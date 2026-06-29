const std = @import("std");
const skiplist = @import("skiplist");
const Arena = skiplist.ArenaBouned;
const Allocator = std.mem.Allocator;
const Node = std.DoublyLinkedList.Node;
const HashTableTest = @import("test_utils").HashTableTest;
const Value = std.atomic.Value;
const SkiplistNode = skiplist.Node;
const sstable = @import("sstable.zig");

const Type = enum(u1) {
    Delete = 0,
    Add = 1,
};

pub const KVSeq = packed struct(usize) {
    value: usize,

    pub fn init(v: usize) KVSeq {
        return .{ .value = v };
    }

    pub fn get(self: *const KVSeq) usize {
        return self.value;
    }
};

pub const KeyValueOwned = struct {
    data: []const u8,

    pub fn from_kv(kv: KeyValue, alloc: Allocator) !KeyValueOwned {
        const full_size = kv.full_size();
        const ptr = try alloc.alloc(u8, full_size);

        @memcpy(ptr, kv.as_slice());
        return .{ .data = ptr };
    }

    pub fn as_kv(self: *const KeyValueOwned) KeyValue {
        return KeyValue{ .data = self.data.ptr };
    }

    pub fn deinit(self: *KeyValueOwned, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

/// Key and Value packed together.
///
///    8b      key len bytes        8b                8b        value len bytes
/// [key len] [     key     ] [type + seq-number] [value len] [      value       ]
pub const KeyValue = struct {
    data: [*]const u8,

    const IntSize = @sizeOf(u64);

    fn read_u64(data: [*]const u8, offset: usize) u64 {
        return std.mem.readInt(u64, (data + offset)[0..IntSize], .little);
    }

    fn key_len(self: *const KeyValue) usize {
        return read_u64(self.data, 0);
    }

    pub fn as_key(self: *const KeyValue) []const u8 {
        return (self.data + IntSize)[0..self.key_len()];
    }

    pub fn calculate_size(key: []const u8, value: ?[]const u8) usize {
        const val_len = if (value) |val| val.len else 0;

        return IntSize + key.len + IntSize + val_len + IntSize;
    }

    pub fn parse(data: []const u8) ?KeyValue {
        var iter = data;

        // Parse key
        {
            if (data.len < @sizeOf(u64)) {
                return null;
            }

            const key_size = std.mem.readInt(u64, iter[0..][0..@sizeOf(u64)], .little);
            iter = iter[@sizeOf(u64)..];

            if (iter.len < key_size) {
                return null;
            }
            iter = iter[key_size..];
        }

        // Parse seq+value
        if (iter.len < 8) {
            return null;
        }

        iter = iter[IntSize..];

        // Parse value
        {
            if (iter.len < @sizeOf(u64)) {
                return null;
            }

            const value_size = std.mem.readInt(u64, iter[0..][0..@sizeOf(u64)], .little);
            iter = iter[@sizeOf(u64)..];

            if (iter.len < value_size) {
                return null;
            }
            iter = iter[value_size..];
        }

        return .{ .data = data.ptr };
    }

    fn value_len(self: *const KeyValue) usize {
        return read_u64(self.data, IntSize + self.key_len() + IntSize);
    }

    pub fn full_size(self: *const KeyValue) usize {
        return IntSize + self.key_len() + IntSize + self.value_len() + IntSize;
    }

    pub fn as_value(self: *const KeyValue) ?[]const u8 {
        if (self.as_type() == .Add) {
            const value_offset = IntSize + self.key_len() + IntSize + IntSize;
            return (self.data + value_offset)[0..self.value_len()];
        } else {
            return null;
        }
    }

    pub fn as_slice(self: *const KeyValue) []const u8 {
        return (self.data)[0..self.full_size()];
    }

    pub fn as_type(self: *const KeyValue) Type {
        const offset = IntSize + self.key_len();
        const seqtype = read_u64(self.data, offset);

        return @enumFromInt(seqtype >> 63);
    }

    pub fn as_seq(self: *const KeyValue) KVSeq {
        const offset = IntSize + self.key_len();
        const seqtype = read_u64(self.data, offset);

        return KVSeq.init(seqtype & ((1 << 63) - 1));
    }

    fn is_tombstone(self: *const KeyValue) bool {
        return self.as_type() == .Delete;
    }

    fn new(key: []const u8, value: ?[]const u8, seq: KVSeq, tp: Type, alloc: Allocator) !KeyValue {
        const val_len = if (value) |val| val.len else 0;
        const size = IntSize + key.len + IntSize + val_len + IntSize;

        if (size > sstable.BlockSize)
            return error.TooBig;

        const ptr = try alloc.alignedAlloc(u8, std.mem.Alignment.@"8", size);
        const seq_type = (seq.get() & ~(@as(u64, 1) << 63)) | (@as(u64, @intFromEnum(tp)) << 63);

        @memmove(ptr.ptr + 0, @as(*const [8]u8, @ptrCast(&key.len)));
        @memmove(ptr.ptr + IntSize, key);
        @memmove(ptr.ptr + IntSize + key.len, @as(*const [8]u8, @ptrCast(&seq_type)));
        @memmove(ptr.ptr + IntSize + key.len + IntSize, @as(*const [8]u8, @ptrCast(&val_len)));

        // Optional value means tombstone
        if (value) |val|
            @memmove(ptr.ptr + IntSize + key.len + IntSize + IntSize, val);

        return .{ .data = ptr.ptr };
    }

    pub fn cmp(self: *const KeyValue, other: *const KeyValue) std.math.Order {
        const res = std.mem.order(u8, self.as_key(), other.as_key());

        if (res == .eq) {
            return std.math.order(self.as_seq().get(), other.as_seq().get());
        } else {
            return res;
        }
    }

    pub fn cmp_with_memtable_FindKey(self: *const KeyValue, other: *const FindKey) std.math.Order {
        const res = std.mem.order(u8, self.as_key(), other.key);

        if (res == .eq) {
            return std.math.order(self.as_seq().get(), other.seq.get());
        } else {
            return res;
        }
    }
};

const FindKey = struct {
    key: []const u8,
    seq: KVSeq,
};

pub const MemTableOpts = struct {
    memtable_size: usize = 1 << 20,
};

/// Result of the search
pub const GetResult = union(enum) {
    Found: []u8,
    Removed: void,
    NotFound: void,

    pub fn as_key(self: *const GetResult) ?[]const u8 {
        return switch (self.*) {
            .Found => |k| k,
            else => null,
        };
    }
};

/// Pre-allocated slot in memtable.
pub const Slot = struct {
    node: *SkiplistNode(KeyValue),
};

/// MemTable that holds newly added key-value pairs
pub const MemTable = struct {
    table: skiplist.SkipList(KeyValue),
    opts: MemTableOpts,
    arena: Arena,
    max_seq: Value(KVSeq),
    size: Value(usize),

    const Self = @This();

    pub fn new(alloc: Allocator, io: std.Io, opts: MemTableOpts) !Self {
        const arena = try Arena.new(alloc, opts.memtable_size);

        const table = try skiplist.SkipList(KeyValue).new(alloc, io);
        return .{
            .opts = opts,
            .arena = arena,
            .table = table,
            .max_seq = Value(KVSeq).init(KVSeq.init(0)),
            .size = Value(usize).init(opts.memtable_size),
        };
    }

    fn update_max_seq(self: *Self, seq: KVSeq) void {
        while (true) {
            const current = self.max_seq.load(.monotonic);

            // This may happen in case of OOO write.
            if (current.get() > seq.get())
                return;

            const res = self.max_seq.cmpxchgWeak(current, seq, .monotonic, .monotonic);

            if (res == null)
                break;
        }
    }

    fn map_kv_error(
        self: *Self,
        kv: anyerror!KeyValue,
        key: []const u8,
        value: ?[]const u8,
    ) !KeyValue {
        const res = kv catch |err| {
            if (err == error.OutOfMemory) {
                const full_size = KeyValue.calculate_size(key, value);

                if (full_size > self.opts.memtable_size)
                    return error.TooBig;

                return error.MemTableFull;
            }

            return err;
        };

        return res;
    }

    /// Creates a new KV using internal bounded arena
    pub fn allocate_put_slot(
        self: *Self,
        key: []const u8,
        value: []const u8,
        seq: KVSeq,
    ) !Slot {
        if (value.len == 0)
            return error.InvalidValue;

        const kv = try self.map_kv_error(
            KeyValue.new(key, value, seq, Type.Add, self.arena.allocator()),
            key,
            value,
        );
        return .{ .node = try self.table.preallocate_node(kv) };
    }

    pub fn allocate_remove_slot(self: *Self, key: []const u8, seq: KVSeq) !Slot {
        const kv = try self.map_kv_error(
            KeyValue.new(key, null, seq, Type.Delete, self.arena.allocator()),
            key,
            null,
        );

        return .{ .node = try self.table.preallocate_node(kv) };
    }

    /// Puts kv previously constructed by MemTable::create_kv
    pub fn commit_slot(self: *Self, slot: Slot) !void {
        try self.table.insert_node(slot.node);
        self.update_max_seq(slot.node.key.as_seq());
    }

    /// Inserts new value into MemTable
    pub fn put(self: *Self, key: []const u8, value: []const u8, seq: KVSeq) !void {
        if (value.len == 0)
            return error.InvalidValue;

        const kv = try self.allocate_put_slot(key, value, seq);
        return self.commit_slot(kv);
    }

    // Removes value from MemTable
    pub fn remove(self: *Self, key: []const u8, seq: KVSeq) !void {
        const kv = try self.allocate_remove_slot(key, seq);
        return self.commit_slot(kv);
    }

    /// Retries value from MemTable
    pub fn get(self: *Self, key: []const u8, seq: KVSeq, alloc: Allocator) !GetResult {
        const found = self.table.find_greater_or_eq(FindKey, FindKey{ .seq = seq, .key = key });

        if (found) |value| {
            const the_same_key = std.mem.eql(u8, value.as_key(), key);

            if (the_same_key) {
                if (value.is_tombstone()) {
                    return .Removed;
                } else {
                    const res = try alloc.alloc(u8, value.as_value().?.len);

                    @memcpy(res, value.as_value().?);
                    return GetResult{ .Found = res };
                }
            }
        }

        return .NotFound;
    }

    /// Returns maximum key
    pub fn max(self: *const Self) ?KeyValue {
        const res = self.table.max();

        return if (res) |r| r.* else null;
    }

    /// Returns minimal key
    pub fn min(self: *const Self) ?KeyValue {
        const res = self.table.min();

        return if (res) |r| r.* else null;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.table.deinit();
        self.arena.deinit(alloc);
    }
};

test "Basic test" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    var tb = try MemTable.new(allocator, std.testing.io, .{});
    defer tb.deinit(allocator);

    {
        try tb.put("hello", "world", KVSeq.init(0));
        var val = try tb.get("hello", KVSeq.init(0), allocator);
        defer allocator.free(val.as_key().?);
        try std.testing.expectEqualSlices(u8, val.as_key().?, "world");
    }

    {
        const val = try tb.get("world", KVSeq.init(1), allocator);
        switch (val) {
            .NotFound => {},
            else => {
                std.debug.print("Unexpected result {any}\n", .{val});
                @panic("");
            },
        }
    }

    try tb.remove("hello", KVSeq.init(2));

    {
        const val = try tb.get("hello", KVSeq.init(2), allocator);
        switch (val) {
            .Removed => {},
            else => @panic("Wrong"),
        }
    }

    {
        // Try to insert one more time
        try tb.put("hello", "bob", KVSeq.init(3));
        const val = try tb.get("hello", KVSeq.init(3), allocator);
        defer allocator.free(val.as_key().?);
        try std.testing.expectEqualSlices(u8, val.as_key().?, "bob");
    }
}

test "Try overwriting the key" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    var tb = try MemTable.new(allocator, std.testing.io, .{});
    defer tb.deinit(allocator);

    try tb.put("hello", "world", KVSeq.init(0));
    try tb.put("hello", "bob", KVSeq.init(1));

    {
        var val = try tb.get("hello", KVSeq.init(1), allocator);
        defer allocator.free(val.as_key().?);
        try std.testing.expectEqualSlices(u8, val.as_key().?, "bob");
    }

    {
        try tb.put("hello", "bibi", KVSeq.init(3));
        var val = try tb.get("hello", KVSeq.init(3), allocator);
        defer allocator.free(val.as_key().?);
        try std.testing.expectEqualSlices(u8, val.as_key().?, "bibi");
    }

    {
        try tb.put("hello", "kiki", KVSeq.init(4));
        var val = try tb.get("hello", KVSeq.init(4), allocator);
        defer allocator.free(val.as_key().?);
        try std.testing.expectEqualSlices(u8, val.as_key().?, "kiki");
    }

    {
        try tb.remove("hello", KVSeq.init(5));
        const val = try tb.get("hello", KVSeq.init(5), allocator);
        switch (val) {
            .Removed => {},
            else => @panic("Wrong"),
        }
    }
}

test "HashTable equivalence" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tb = try MemTable.new(allocator, std.testing.io, .{});
    try HashTableTest.test_hash_table_equavalance(tb, false, 1000);
}
