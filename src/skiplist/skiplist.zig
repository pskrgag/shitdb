const std = @import("std");
const Allocator = std.mem.Allocator;
const compare_keys = @import("generic_utils").compare_keys;
pub const Arena = @import("arena.zig").ThreadSafeArena;
pub const ArenaBouned = @import("arena.zig").ThreadSafeArenaBounded;
const thread_prng = @import("prng.zig").prng;

pub const Prng = @import("prng.zig");
const MaxHeigth = 12;

fn NodeRef(T: type) type {
    return packed struct(usize) {
        ptr: usize,

        pub fn new(p: ?*const Node(T)) NodeRef(T) {
            return .{ .ptr = if (p) |pp| @intFromPtr(pp) else 0 };
        }

        pub fn nul() NodeRef(T) {
            return .{ .ptr = 0 };
        }

        pub fn is_null(self: *const NodeRef(T)) bool {
            return self.ptr == 0;
        }

        pub fn as_ptr(self: *const NodeRef(T)) ?*Node(T) {
            if (self.ptr == 0) {
                return null;
            } else {
                return @ptrFromInt(self.ptr);
            }
        }
    };
}

pub fn Node(T: type) type {
    return struct {
        key: T,
        next: std.ArrayList(std.atomic.Value(NodeRef(T))),

        fn new(h: usize, val: T, alloc: Allocator) !Node(T) {
            var nxt = try std.ArrayList(std.atomic.Value(NodeRef(T))).initCapacity(alloc, h);

            nxt.appendNTimesAssumeCapacity(std.atomic.Value(NodeRef(T)).init(NodeRef(T).nul()), h);
            return .{ .key = val, .next = nxt };
        }

        fn next_at_lvl(self: *const Node(T), lvl: usize) NodeRef(T) {
            return self.next.items[lvl].load(.acquire);
        }

        fn change_next_at_lvl_unsafe(self: *Node(T), lvl: usize, n: ?*Node(T)) void {
            self.next.items[lvl].store(NodeRef(T).new(n), .release);
        }

        fn try_change_next_at_lvl(self: *Node(T), lvl: usize, expected: ?*Node(T), n: *Node(T)) bool {
            return self.next.items[lvl].cmpxchgStrong(
                NodeRef(T).new(expected),
                NodeRef(T).new(n),
                .release,
                .monotonic,
            ) == null;
        }

        fn heigth(self: *Node(T)) usize {
            // Height is constant, so it's possible to read it w/o locks
            return self.next.items.len;
        }
    };
}

pub fn Iterator(T: type) type {
    return struct {
        cur: ?*Node(T),

        const Self = @This();

        fn new(h: NodeRef(T)) Self {
            var head = h;
            return .{ .cur = head.as_ptr() };
        }

        pub fn next(self: *Self) ?*T {
            if (self.cur) |node| {
                const res = &node.key;
                var nxt = node.next_at_lvl(0);

                self.cur = nxt.as_ptr();
                return res;
            } else {
                return null;
            }
        }
    };
}

pub fn SkipList(T: type) type {
    return struct {
        head: Node(T),
        arena: Arena,
        heigth: std.atomic.Value(usize),

        const Self = @This();

        fn max_heigth(self: *Self) usize {
            return self.heigth.load(.monotonic);
        }

        fn random_lvl() usize {
            const FACTOR: usize = 25;

            var h: usize = 1;

            while (thread_prng().random().int(u8) % 100 < FACTOR and h < MaxHeigth - 1) {
                h += 1;
            }

            return h;
        }

        fn find_insert_spot(
            self: *Self,
            K: type,
            val: K,
            h: usize,
            prev: []*Node(T),
            succ: []?*Node(T),
            to_lvl: usize,
        ) ?*Node(T) {
            var lvl: usize = h - 1;
            var node = &self.head;

            while (true) {
                var next = node.next_at_lvl(lvl);

                if (next.as_ptr()) |nxt| {
                    const cmp_res = compare_keys(T, K, nxt.key, val);
                    switch (cmp_res) {
                        .lt => {
                            // val > node::key. Move forward to the right
                            node = nxt;
                        },
                        .gt => {
                            prev[lvl] = node;
                            succ[lvl] = nxt;

                            if (lvl == to_lvl)
                                return null;

                            lvl -= 1;
                        },
                        .eq => {
                            for (0..lvl + 1) |i| {
                                var cur_next = nxt.next_at_lvl(i);

                                prev[i] = nxt;
                                succ[i] = cur_next.as_ptr();
                            }

                            return nxt;
                        },
                    }
                } else {
                    prev[lvl] = node;
                    succ[lvl] = null;

                    if (lvl == to_lvl)
                        return null;

                    lvl -= 1;
                }
            }
        }

        // Pre-allocates node
        pub fn preallocate_node(self: *Self, val: T) !*Node(T) {
            const lvl = Self.random_lvl();
            const node = try self.arena.allocator().create(Node(T));

            node.* = try Node(T).new(lvl, val, self.arena.allocator());
            return node;
        }

        /// Constructs new SkipList with `bound` memory usage.
        pub fn new(alloc: Allocator, io: std.Io) !Self {
            var arena = try Arena.new(alloc, io);
            const node = try Node(T).new(MaxHeigth, undefined, arena.allocator());

            return .{
                .head = node,
                .arena = arena,
                .heigth = std.atomic.Value(usize).init(1),
            };
        }

        /// Inserts new value into the SkipList
        pub fn insert(self: *Self, val: T) !void {
            const lvl = Self.random_lvl();
            const node = try self.arena.allocator().create(Node(T));
            node.* = try Node(T).new(lvl, val, self.arena.allocator());

            return self.insert_node(node);
        }

        /// Inserts pre-allocated node into skiplist.
        pub fn insert_node(self: *Self, node: *Node(T)) !void {
            var linked_lvl: usize = 0;
            const lvl = node.heigth();

            std.debug.assert(lvl > 0);
            std.debug.assert(lvl < MaxHeigth);

            outer: while (true) {
                var prev: [MaxHeigth]*Node(T) = undefined;
                var succ: [MaxHeigth]?*Node(T) = undefined;
                const max_h = @max(self.max_heigth(), lvl);

                std.debug.assert(max_h < MaxHeigth);

                const found = self.find_insert_spot(T, node.key, max_h, prev[0..], succ[0..], linked_lvl);
                if (found != null)
                    return error.AlreadyExists;

                for (linked_lvl..lvl) |h| {
                    // NOTE: initialize next before publishing. Otherwise there is a chance that list would be split
                    // into 2 parts on 0th lvl.
                    node.change_next_at_lvl_unsafe(h, succ[h]);

                    // If this fails, just retry the search. Even if h != 0, it's fine, since node can
                    // be found using 0th level. It only affects O(logN) for the search.
                    if (!prev[h].try_change_next_at_lvl(h, succ[h], node)) {
                        continue :outer;
                    }

                    linked_lvl += 1;
                }

                break;
            }

            // Try to update the maximum length.
            while (lvl > self.max_heigth()) {
                const cur = self.max_heigth();

                if (self.heigth.cmpxchgWeak(cur, lvl, .monotonic, .monotonic) == null)
                    break;
            }
        }

        /// Finds a key by `val`. K and T must be comparable and should have strict ordering
        pub fn find(self: *Self, K: type, val: K) ?*T {
            var prev: [MaxHeigth]*Node(T) = undefined;
            var succ: [MaxHeigth]?*Node(T) = undefined;

            const node = self.find_insert_spot(K, val, self.max_heigth(), prev[0..], succ[0..], 0);
            return if (node) |n| &n.key else null;
        }

        /// Finds a key by `val`. K and T must be comparable and should have strict ordering
        pub fn find_greater_or_eq(self: *Self, K: type, val: K) ?*T {
            var prev: [MaxHeigth]*Node(T) = undefined;
            var succ: [MaxHeigth]?*Node(T) = undefined;

            _ = self.find_insert_spot(K, val, self.max_heigth(), prev[0..], succ[0..], 0);

            if (prev[0] == &self.head) {
                return null;
            } else {
                return &prev[0].key;
            }
        }

        /// Returns an iterator over values. It's safe to use concurrently with writers. It must not
        /// be used after SkipList is de-initialized.
        pub fn iterator(self: *const Self) Iterator(T) {
            return Iterator(T).new(self.head.next_at_lvl(0));
        }

        /// Returns maximum key
        pub fn max(self: *const Self) ?*const T {
            var iter = self.head.next_at_lvl(0);

            if (iter.is_null())
                return null;

            while (true) {
                const next = iter.as_ptr().?.next_at_lvl(0);

                if (next.is_null())
                    return &iter.as_ptr().?.key;

                iter = next;
            }
        }

        /// Returns minimal key
        pub fn min(self: *const Self) ?*const T {
            const node = self.head.next_at_lvl(0);

            if (node.as_ptr()) |nd| {
                return &nd.key;
            } else {
                return null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

test "Basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try SkipList(usize).new(allocator, std.testing.io);
    try list.insert(40);
    try list.insert(20);
    try list.insert(10);
    try list.insert(30);

    var iter = list.iterator();

    try std.testing.expectEqual(iter.next().?.*, 10);
    try std.testing.expectEqual(iter.next().?.*, 20);
    try std.testing.expectEqual(iter.next().?.*, 30);
    try std.testing.expectEqual(iter.next().?.*, 40);
    try std.testing.expectEqual(iter.next(), null);
}

test "Min Max" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try SkipList(usize).new(allocator, std.testing.io);
    try list.insert(40);
    try list.insert(20);
    try list.insert(10);
    try list.insert(30);

    try std.testing.expectEqual(list.max().?.*, 40);
    try std.testing.expectEqual(list.min().?.*, 10);
}

fn producer(list: *SkipList(usize), vals: []const usize) !void {
    for (vals) |i| {
        try list.insert(i);
    }
}

fn consumer(list: *SkipList(usize), finish: *bool) !void {
    while (@atomicLoad(bool, finish, .monotonic) == false) {
        var iter = list.iterator();
        var prev = iter.next() orelse continue;

        while (iter.next()) |val| {
            std.debug.assert(val.* > prev.*);
            prev = val;
        }
    }
}

const NumPush = 10000;

test "Test MT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shuffle_prng = std.Random.DefaultPrng.init(0xdead_beef);
    const rand = shuffle_prng.random();

    var list = try SkipList(usize).new(allocator, std.testing.io);
    var list1 = try std.ArrayList(usize).initCapacity(allocator, NumPush);
    var list2 = try std.ArrayList(usize).initCapacity(allocator, NumPush);

    for (0..NumPush) |i| {
        try list1.append(allocator, i);
    }

    rand.shuffle(usize, list1.items);

    for (NumPush..NumPush * 2) |i| {
        try list2.append(allocator, i);
    }

    rand.shuffle(usize, list2.items);

    var finish = false;
    const prod = try std.Thread.spawn(.{}, producer, .{ &list, list1.items });
    const prod1 = try std.Thread.spawn(.{}, producer, .{ &list, list2.items });
    const cons = try std.Thread.spawn(.{}, consumer, .{ &list, &finish });

    prod.join();
    prod1.join();

    @atomicStore(bool, &finish, true, .monotonic);
    cons.join();

    // Check that all values are present
    for (0..NumPush * 2) |i| {
        const key = list.find(usize, i);
        try std.testing.expect(key != null);
        try std.testing.expectEqual(key.?.*, i);
    }

    // Check that other values are not present
    for (NumPush * 2..NumPush * 3) |i| {
        const key = list.find(usize, i);
        try std.testing.expect(key == null);
    }
}
