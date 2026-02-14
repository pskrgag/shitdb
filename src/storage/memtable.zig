const std = @import("std");
const skiplist = @import("skiplist");
const sstable = @import("sstable.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

var SeqCounter: u64 = 0;

const Type = enum(u1) {
    Delete = 0,
    Add = 1,
};

/// Key and Value packed together.
///
///    8b      key len bytes      8b          value len bytes      7b         1b
/// [key len] [     key     ] [value len] [      value       ] [seq-number] [type]
pub const KeyValue = struct {
    data: [*]const u8,

    pub fn as_key(self: *const KeyValue) []const u8 {
        const self_key_len: [*]const u64 = @ptrCast(@alignCast(self.data));

        return (self.data + 8)[0..self_key_len[0]];
    }

    fn value_len(self: *const KeyValue) usize {
        const self_key_len: [*]const u64 = @ptrCast(@alignCast(self.data));
        const to_skip = utils.round_up(self_key_len[0], 8) + 8;
        const self_value_len: [*]const u64 = @ptrCast(@alignCast(self.data + to_skip));

        return self_value_len[0];
    }

    pub fn full_size(self: *const KeyValue) usize {
        return utils.round_up(utils.round_up(self.value_len(), 8) + utils.round_up(self.as_key().len, 8) + 24, 8);
    }

    pub fn as_value(self: *const KeyValue) ?[]const u8 {
        if (self.as_type() == .Add) {
            const self_key_len: [*]const u64 = @ptrCast(@alignCast(self.data));
            const to_skip = utils.round_up(self_key_len[0], 8) + 8;
            const self_value_len: [*]const u64 = @ptrCast(@alignCast(self.data + to_skip));

            return (self.data + to_skip + 8)[0..self_value_len[0]];
        } else {
            return null;
        }
    }

    pub fn as_type(self: *const KeyValue) Type {
        const size = self.full_size();

        return @enumFromInt((self.data[size - 1] & (1 << 7)) >> 7);
    }

    fn is_tombstone(self: *const KeyValue) bool {
        return self.as_type() == .Delete;
    }

    fn new(key: []const u8, value: ?[]const u8, tp: Type, alloc: Allocator) !KeyValue {
        const key_len_rounded = utils.round_up(key.len, 8);
        const val_len = if (value) |val| val.len else 0;
        const value_len_rounded = utils.round_up(val_len, 8);
        const size = utils.round_up(key_len_rounded + value_len_rounded + 24, 8);

        if (size > sstable.BlockSize)
            return error.TooBig;

        const ptr = try alloc.alignedAlloc(u8, std.mem.Alignment.@"8", size);
        const seq = @atomicRmw(u64, &SeqCounter, .Add, 1, .monotonic);
        const seq_type = (seq & ~(@as(u64, 1) << 63)) | (@as(u64, @intFromEnum(tp)) << 63);

        @memmove(ptr.ptr + 0, @as(*const [8]u8, @ptrCast(&key.len)));
        @memmove(ptr.ptr + 8, key);

        @memmove(ptr.ptr + 8 + key_len_rounded, utils.data_as_u8_const_ptr(&val_len));

        // Optional value means tombstone
        if (value) |val|
            @memmove(ptr.ptr + 16 + key_len_rounded, val);

        @memmove(ptr.ptr + 16 + key_len_rounded + value_len_rounded, utils.data_as_u8_const_ptr(&seq_type));
        return .{ .data = ptr.ptr };
    }

    pub fn cmp(self: *const KeyValue, other: *const KeyValue) std.math.Order {
        const res = std.mem.order(u8, self.as_key(), other.as_key());

        // Removal should be first
        if (res == .eq) {
            return std.math.order(@intFromEnum(self.as_type()), @intFromEnum(other.as_type()));
        }

        return res;
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
        const kv = try KeyValue.new(key, value, Type.Add, self.arena.allocator());

        std.debug.assert(!kv.is_tombstone());
        _ = try self.table.insert(kv);
    }

    // Removes value from MemTable
    pub fn remove(self: *Self, key: []const u8) !void {
        const kv = try KeyValue.new(key, "", Type.Delete, self.arena.allocator());

        std.debug.assert(kv.is_tombstone());
        _ = try self.table.insert(kv);
    }

    /// Retries value from MemTable
    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        const found = try self.table.find_by_other([]const u8, key);

        if (found) |value| {
            return if (!value.is_tombstone()) value.as_value() else null;
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
    try tb.remove("hello");
    try std.testing.expectEqual(try tb.get("hello"), null);
}

test {
    _ = @import("sstable.zig");
}
