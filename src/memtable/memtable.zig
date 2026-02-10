const std = @import("std");
const skiplist = @import("skiplist");
const Allocator = std.mem.Allocator;

pub fn round_up(value: anytype, alignment: anytype) @TypeOf(value) {
    const mask = alignment - 1;
    return (value + mask) & ~@as(usize, mask);
}

/// Key and Value packed together.
///
///    8b      key len bytes      8b          value len bytes
/// [key len] [     key     ] [value len] [      value       ]
const KeyValue = struct {
    data: [*]u8,

    fn as_key(self: *const KeyValue) []const u8 {
        const self_key_len: [*]u64 = @ptrCast(@alignCast(self.data));
        return (self.data + 8)[0..self_key_len[0]];
    }

    fn as_value(self: *const KeyValue) []const u8 {
        const self_key_len: [*]u64 = @ptrCast(@alignCast(self.data));
        const to_skip = round_up(self_key_len[0], 8) + 8;
        const self_value_len: [*]u64 = @ptrCast(@alignCast(self.data + to_skip));

        return (self.data + to_skip + 8)[0..self_value_len[0]];
    }

    fn new(key: []const u8, value: []const u8, alloc: Allocator) !KeyValue {
        const key_len_rounded = round_up(key.len, 8);
        const value_len_rounded = round_up(value.len, 8);
        const size = key_len_rounded + value_len_rounded + 8 * 2;
        const ptr = try alloc.alignedAlloc(u8, std.mem.Alignment.@"8", size);

        @memmove(ptr.ptr + 0, @as(*const [8]u8, @ptrCast(&key.len)));
        @memmove(ptr.ptr + 8, key);

        @memmove(ptr.ptr + 8 + key_len_rounded, @as(*const [8]u8, @ptrCast(&value.len)));
        @memmove(ptr.ptr + 16 + key_len_rounded, value);
        return .{ .data = ptr.ptr };
    }

    pub fn cmp(self: *const KeyValue, other: *const KeyValue) std.math.Order {
        return std.mem.order(u8, self.as_key(), other.as_key());
    }

    pub fn cmp_with_slice_u8(self: *const KeyValue, other: *const []const u8) std.math.Order {
        return std.mem.order(u8, self.as_key(), other.*);
    }
};

/// MemTable that holds newly added key-value pairs
pub const MemTable = struct {
    table: skiplist.SkipList(KeyValue),
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn new(alloc: Allocator) !*Self {
        var self = try alloc.create(Self);
        const arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        self.arena = arena;
        self.table = try skiplist.SkipList(KeyValue).new(self.arena.allocator());

        return self;
    }

    /// Inserts new value into MemTable
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const kv = try KeyValue.new(key, value, self.arena.allocator());

        _ = try self.table.insert(kv);
    }

    /// Retries value from MemTable
    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        const found = try self.table.find_by_other([]const u8, key);

        if (found) |value| {
            return value.as_value();
        } else {
            return null;
        }
    }
};

test "Basic test" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tb = try MemTable.new(allocator);
    try tb.put("hello", "world");
    try std.testing.expectEqualSlices(u8, try tb.get("hello") orelse @panic(""), "world");
    try std.testing.expectEqual(try tb.get("world"), null);
}
