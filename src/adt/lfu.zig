const std = @import("std");
const List = std.DoublyLinkedList;
const ListNode = std.DoublyLinkedList.Node;
const HashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;

fn Node(Key: type, Value: type) type {
    return struct {
        node: ListNode,
        key: Key,
        value: Value,
        freq: usize,

        const Self = @This();

        fn new(key: Key, value: Value, alloc: Allocator) !*Self {
            const res = try alloc.create(Self);

            res.node = .{};
            res.key = key;
            res.value = value;
            res.freq = 0;

            return res;
        }
    };
}

pub fn Lfu(Key: type, Value: type) type {
    return struct {
        const NodeMap = HashMap(Key, *Node(Key, Value));
        const FreqMap = HashMap(Key, *FreqList);

        nodes: NodeMap,
        freq: FreqMap,
        capacity: usize,
        min_freq: usize = 0,
        freq_nodes: List,

        // To support removal, it's required to find next freqlist to update min_freq.
        const FreqList = struct {
            list: List = .{},
            freq: usize,
            node: ListNode = .{},
        };

        const Self = @This();

        pub fn init(cap: usize, alloc: Allocator) Self {
            return .{
                .capacity = cap,
                .nodes = NodeMap.init(alloc),
                .freq = FreqMap.init(alloc),
                .freq_nodes = .{},
            };
        }

        pub fn get(self: *Self, val: Key, alloc: Allocator) !?*const Value {
            if (self.nodes.get(val)) |node| {
                const prev = self.remove_from_list(node, alloc);

                node.freq += 1;
                try self.append_to_freq_list(node.freq, prev, node, alloc);

                return &node.value;
            } else {
                return null;
            }
        }

        pub fn put(self: *Self, key: Key, value: Value, alloc: Allocator) !void {
            std.debug.assert(self.nodes.unmanaged.size <= self.capacity);

            if (self.nodes.get(key)) |k| {
                k.value = value;
            } else {
                const node = try Node(Key, Value).new(key, value, alloc);
                errdefer alloc.destroy(node);

                if (self.nodes.unmanaged.size == self.capacity) {
                    self.evict_one(alloc);
                }

                try self.nodes.put(key, node);
                errdefer {
                    const res = self.nodes.remove(key);
                    std.debug.assert(res);
                }

                try self.append_to_freq_list(0, null, node, alloc);
            }
        }

        pub fn remove(self: *Self, key: Key, alloc: Allocator) bool {
            if (self.nodes.get(key)) |k| {
                _ = self.remove_from_list(k, alloc);

                _ = self.nodes.remove(key);
                alloc.destroy(k);
                return true;
            } else {
                return false;
            }
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            var f_iter = self.freq.iterator();

            while (f_iter.next()) |lst| {
                alloc.destroy(lst.value_ptr.*);
            }

            self.freq.deinit();

            var n_iter = self.nodes.iterator();
            while (n_iter.next()) |lst| {
                alloc.destroy(lst.value_ptr.*);
            }
            self.nodes.deinit();
        }

        fn append_to_freq_list(
            self: *Self,
            freq: usize,
            prev: ?*ListNode,
            node: *Node(Key, Value),
            alloc: Allocator,
        ) !void {
            var list = self.freq.get(freq);

            if (list == null) {
                const new = try alloc.create(FreqList);
                errdefer alloc.destroy(new);

                new.* = .{
                    .freq = freq,
                };
                try self.freq.put(freq, new);
                list = new;

                if (prev) |p| {
                    // Lookup previous freq node and insert after it.
                    self.freq_nodes.insertAfter(p, &new.node);
                } else {
                    // It should be in the tail of the list, since it's the lowest freq
                    self.freq_nodes.prepend(&new.node);
                    std.debug.assert(prev == null);
                }
            }

            if (freq < self.min_freq)
                self.min_freq = freq;

            list.?.list.append(&node.node);
        }

        fn remove_from_list(self: *Self, node: *Node(Key, Value), alloc: Allocator) ?*ListNode {
            const old_list = self.freq.get(node.freq).?;
            var prev: ?*ListNode = undefined;

            old_list.list.remove(&node.node);
            if (old_list.list.first == null) {
                const res = self.freq.remove(old_list.freq);

                std.debug.assert(res);

                if (node.freq == self.min_freq) {
                    if (old_list.node.next) |nxt| {
                        self.min_freq = @as(*FreqList, @fieldParentPtr("node", nxt)).freq;
                    }
                }

                prev = old_list.node.prev;
                self.freq_nodes.remove(&old_list.node);

                alloc.destroy(old_list);
            } else {
                prev = &old_list.node;
            }

            return prev;
        }

        fn evict_one(self: *Self, alloc: Allocator) void {
            const last_list = self.freq.get(self.min_freq).?;
            const first: *Node(Key, Value) = @fieldParentPtr("node", last_list.list.first.?);
            const res = self.nodes.remove(first.key);

            std.debug.assert(res);
            _ = self.remove_from_list(first, alloc);
            alloc.destroy(first);
        }
    };
}

test "Basic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cap = 10;
    var lfu = Lfu(usize, usize).init(cap, alloc);
    defer lfu.deinit(alloc);

    for (0..cap) |i| {
        try lfu.put(i, i, alloc);
    }

    for (0..cap) |i| {
        try std.testing.expectEqual((try lfu.get(i, alloc)).?.*, i);
    }

    // 0th one is the oldest, so it should be evicted.
    {
        try lfu.put(11, 11, alloc);
        try std.testing.expectEqual(try lfu.get(0, alloc), null);
    }
}

test "Remove min_freq update" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cap = 10;
    var lfu = Lfu(usize, usize).init(cap, alloc);
    defer lfu.deinit(alloc);

    try lfu.put(0, 0, alloc);
    try lfu.put(1, 1, alloc);

    try std.testing.expectEqual(lfu.min_freq, 0);

    {
        // Move to 1st
        try std.testing.expectEqual((try lfu.get(1, alloc)).?.*, 1);
        // Move to 2nd
        try std.testing.expectEqual((try lfu.get(1, alloc)).?.*, 1);

        // Remove first one
        try std.testing.expectEqual(lfu.min_freq, 0);
        try std.testing.expect(lfu.remove(0, alloc));
        try std.testing.expectEqual(lfu.min_freq, 2);

        // 1 must be still there
        try std.testing.expectEqual((try lfu.get(1, alloc)).?.*, 1);
        try std.testing.expectEqual((try lfu.get(0, alloc)), null);
    }

    {
        try lfu.put(2, 2, alloc);
        try std.testing.expectEqual(lfu.min_freq, 0);

        try std.testing.expectEqual((try lfu.get(1, alloc)).?.*, 1);
        try std.testing.expectEqual((try lfu.get(2, alloc)).?.*, 2);
        try std.testing.expect(lfu.remove(2, alloc));
        try std.testing.expectEqual(4, lfu.min_freq);
    }

    {
        try lfu.put(2, 2, alloc);
        try lfu.put(3, 3, alloc);

        try std.testing.expectEqual(0, lfu.min_freq);
        try std.testing.expectEqual((try lfu.get(3, alloc)).?.*, 3);
        try std.testing.expectEqual(0, lfu.min_freq);
        try std.testing.expect(lfu.remove(2, alloc));
        try std.testing.expectEqual(1, lfu.min_freq);
    }
}
