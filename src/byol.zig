const std = @import("std");
const Allocator = std.mem.Allocator;

// TODO: Zig#10967 (or similar)
const Align = std.Target.stack_align;

pub const Scheduler = struct {
    allocator: Allocator,
    max_tasks: usize,
    active_tasks: *usize,

    pub fn init(allocator: Allocator, max_tasks: usize) !@This() {
        const active_tasks = try allocator.create(usize);
        errdefer allocator.destroy(active_tasks);
        active_tasks.* = 0;

        return @This(){
            .allocator = allocator,
            .max_tasks = max_tasks,
            .active_tasks = active_tasks,
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.destroy(self.active_tasks);
    }

    pub fn spawn(self: @This(), comptime f: anytype, comptime RtnT: ?type, args: anytype) !ResumeTicket(f, RtnT) {
        const _f = ImmediateSuspendWrapper(f, RtnT)._f;

        const should_spawn = blk: {
            const prev_tasks = @atomicRmw(usize, self.active_tasks, .Add, 1, .Monotonic);
            const rtn = prev_tasks < self.max_tasks;
            if (!rtn)
                _ = @atomicRmw(usize, self.active_tasks, .Sub, 1, .Monotonic);
            break :blk rtn;
        };

        const F = @TypeOf(async _f(self, should_spawn, args));
        var frame_ptr = try self.allocator.create(F);
        errdefer self.allocator.destroy(frame_ptr);
        frame_ptr.* = async _f(self, should_spawn, args);

        if (should_spawn)
            resume frame_ptr;

        return ResumeTicket(f, RtnT){
            .free_ptr = @intToPtr([*]align(Align) u8, @ptrToInt(frame_ptr))[0..@sizeOf(F)],
            .frame = frame_ptr,
            .resumed = should_spawn,
        };
    }

    pub fn finish(self: @This(), handle: anytype) @typeInfo(@TypeOf(handle.frame)).AnyFrame.child.? {
        defer self.allocator.free(handle.free_ptr);
        if (!handle.resumed)
            resume handle.frame;
        return await handle.frame;
    }
};

// TODO: Zig#2935
fn GenericReturnT(comptime f: anytype, comptime T: ?type) type {
    const BaseT = T orelse @typeInfo(@TypeOf(f)).Fn.return_type orelse @compileError("Return type inference failed");

    // TODO: wrong place, hard-coded error set
    return switch (@typeInfo(BaseT)) {
        .ErrorUnion => |info| @Type(.{
            .ErrorUnion = .{ .error_set = info.error_set || Allocator.Error, .payload = info.payload },
        }),
        else => Allocator.Error!BaseT,
    };
}

fn ResumeTicket(comptime f: anytype, comptime T: ?type) type {
    return struct {
        free_ptr: []align(Align) u8,
        frame: anyframe->GenericReturnT(f, T),
        resumed: bool,
    };
}

fn ImmediateSuspendWrapper(comptime f: anytype, comptime RtnT: ?type) type {
    return struct {
        pub fn _f(scheduler: Scheduler, should_yield: bool, args: anytype) GenericReturnT(f, RtnT) {
            suspend {}
            defer {
                if (should_yield)
                    _ = @atomicRmw(usize, scheduler.active_tasks, .Sub, 1, .Monotonic);
            }
            if (std.event.Loop.instance) |loop| {
                if (should_yield)
                    loop.yield();
            }

            // TODO: Zig#???
            // Only possible to use @asyncCall on async functions (for now), but detecting whether
            // a function is async invokes the recursive function analysis check (for now). Choosing
            // to only support async.
            var buf = try scheduler.allocator.alignedAlloc(u8, Align, @frameSize(f));
            defer scheduler.allocator.free(buf);
            return await @asyncCall(buf, {}, f, args);
        }
    };
}

fn quicksum(scheduler: Scheduler, m: usize, M: usize) anyerror!usize {
    // Recursion should have a base case
    if (M - m < 100) {
        var total: usize = 0;
        var k: usize = m;
        while (k < M) : (k += 1) {
            total +%= k;
        }
        return total;
    }

    // Express some concurrency in your problem
    const i = @divFloor(M - m + 1, 3);
    var left = try scheduler.spawn(quicksum, null, .{ scheduler, m, i + m });
    var mid = try scheduler.spawn(quicksum, null, .{ scheduler, i + m, 2 * i + m });
    var right = try scheduler.spawn(quicksum, null, .{ scheduler, 2 * i + m, M });

    // Request your answers
    var total: usize = 0;
    total +%= try await async scheduler.finish(left);
    total +%= try await async scheduler.finish(mid);
    total +%= try await async scheduler.finish(right);

    return total;
}

fn test_main(allocator: Allocator) void {
    const scheduler = Scheduler.init(allocator, 4) catch unreachable;
    defer scheduler.deinit();
    _ = await async quicksum(scheduler, 0, 10000) catch unreachable;
}

test "doesn't crash" {
    const allocator = std.testing.allocator;

    var event_loop: std.event.Loop = undefined;
    try event_loop.initMultiThreaded();
    defer event_loop.deinit();

    try event_loop.runDetached(allocator, test_main, .{allocator});
    event_loop.run();
}
