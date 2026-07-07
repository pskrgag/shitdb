const std = @import("std");
const Fiber = @import("fiber.zig").Fiber;
const SleepPoint = @import("fiber.zig").SleepPoint;
const ei = @import("../injection/ei.zig");
const List = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;
const FiberKind = @import("fiber.zig").FiberKind;

threadlocal var SchedulerContext: ?*Fiber = null;
threadlocal var CurrentFiber: ?*Fiber = null;
var Sched: Scheduler = undefined;

/// Opaque fiber handle
pub const FiberHandle = union {
    fiber: usize,
    thread: std.Thread,

    pub fn join(self: FiberHandle) void {
        if (is_running()) {
            Sched.run_until_done(self);
        } else {
            self.thread.join();
        }
    }

    fn as_fiber(handle: FiberHandle) *Fiber {
        return @ptrFromInt(handle.fiber);
    }
};

pub const SchedulerPlanEntry = struct {
    fiber: FiberHandle,
    run: union(enum) {
        Sleep: SleepPoint,
        End: void,
    },
    inject_error: []const ei.ErrorKind = &.{},
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
const Scheduler = struct {
    foreground: List = .{},
    background: List = .{},
    gc: List = .{},
    debug: bool,

    pub fn new(debug: bool) !Scheduler {
        return .{ .debug = debug };
    }

    pub fn spawn(
        self: *Scheduler,
        comptime f: anytype,
        args: anytype,
        name: []const u8,
        kind: FiberKind,
        alloc: Allocator,
    ) !FiberHandle {
        const Args = @TypeOf(args);

        const CallContext = struct {
            args: Args,

            fn entry(ptr: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const result = @call(.auto, f, ctx.args);
                switch (@typeInfo(@TypeOf(result))) {
                    .error_union => result catch @panic("fiber returned error"),
                    .void => {},
                    else => @compileError("fiber entry must return void or !void"),
                }
            }

            fn cleanup(ptr: *anyopaque, allocator: Allocator) void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(ctx);
            }
        };

        const ctx = try alloc.create(CallContext);
        errdefer alloc.destroy(ctx);
        ctx.* = .{ .args = args };

        const fib = try Fiber.new(
            CallContext.entry,
            ctx,
            CallContext.cleanup,
            SchedulerContext.?,
            name,
            kind,
            alloc,
        );

        if (kind == .Foregroud) {
            self.foreground.append(&fib.node);
        } else {
            self.background.append(&fib.node);
        }

        return .{ .fiber = @intFromPtr(fib) };
    }

    fn ping_background(self: *Scheduler) void {
        var new_list = List{};

        while (self.background.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            // NOTE: this is hacky. It's overcomes the problem when background thread is awaited
            // by run_until_done(). It must ping background threads sometimes, so fiber may be
            // in weird state here....
            if (!fiber.is_done())
                self.run_one(fiber);

            if (fiber.is_done()) {
                self.gc.append(&fiber.node);
            } else {
                new_list.append(&fiber.node);
            }
        }

        self.background = new_list;
    }

    fn run_one(self: *Scheduler, fiber: *Fiber) void {
        CurrentFiber = fiber;
        defer CurrentFiber = null;

        if (self.debug) {
            std.debug.print("--> {s}\n", .{fiber.name});
        }

        fiber.switch_from(SchedulerContext.?);

        if (self.debug) {
            std.debug.print("<-- {s} (sleep: {any}) (done: {})\n", .{ fiber.name, fiber.sleep, fiber.is_done() });
        }
    }

    pub fn run_until_sleep(self: *Scheduler, handle: FiberHandle, point: SleepPoint) void {
        const fiber = handle.as_fiber();

        while (true) {
            if (fiber.sleep == point)
                return;

            if (fiber.is_done()) {
                std.debug.print("Cannot run fiber till sleep point '{}'. It has finished earlier\n", .{point});
                @panic("Incorrect scheduling plan");
            }

            self.run_one(fiber);
        }
    }

    pub fn run_until_done(self: *Scheduler, handle: FiberHandle) void {
        const fiber = handle.as_fiber();

        while (!fiber.is_done()) {
            self.run_one(fiber);
            self.ping_background();
        }

        if (fiber.kind == .Foregroud) {
            self.foreground.remove(&fiber.node);
            self.gc.append(&fiber.node);
        }
    }

    pub fn run_with_plan(self: *Scheduler, plan: SchedulerPlan, alloc: Allocator) !void {
        for (plan.plan.items) |entry| {
            const fiber = entry.fiber.as_fiber();

            std.debug.assert(fiber.kind == .Foregroud);

            for (entry.inject_error) |err| {
                try ei.enable(err, 1);
            }

            switch (entry.run) {
                .End => {
                    while (!fiber.is_done()) {
                        self.run_one(fiber);
                        self.ping_background();
                    }

                    self.foreground.remove(&fiber.node);
                    fiber.deinit(alloc);
                },
                .Sleep => |p| {
                    while (true) {
                        if (fiber.sleep == p) {
                            break;
                        }

                        if (fiber.is_done()) {
                            std.debug.print("Cannot run fiber till sleep point '{}'. It has finished earlier\n", .{
                                p,
                            });
                            @panic("Incorrect scheduling plan");
                        }

                        self.run_one(fiber);
                        self.ping_background();
                    }
                },
            }
        }

        // At the end run all remaining fibers till the end in RR manner.
        try self.run(alloc);
    }

    pub fn run(self: *Scheduler, alloc: Allocator) !void {
        while (self.foreground.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            self.run_one(fiber);

            if (fiber.is_done()) {
                std.debug.assert(fiber.sleep == null);
                fiber.deinit(alloc);
            } else {
                std.debug.assert(fiber.sleep != null);
                self.foreground.append(&fiber.node);
            }
        }
    }

    fn deinit_list(list: List, alloc: Allocator) void {
        var lst = list;

        while (lst.popFirst()) |task| {
            const fiber: *Fiber = @fieldParentPtr("node", task);

            fiber.deinit(alloc);
        }
    }

    pub fn deinit(self: *Scheduler, alloc: Allocator) void {
        deinit_list(self.foreground, alloc);
        deinit_list(self.background, alloc);
        deinit_list(self.gc, alloc);
    }
};

pub fn run_with_scheduler(comptime f: anytype, args: anytype, debug: bool, alloc: Allocator) !void {
    Sched = try Scheduler.new(debug);
    SchedulerContext = try Fiber.from_current(alloc);

    defer {
        Sched.deinit(alloc);
        Sched = undefined;

        SchedulerContext.?.deinit(alloc);
        SchedulerContext = null;
    }

    try @call(.auto, f, args);
}

pub fn spawn_ex(
    comptime f: anytype,
    args: anytype,
    name: []const u8,
    kind: FiberKind,
    alloc: Allocator,
) !FiberHandle {
    if (is_running()) {
        return try Sched.spawn(f, args, name, kind, alloc);
    } else {
        return .{ .thread = try std.Thread.spawn(.{}, f, args) };
    }
}

pub fn spawn(
    comptime f: anytype,
    args: anytype,
    name: []const u8,
    alloc: Allocator,
) !FiberHandle {
    return try spawn_ex(f, args, name, .Foregroud, alloc);
}

pub fn run_with_plan(plan: SchedulerPlan, alloc: Allocator) !void {
    return try Sched.run_with_plan(plan, alloc);
}

pub fn is_running() bool {
    const builtin = @import("builtin");
    return builtin.is_test and SchedulerContext != null;
}

pub fn yield(point: SleepPoint) void {
    if (is_running()) {
        const fiber = CurrentFiber orelse return;

        fiber.sleep = point;
        defer fiber.sleep = null;

        SchedulerContext.?.switch_from(fiber);
    }
}

var Global: i32 = 0;

fn test_scheduler_context(alloc: Allocator) !void {
    SchedulerContext = try Fiber.from_current(alloc);
}

fn deinit_test_scheduler_context(alloc: Allocator) void {
    SchedulerContext.?.deinit(alloc);
    SchedulerContext = null;
}

fn noop() void {
    Global = 1;
}

test "Noop fiber" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    try test_scheduler_context(allocator);
    defer deinit_test_scheduler_context(allocator);

    var sched = try Scheduler.new(false);
    defer sched.deinit(allocator);

    _ = try sched.spawn(noop, .{}, "noop", .Foregroud, allocator);
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
    try test_scheduler_context(allocator);
    defer deinit_test_scheduler_context(allocator);

    var sched = try Scheduler.new(false);
    defer sched.deinit(allocator);

    _ = try sched.spawn(ping, .{}, "ping", .Foregroud, allocator);
    _ = try sched.spawn(pong, .{}, "pong", .Foregroud, allocator);
    try sched.run(allocator);
    try std.testing.expectEqual(GlobalPong, 4);
}

fn test_sleep() void {
    std.debug.assert(CurrentFiber.?.sleep == null);
    yield(.Test);
}

test "Sleep points" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const allocator = arena.allocator();
    try test_scheduler_context(allocator);
    defer deinit_test_scheduler_context(allocator);

    var sched = try Scheduler.new(false);
    defer sched.deinit(allocator);

    _ = try sched.spawn(test_sleep, .{}, "test_sleep", .Foregroud, allocator);
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
    try test_scheduler_context(allocator);
    defer deinit_test_scheduler_context(allocator);

    var sched = try Scheduler.new(false);
    defer sched.deinit(allocator);

    const f1_handle = try sched.spawn(f1, .{}, "f1", .Foregroud, allocator);
    const f2_handle = try sched.spawn(f2, .{}, "f2", .Foregroud, allocator);
    const f3_handle = try sched.spawn(f3, .{}, "f3", .Foregroud, allocator);

    var plan = try SchedulerPlan.new(allocator);
    defer plan.deinit(allocator);

    try plan.add(.{ .fiber = f1_handle, .run = .{ .Sleep = .Test } }, allocator);
    try plan.add(.{ .fiber = f3_handle, .run = .End }, allocator);
    try plan.add(.{ .fiber = f2_handle, .run = .{ .Sleep = .Test } }, allocator);

    try sched.run_with_plan(plan, allocator);
    try std.testing.expectEqual(PlanGlobal, 4);
}

var ArgsGlobal: i32 = 0;

fn add_to_global(delta: i32, multiplier: i32) void {
    ArgsGlobal += delta * multiplier;
}

test "Spawn passes args" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    ArgsGlobal = 0;

    const allocator = arena.allocator();
    try test_scheduler_context(allocator);
    defer deinit_test_scheduler_context(allocator);

    var sched = try Scheduler.new(false);
    defer sched.deinit(allocator);

    _ = try sched.spawn(add_to_global, .{ 2, 3 }, "add1", .Foregroud, allocator);
    _ = try sched.spawn(add_to_global, .{ 4, 5 }, "add2", .Foregroud, allocator);
    try sched.run(allocator);
    try std.testing.expectEqual(@as(i32, 26), ArgsGlobal);
}
