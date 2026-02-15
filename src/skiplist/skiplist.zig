const std = @import("std");
const Allocator = std.mem.Allocator;
const MaxHeigth = 12;

pub const Arena = @import("arena.zig").ThreadSafeArena;

fn is_primitive_type(Key: type) bool {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => true,
        else => false,
    };
}

fn compare_same(Key: type, lhs: Key, rhs: Key) std.math.Order {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => {
            return std.math.order(lhs, rhs);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and is_primitive_type(ptr.child)) {
                return std.mem.order(ptr.child, lhs, rhs);
            } else {
                @compileError("todo " ++ @typeName(ptr.child));
            }
        },
        .@"struct" => |_| {
            if (@hasDecl(Key, "cmp")) {
                return lhs.cmp(&rhs);
            } else {
                @compileError("Custom structs must implement 'cmp' method" ++ @typeName(Key));
            }
        },
        else => @compileError("Unsupported type for comparison: " ++ @typeName(Key)),
    };
}

fn transform_struct_name(comptime input: []const u8) [input.len]u8 {
    comptime {
        var result: [input.len]u8 = undefined;

        for (input, 0..) |c, i| {
            result[i] = if (c == '.') '_' else c;
        }

        return result;
    }
}

fn compare_keys(Key: type, Other: type, lhs: Key, rhs: Other) std.math.Order {
    if (Key == Other) {
        return compare_same(Key, lhs, rhs);
    } else {
        return switch (@typeInfo(Key)) {
            .@"struct" => |_| {
                const suffix = blk: {
                    switch (@typeInfo(Other)) {
                        .pointer => |ptr| {
                            if (ptr.size == .slice) {
                                break :blk "slice_" ++ @typeName(ptr.child);
                            } else {
                                @compileError("todo");
                            }
                        },
                        else => break :blk @typeName(Other),
                    }
                };

                if (@hasDecl(Key, "cmp_with_" ++ &transform_struct_name(suffix))) {
                    return @field(Key, "cmp_with_" ++ &transform_struct_name(suffix))(&lhs, &rhs);
                } else {
                    @compileError("Custom structs must implement 'cmp_with_" ++ &transform_struct_name(suffix) ++ "' method. Type name is " ++ @typeName(Key));
                }
            },
            else => @compileError("Unsupported type for comparison: " ++ @typeName(Key)),
        };
    }
}

fn NodeRef(T: type) type {
    return packed struct {
        ptr: usize,

        pub fn new(p: ?*Node(T)) NodeRef(T) {
            return .{ .ptr = if (p) |pp| @intFromPtr(pp) else 0 };
        }

        pub fn nul() NodeRef(T) {
            return .{ .ptr = 0 };
        }

        pub fn is_null(self: *const NodeRef(T)) bool {
            return self.ptr == 0;
        }

        pub fn as_ptr(self: *NodeRef(T)) ?*Node(T) {
            if (self.ptr == 0) {
                return null;
            } else {
                return @ptrFromInt(self.ptr);
            }
        }
    };
}

fn Node(T: type) type {
    return struct {
        key: T,
        next: std.ArrayList(std.atomic.Value(NodeRef(T))),

        fn new(h: usize, val: T, alloc: Allocator) !Node(T) {
            var nxt = try std.ArrayList(std.atomic.Value(NodeRef(T))).initCapacity(alloc, h);

            nxt.appendNTimesAssumeCapacity(std.atomic.Value(NodeRef(T)).init(NodeRef(T).nul()), h);
            return .{ .key = val, .next = nxt };
        }

        fn next_at_lvl(self: *const Node(T), lvl: usize) NodeRef(T) {
            return self.next.items[lvl].load(.monotonic);
        }

        fn change_next_at_lvl_unsafe(self: *Node(T), lvl: usize, n: ?*Node(T)) void {
            self.next.items[lvl].store(NodeRef(T).new(n), .release);
        }

        fn try_change_next_at_lvl(self: *Node(T), lvl: usize, expected: ?*Node(T), n: *Node(T)) bool {
            return self.next.items[lvl].cmpxchgStrong(NodeRef(T).new(expected), NodeRef(T).new(n), .release, .monotonic) == null;
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
        prng: std.Random.DefaultPrng,

        const Self = @This();

        fn max_heigth(self: *Self) usize {
            return self.heigth.load(.monotonic);
        }

        fn random_lvl(self: *Self) usize {
            const FACTOR: usize = 25;

            var h: usize = 1;

            while (self.prng.random().int(u8) % 100 < FACTOR and h < MaxHeigth - 1) {
                h += 1;
            }

            return h;
        }

        fn find_insert_spot(self: *Self, K: type, val: K, h: usize, prev: []*Node(T), succ: []?*Node(T), to_lvl: usize) ?*Node(T) {
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

        /// Constructs new SkipList with `bound` memory usage.
        pub fn new(alloc: Allocator, bound: usize) !Self {
            var arena = try Arena.new(alloc, bound);
            const node = try Node(T).new(MaxHeigth, undefined, arena.allocator());

            return .{
                .head = node,
                .arena = arena,
                .heigth = std.atomic.Value(usize).init(1),
                .prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp())),
            };
        }

        /// Inserts new value into the SkipList
        pub fn insert(self: *Self, val: T) !void {
            const lvl = self.random_lvl();
            const node = try self.arena.allocator().create(Node(T));
            node.* = try Node(T).new(lvl, val, self.arena.allocator());

            var linked_lvl: usize = 0;

            std.debug.assert(lvl > 0);
            std.debug.assert(lvl < MaxHeigth);
            std.debug.assert(node.heigth() > 0);

            outer: while (true) {
                var prev: [MaxHeigth]*Node(T) = undefined;
                var succ: [MaxHeigth]?*Node(T) = undefined;
                const max_h = @max(self.max_heigth(), lvl);

                std.debug.assert(max_h < MaxHeigth);

                const found = self.find_insert_spot(T, val, max_h, prev[0..], succ[0..], linked_lvl);
                std.debug.assert(found == null);

                for (linked_lvl..lvl) |h| {
                    // If this fails, just retry the search. Even if h != 0, it's fine, since node can
                    // be found using 0th level. It only affects O(logN) for the search.
                    if (!prev[h].try_change_next_at_lvl(h, succ[h], node)) {
                        continue :outer;
                    }

                    node.change_next_at_lvl_unsafe(h, succ[h]);
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
    };
}

test "Basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try SkipList(usize).new(allocator, 1000);
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
    const rand = std.crypto.random;

    var list = try SkipList(usize).new(allocator, NumPush * NumPush);
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
