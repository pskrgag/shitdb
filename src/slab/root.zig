const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.atomic.Value;

pub fn Slab(comptime T: type, capacity: usize) type {
    return struct {
        const Node = struct {
            val: T,
            next: ?*Node,
        };

        head: ?*Node,
        memory: *[capacity]Node,
        mutex: std.Io.Mutex,
        cv: std.Io.Condition,
        io: std.Io,

        const Self = @This();

        pub fn init(a: Allocator, io: std.Io) !Self {
            const nodes = try a.alloc(Node, capacity);

            for (nodes[0 .. capacity - 1], 0..) |*node, i| {
                node.next = &nodes[i + 1];
            }

            nodes[capacity - 1].next = null;
            return .{
                .head = &nodes[0],
                .memory = @ptrCast(nodes.ptr),
                .mutex = .init,
                .cv = .init,
                .io = io,
            };
        }

        pub fn try_alloc(self: *Self) ?*T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            return self.alloc_unlocked();
        }

        pub fn alloc(self: *Self) *T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (true) {
                if (self.alloc_unlocked()) |ptr| return ptr;
                self.cv.waitUncancelable(self.io, &self.mutex);
            }
        }

        fn alloc_unlocked(self: *Self) ?*T {
            const current = self.head;

            if (current) |cur| {
                self.head = cur.next;
                return &cur.val;
            } else {
                return null;
            }
        }

        pub fn free(self: *Self, ptr: *T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const node: *Node = @fieldParentPtr("val", ptr);
            const current = self.head;

            node.next = current;
            self.head = node;
            self.cv.signal(self.io);
        }

        pub fn deinit(self: *Self, a: Allocator) void {
            const slice: []Node = (self.memory)[0..capacity];
            a.free(slice);
        }
    };
}

test "Single threaded" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const cap: usize = 10;

    var slab = try Slab(usize, cap).init(arena.allocator(), std.testing.io);
    defer slab.deinit(arena.allocator());

    var set = std.AutoHashMap(usize, void).init(arena.allocator());
    defer set.deinit();

    for (0..cap) |_| {
        const val = slab.try_alloc();

        try std.testing.expect(!set.contains(@intFromPtr(val)));
        try set.put(@intFromPtr(val), {});
    }

    try std.testing.expectEqual(slab.try_alloc(), null);
}

test "Freed slots can be allocated again" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    const cap: usize = 10;
    var slab = try Slab(usize, cap).init(arena.allocator(), std.testing.io);
    defer slab.deinit(arena.allocator());

    var slots: [cap]*usize = undefined;
    for (&slots) |*slot| {
        slot.* = slab.try_alloc().?;
    }

    try std.testing.expectEqual(null, slab.try_alloc());

    for (slots) |slot| {
        slab.free(slot);
    }

    var set = std.AutoHashMap(usize, void).init(arena.allocator());
    defer set.deinit();

    for (0..cap) |_| {
        const slot = slab.try_alloc().?;
        try std.testing.expect(!set.contains(@intFromPtr(slot)));
        try set.put(@intFromPtr(slot), {});
    }

    try std.testing.expectEqual(null, slab.try_alloc());
}

test "Allocation waits until a slot is freed" {
    const TestSlab = Slab(usize, 1);
    const Worker = struct {
        fn run(slab: *TestSlab, started: *Value(bool), result: *?*usize) void {
            started.store(true, .release);
            result.* = slab.alloc();
        }
    };

    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    var slab = try TestSlab.init(arena.allocator(), std.testing.io);
    defer slab.deinit(arena.allocator());

    const slot = slab.try_alloc().?;
    var started = Value(bool).init(false);
    var result: ?*usize = null;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &slab, &started, &result });

    while (!started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try std.testing.expectEqual(null, result);
    slab.free(slot);
    thread.join();

    try std.testing.expectEqual(slot, result.?);
}

test "Free wakes multiple allocation waiters" {
    const TestSlab = Slab(usize, 2);
    const Worker = struct {
        fn run(slab: *TestSlab, started: *Value(usize), result: *?*usize) void {
            _ = started.fetchAdd(1, .release);
            result.* = slab.alloc();
        }
    };

    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }

    var slab = try TestSlab.init(arena.allocator(), std.testing.io);
    defer slab.deinit(arena.allocator());

    const first = slab.try_alloc().?;
    const second = slab.try_alloc().?;
    var started = Value(usize).init(0);
    var results: [2]?*usize = .{ null, null };
    var threads: [2]std.Thread = undefined;

    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &slab, &started, result });
    }

    while (started.load(.acquire) != threads.len) {
        std.Thread.yield() catch {};
    }

    try std.testing.expectEqual(null, results[0]);
    try std.testing.expectEqual(null, results[1]);

    slab.free(first);
    slab.free(second);

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expect(results[0] != null);
    try std.testing.expect(results[1] != null);
    try std.testing.expect(results[0] != results[1]);
}
