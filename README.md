# BYOL

Bring Your Own Loop -- A memory-efficient, straggler-avoiding, cache-friendly scheduler

## Purpose

Make your programs actually faster when you parallelize them:

1. You can still just write the naive code that spawns new tasks whenever you have natural concurrency. BYOL defers instantiating them till the right time to ensure you don't accidentally use GB of RAM for your parallel quicksort.

1. Scheduling overhead is low, so you can schedule fine-grained tasks and not get stuck with 15 idle cores while 1 task takes twice as long as the others.

1. In-flight tasks are (probabilistically) near to each other in the execution graph. Assuming parent/child tasks tend to use the same memory (like passing a slice of your data to a child as in quicksort), this results in less cache thrashing.

## Installation

Choose your favorite method for vendoring this code into your repository. I'm using [zigmod](https://github.com/nektro/zigmod) to bring in the pool allocator for this project, and it's pretty painless. I also generally like [git-subrepo](https://github.com/ingydotnet/git-subrepo), copy-paste is always a winner, and whenever the official package manager is up we'll be there too.

## Examples

```zig
// const max_in_flight: usize = 42;
// const scheduler = try Scheduler.init(allocator, max_in_flight);
// defer scheduler.deinit();

fn quicksum(scheduler: Scheduler, m: usize, M: usize) anyerror!usize {
    // Recursion should have a base case.
    if (M - m < 100) {
        var total: usize = 0;
        var k: usize = m;
        while (k < M) : (k += 1) {
            total +%= k;
        }
        return total;
    }

    // Express some concurrency in your problem. This division into 3 is
    // arbitrary, just to show you can spawn however many times you like.
    const i = @divFloor(M - m + 1, 3);
    var left = try scheduler.spawn(quicksum, null, .{ scheduler, m, i + m });
    var mid = try scheduler.spawn(quicksum, null, .{ scheduler, i + m, 2 * i + m });
    var right = try scheduler.spawn(quicksum, null, .{ scheduler, 2 * i + m, M });

    // Request your answers.
    var total: usize = 0;
    total +%= try await async scheduler.finish(left);
    total +%= try await async scheduler.finish(mid);
    total +%= try await async scheduler.finish(right);

    return total;
}
```

## How does it work?

Scheduling algorithms like DFDeques use clever data structures to approximate the "natural" depth-first execution order you would get with single-threaded execution (preserving cache friendliness) with minimal scheduling overhead (allowing fine-grained tasks to avoid stragglers), and capping peak RAM by not widening that execution graph very far -- adding only a few new tasks near to the others in the execution graph and preferring for those to be deep rather than shallow.

We use the opposite of clever data structures to approximate the behavior of DFDeques. In particular, we maintain an atomic count of in-flight tasks. When you spawn a new task, if the count is low then we yield to the event loop so that it can eventually schedule that task on its favorite CPU core. If instead the count is high, we simply execute that work as part of the current task. The event loop never knows about very many in-flight tasks, and we only tell it about them in an order that is (probabilistically) similar to the depth-first order in DFDeques, so we obtain similar scheduling behavior.

Peak RAM is, as in DFDeques, tunable. With higher max in-flight counts you will tend to use more RAM but will have runtime behavior more akin to a work-stealing scheduler (i.e., fewer stragglers). Scheduling overhead is low (an atomic counter and a few lines of compile-time known wrapper code). Cache friendliness is the property that can suffer the most when compared to DFDeques; at any moment in time, most in-flight tasks will be close in the execution graph, but unless the underlying event loop takes care to schedule parents/children on the same core you might have less sharing than would be available in a full-blown scheduler.

## Status
Contributions welcome. I'll check back on this repo at least once per month. Currently targets Zig 0.10.

The scheduler works and does everything I need it to. However:

1. The use of a shared atomic variable necessarily means that at sufficiently high levels of concurrency (10s of thousands up to 10s of millions of cores should be fine, billions shouldn't be) the scheduler overhead is actually quadratic rather than linear. It might be worth taking a look at doing something less naive.

1. The API is a bit wonky. E.g., I don't like the Scheduler `init` function accepting a numeric argument and not telling you what it is.

1. It _might_ be nice to provide a wrapper where people only intending to use async for this one purpose don't have to concern themselves with setting up an event loop and getting their values out of it (or shunting their other code into it).
