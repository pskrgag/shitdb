const std = @import("std");
const Fiber = @import("fiber.zig").Fiber;
const SleepPoint = @import("fiber.zig").SleepPoint;
const List = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

var SchedulerContext: ?*Fiber = null;
var CurrentFiber: *Fiber = undefined;

/// Opaque fiber handle
pub const FiberHandle = struct {
    ptr: usize,
};

pub const SchedulerPlanEntry = struct {
    fiber: FiberHandle,
    run: union(enum) {
        Sleep: SleepPoint,
        End: void,
    },
};

/// Predefined scheduler plan
pub const SchedulerPlan = struct {
    const Array = std.ArrayList(SchedulerPlanEntry);

    plan: Array,

    pub fn new(alloc: Allocator) !SchedulerPlan {
        return .{ .plan = try Array.initCapacity(alloc, 0) };
    }

    pub fn add(self: *SchedulerPlan, entry: SchedulerPlanEntry, alloc: Allocator) !void {
        try self.plan.append(alloc, entry);
    }

    pub fn deinit(self: *SchedulerPlan, alloc: Allocator) void {
        self.plan.deinit(alloc);
    }
};

/// Scheduler that runs fibers
pub const Scheduler = struct {
    active: List,

    pub fn new(alloc: Allocator) !Scheduler {
        SchedulerContext = try Fiber.from_current(alloc);
        return .{ .active = List{} };
    }

    pub fn spawn(self: *Scheduler, f: *const fn () void, alloc: Allocator) !FiberHandle {
        const fib = try Fiber.new(f, SchedulerContext.?, alloc);

        self.active.append(&fib.node);
        return .{ .ptr = @intFromPtr(fib) };
    }

    fn run_one(self: *Scheduler, fiber: *Fiber) void {
        _ = self;
        CurrentFiber = fiber;
        defer CurrentFiber = undefined;

        fiber.switch_from(SchedulerContext.?);
    }

    pub fn run_with_plan(self: *Scheduler, plan: SchedulerPlan, alloc: Allocator) !void {
        for (plan.plan.items) |entry| {
            // This is insanely unsafe, but let's assume caller is not an asshole
            const fiber: *Fiber = @ptrFromInt(entry.fiber.ptr);

            switch (entry.run) {
                .End => {
                    while (!fiber.is_done()) {
                        self.run_one(fiber);
                    }

                    self.active.remove(&fiber.node);
                    fiber.deinit(alloc);
                },
                .Sleep => |p| {
                    while (true) {
                        if (fiber.sleep == p)
                            break;

                        if (fiber.is_done()) {
                            std.debug.print("Cannot run fiber till sleep point '{}'. It has finished earlier\n", .{p});
                            @panic("Incorrect scheduling plan");
                        }

                        self.run_one(fiber);
                    }
                },
            }
        }

        // At the end run all remaining fibers till the end in RR manner.
        try self.run(alloc);
    }

    pub fn run(self: *Scheduler, alloc: Allocator) !void {
        while (self.active.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            self.run_one(fiber);

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
        while (self.active.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            fiber.deinit(alloc);
        }

        SchedulerContext.deinit(alloc);
        SchedulerContext = null;
    }
};

pub fn yield(point: SleepPoint) void {
    const builtin = @import("builtin");

    if (builtin.is_test and SchedulerContext != null) {
        CurrentFiber.sleep = point;
        defer CurrentFiber.sleep = null;

        SchedulerContext.?.switch_from(CurrentFiber);
    }
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

    _ = try sched.spawn(noop, allocator);
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

    _ = try sched.spawn(ping, allocator);
    _ = try sched.spawn(pong, allocator);
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

    _ = try sched.spawn(test_sleep, allocator);
    try sched.run(allocator);
}

var PlanGlobal: i32 = 0;

fn f1() void {
    PlanGlobal = 1;
    yield(.Test1);

    PlanGlobal = 1;
    yield(.Test1);

    PlanGlobal = 2;
    yield(.Test);
}

fn f2() void {
    std.debug.assert(PlanGlobal == 3);
    yield(.Test);
    PlanGlobal = 4;
}

fn f3() void {
    std.debug.assert(PlanGlobal == 2);
    PlanGlobal = 3;
}

test "Simple plan" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    var sched = try Scheduler.new(allocator);
    defer sched.deinit(allocator);

    const f1_handle = try sched.spawn(f1, allocator);
    const f2_handle = try sched.spawn(f2, allocator);
    const f3_handle = try sched.spawn(f3, allocator);

    var plan = try SchedulerPlan.new(allocator);
    defer plan.deinit(allocator);

    try plan.add(.{ .fiber = f1_handle, .run = .{ .Sleep = .Test } }, allocator);
    try plan.add(.{ .fiber = f3_handle, .run = .End }, allocator);
    try plan.add(.{ .fiber = f2_handle, .run = .{ .Sleep = .Test } }, allocator);

    try sched.run_with_plan(plan, allocator);
    try std.testing.expectEqual(PlanGlobal, 4);
}
