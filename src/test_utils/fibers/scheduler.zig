const std = @import("std");
const Fiber = @import("fiber.zig").Fiber;
const SleepPoint = @import("fiber.zig").SleepPoint;
const List = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

var SchedulerContext: *Fiber = undefined;
var CurrentFiber: *Fiber = undefined;

pub const Scheduler = struct {
    active: List,

    pub fn new(alloc: Allocator) !Scheduler {
        SchedulerContext = try Fiber.from_current(alloc);
        return .{ .active = List{} };
    }

    pub fn spawn(self: *Scheduler, f: *const fn () void, alloc: Allocator) !void {
        const fib = try Fiber.new(f, SchedulerContext, alloc);
        self.active.append(&fib.node);
    }

    pub fn run(self: *Scheduler, alloc: Allocator) !void {
        while (self.active.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            CurrentFiber = fiber;
            fiber.switch_from(SchedulerContext);
            CurrentFiber = undefined;

            if (fiber.is_done()) {
                std.debug.assert(fiber.sleep == null);
                fiber.deinit(alloc);
            } else {
                std.debug.assert(fiber.sleep != null);
                self.active.append(&fiber.node);
            }
        }
    }

    pub fn deinit(self: *Scheduler, alloc: Allocator) void {
        _ = self;
        SchedulerContext.deinit(alloc);
        SchedulerContext = undefined;
    }
};

pub fn yield(point: SleepPoint) void {
    CurrentFiber.sleep = point;
    defer CurrentFiber.sleep = null;

    SchedulerContext.switch_from(CurrentFiber);
}

var Global: i32 = 0;

fn noop() void {
    Global = 1;
}

test "Noop fiber" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    var sched = try Scheduler.new(allocator);
    defer sched.deinit(allocator);

    try sched.spawn(noop, allocator);
    try sched.run(allocator);
    try std.testing.expectEqual(Global, 1);
}

var GlobalPong: i32 = 0;

fn ping() void {
    std.debug.assert(GlobalPong == 0);
    GlobalPong = 1;
    yield(.Test);

    std.debug.assert(GlobalPong == 2);
    GlobalPong = 3;
    yield(.Test);
}

fn pong() void {
    std.debug.assert(GlobalPong == 1);
    GlobalPong = 2;
    yield(.Test);

    std.debug.assert(GlobalPong == 3);
    GlobalPong = 4;
    yield(.Test);
}

test "Ping pong" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    var sched = try Scheduler.new(allocator);
    defer sched.deinit(allocator);

    try sched.spawn(ping, allocator);
    try sched.spawn(pong, allocator);
    try sched.run(allocator);
    try std.testing.expectEqual(GlobalPong, 4);
}

fn test_sleep() void {
    std.debug.assert(CurrentFiber.sleep == null);
    yield(.Test);
}

test "Sleep points" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    var sched = try Scheduler.new(allocator);
    defer sched.deinit(allocator);

    try sched.spawn(test_sleep, allocator);
    try sched.run(allocator);
}

