const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

fn is_primitive_type(Key: type) bool {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => true,
        else => false,
    };
}

fn compare_same(Key: type, lhs: Key, rhs: Key) std.math.Order {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => std.math.order(lhs, rhs),
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
                        else => break :blk @typeInfo(Other),
                    }
                };

                if (@hasDecl(Key, "cmp_with_" ++ suffix)) {
                    return @field(Key, "cmp_with_" ++ suffix)(&lhs, &rhs);
                } else {
                    @compileError("Custom structs must implement 'cmp_with_" ++ suffix ++ "' method" ++ @typeName(Key));
                }
            },
            else => @compileError("Unsupported type for comparison: " ++ @typeName(Key)),
        };
    }
}

fn Node(Key: type) type {
    return struct {
        next: ArrayList(NodeRef),
        key: Key,

        const NodeRef = ?*Node(Key);
        const NodePtr = *Node(Key);
        const Self = @This();

        fn heigth(self: *const Self) usize {
            return self.next.items.len;
        }

        fn random_lvl(rng: std.Random) usize {
            const FACTOR: usize = 25;

            var h: usize = 1;

            while (rng.int(u8) % 100 < FACTOR) {
                h += 1;
            }

            return h;
        }

        fn new_random(rng: std.Random, key: Key, alloc: Allocator) !NodePtr {
            const lvl = Self.random_lvl(rng);
            var next = try std.ArrayList(NodeRef).initCapacity(alloc, lvl);
            try next.appendNTimes(alloc, null, lvl);

            const new_ptr = try alloc.create(Self);
            const new = Self{ .key = key, .next = next };

            new_ptr.* = new;
            return new_ptr;
        }
    };
}

pub fn Iterator(Key: type) type {
    return struct {
        current: ?*Node(Key),

        const Self = @This();

        fn new(root: ?*Node(Key)) Self {
            return .{ .current = root };
        }

        pub fn next(self: *Self) ?*const Key {
            if (self.current) |cur| {
                const res = &cur.key;

                self.current = cur.next.items[0];
                return res;
            } else {
                return null;
            }
        }
    };
}

pub fn SkipList(Key: type) type {
    return struct {
        head: ArrayList(NodeRef),
        size: usize,
        alloc: Allocator,
        prng: std.Random.DefaultPrng,

        const Self = @This();
        const NodeRef = ?NodePtr;
        const NodePtr = *Node(Key);

        const Cursor = struct {
            list: *SkipList(Key),
            node: NodeRef,
            parents: ArrayList(?*NodeRef),

            fn insert(self: *const Cursor, node: NodePtr) !void {
                // Wire node at parents
                for (0..@min(self.list.heigth(), node.heigth())) |h| {
                    const prev_node = self.parents.items[h].?;

                    node.next.items[h] = prev_node.*;
                    prev_node.* = node;
                }

                // If node's height is bigger than head, wire it to the head
                if (node.heigth() > self.list.heigth()) {
                    const diff = node.heigth() - self.list.heigth();
                    const old_head = self.list.heigth();

                    try self.list.head.appendNTimes(self.list.alloc, null, diff);

                    for (old_head..node.heigth()) |h| {
                        self.list.head.items[h] = node;
                    }
                }
            }

            fn remove(self: *const Cursor) bool {
                if (self.node) |node| {
                    std.debug.assert(node.heigth() <= self.list.heigth());

                    for (0..node.heigth()) |h| {
                        const prev_node = self.parents.items[h].?;

                        prev_node.* = node.next.items[h];
                    }

                    self.list.alloc.destroy(node);
                    return true;
                } else {
                    return false;
                }
            }
        };

        /// Constructs empty Skiplist
        pub fn new(alloc: Allocator) !Self {
            return .{
                .head = try ArrayList(NodeRef).initCapacity(alloc, 0),
                .size = 0,
                .alloc = alloc,
                .prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp())),
            };
        }

        /// Iterator over keys
        pub fn iterator(self: *const Self) Iterator(Key) {
            return Iterator(Key).new(self.head.items[0]);
        }

        /// Inserts key value pair into Skiplist. If specified key is already present, key will be updated and old
        /// one will be returned
        pub fn insert(self: *Self, key: Key) !?Key {
            const cur = try self.cursor(Key, key);

            if (cur.node) |*node| {
                const old = node.*.key;

                // If node was found, update it with new value
                node.*.key = key;
                return old;
            } else {
                // ... Otherwise allocate new one and wire it at iterator
                const new_node = try Node(Key).new_random(self.prng.random(), key, self.alloc);

                try cur.insert(new_node);
                self.size += 1;
                return null;
            }
        }

        /// Removes node from the list and returns value associated with it
        pub fn remove(self: *Self, key: Key) !bool {
            const cur = try self.cursor(Key, key);

            if (cur.remove()) {
                self.size -= 1;
                return true;
            } else {
                return false;
            }
        }

        /// Finds key in the skiplist
        pub fn contains(self: *Self, key: Key) !bool {
            const cur = try self.cursor(Key, key);

            return cur.node != null;
        }

        /// Finds key in the skiplist
        pub fn find_by_other(self: *Self, Other: type, key: Other) !?*const Key {
            const cur = try self.cursor(Other, key);

            if (cur.node) |node| {
                return &node.key;
            } else {
                return null;
            }
        }

        fn heigth(self: *const Self) usize {
            return self.head.items.len;
        }

        fn cursor(self: *Self, Other: type, key: Other) !Cursor {
            var iter = &self.head;
            var parents = try ArrayList(?*NodeRef).initCapacity(self.alloc, self.heigth());
            var node: NodeRef = null;
            var lvl = self.heigth();

            // It has enough capacity
            parents.appendNTimes(self.alloc, null, self.heigth()) catch unreachable;

            while (lvl > 0) {
                lvl -= 1;

                while (iter.items[lvl]) |next| {
                    const cmp = compare_keys(Key, Other, next.key, key);

                    // Key is greater. Stop search at this level
                    if (cmp != .eq and cmp != .lt) {
                        break;
                    }

                    // The exact node was found.
                    if (cmp == .eq) {
                        for (0..lvl) |i| {
                            parents.items[i] = &iter.items[i];
                        }

                        node = next;
                        break;
                    }

                    iter = &next.next;
                }

                parents.items[lvl] = &iter.items[lvl];
            }

            return Cursor{ .node = node, .parents = parents, .list = self };
        }

        fn debug_check_sanity(self: *const Self) void {
            const head_heigth = self.heigth();

            for (0..head_heigth) |h| {
                // Check sanity at each lvl. Each node must be less than its next.
                if (self.head.items[h]) |lvl_head| {
                    var iter: NodeRef = lvl_head;

                    while (iter) |current| {
                        if (current.next.items[h]) |next| {
                            std.debug.assert(compare_keys(Key, Key, current.key, next.key) == .lt);
                        }

                        iter = current.next.items[h];
                    }
                }
            }
        }

        pub fn as_sorted_array(self: *const Self, alloc: Allocator) !ArrayList(Key) {
            var res = try ArrayList(Key).initCapacity(alloc, 0);

            if (self.head.items[0]) |lvl_head| {
                var iter: NodeRef = lvl_head;

                while (iter) |current| {
                    try res.append(alloc, current.key);
                    iter = current.next.items[0];
                }
            }

            return res;
        }
    };
}

test "Comparator" {
    _ = compare_keys(u8, u8, 1, 2);

    // TODO: fix comparator
    // _ = compare_keys([]const u8, []const u8, "ab", "cd");
}

test "Insert stuff" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try SkipList(u8).new(allocator);

    // Try in order
    try std.testing.expectEqual(try list.insert(1), null);
    try std.testing.expectEqual(try list.insert(1), 1);
    list.debug_check_sanity();

    try std.testing.expectEqual(try list.insert(2), null);
    try std.testing.expectEqual(try list.insert(2), 2);
    list.debug_check_sanity();

    try std.testing.expectEqual(try list.insert(3), null);
    try std.testing.expectEqual(try list.insert(3), 3);
    list.debug_check_sanity();

    // Try out of order
    try std.testing.expectEqual(try list.insert(10), null);
    try std.testing.expectEqual(try list.insert(10), 10);
    list.debug_check_sanity();

    try std.testing.expectEqual(try list.insert(5), null);
    try std.testing.expectEqual(try list.insert(5), 5);
    list.debug_check_sanity();

    try std.testing.expectEqual(try list.insert(0), null);
    try std.testing.expectEqual(try list.insert(0), 0);
    list.debug_check_sanity();

    const arr = try list.as_sorted_array(allocator);
    try std.testing.expectEqualSlices(u8, arr.items, &[_]u8{ 0, 1, 2, 3, 5, 10 });
}

test "Insert remove stuff" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try SkipList(u8).new(allocator);

    try std.testing.expectEqual(try list.insert(1), null);
    try std.testing.expectEqual(try list.insert(1), 1);
    try std.testing.expectEqual(try list.contains(1), true);
    list.debug_check_sanity();

    for (0..2) |_| {
        try std.testing.expectEqual(try list.insert(2), null);
        try std.testing.expectEqual(try list.insert(2), 2);
        try std.testing.expectEqual(try list.contains(2), true);
        list.debug_check_sanity();

        try std.testing.expectEqual(try list.remove(2), true);
        try std.testing.expectEqual(try list.remove(2), false);
        try std.testing.expectEqual(try list.contains(2), false);
        list.debug_check_sanity();
    }

    try std.testing.expectEqual(try list.remove(1), true);

    try std.testing.expectEqual(try list.insert(1), null);
    try std.testing.expectEqual(try list.insert(1), 1);
    try std.testing.expectEqual(try list.contains(1), true);
    // try std.testing.expectEqualDeep((try list.find_by_other(u8, 1)), &1);
    list.debug_check_sanity();
}
