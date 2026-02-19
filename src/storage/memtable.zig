const std = @import("std");
const skiplist = @import("skiplist");
const Arena = skiplist.Arena;
const sstable = @import("sstable.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

var SeqCounter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const Type = enum(u1) {
    Delete = 0,
    Add = 1,
};

/// Key and Value packed together.
///
///    8b      key len bytes      8b          value len bytes    1b        7b
/// [key len] [     key     ] [value len] [      value       ] [type] [seq-number]
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

    pub fn as_seq(self: *const KeyValue) usize {
        const size = self.full_size();
        const last_u64: [*]const u64 = @ptrCast(@alignCast(self.data + (size - 8)));

        return last_u64[0] & ((1 << 63) - 1);
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
        const seq = SeqCounter.fetchAdd(1, .monotonic);
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

        if (res == .eq) {
            return std.math.order(self.as_seq(), other.as_seq());
        } else {
            return res;
        }
    }

    pub fn cmp_with_memtable_FindKey(self: *const KeyValue, other: *const FindKey) std.math.Order {
        const res = std.mem.order(u8, self.as_key(), other.key);

        if (res == .eq) {
            return std.math.order(self.as_seq(), other.seq);
        } else {
            return res;
        }
    }
};

const FindKey = struct {
    key: []const u8,
    seq: usize,
};

pub const MemTableOpts = struct {
    memtable_size: usize,

    fn default() MemTableOpts {
        return .{ .memtable_size = 1 << 20 };
    }
};

/// MemTable that holds newly added key-value pairs
pub const MemTable = struct {
    table: skiplist.SkipList(KeyValue),
    arena: Arena,

    const Self = @This();

    pub fn new(alloc: Allocator, user_opts: ?MemTableOpts) !*Self {
        const opts = user_opts orelse MemTableOpts.default();
        var self = try alloc.create(Self);

        self.arena = try Arena.new(alloc, opts.memtable_size);

        // TODO: oh, this is weird place. Actually it would be cool to reuse self.arena. However, it's not
        // really fair, since skiplist is utility memory and should not really count. Node itself can take a lot
        // of memory.
        //
        // So here I just try to guess enough memory for skiplist itself.
        self.table = try skiplist.SkipList(KeyValue).new(alloc, opts.memtable_size * 10);
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
        const found = self.table.find_greater_or_eq(FindKey, FindKey{ .seq = SeqCounter.load(.monotonic), .key = key });

        if (found) |value| {
            return if (std.mem.eql(u8, value.as_key(), key) and !value.is_tombstone()) value.as_value() else null;
        } else {
            return null;
        }
    }
};

test "Basic test" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tb = try MemTable.new(allocator, null);

    try tb.put("hello", "world");
    try std.testing.expectEqualSlices(u8, try tb.get("hello") orelse @panic(""), "world");
    try std.testing.expectEqual(null, try tb.get("world"));
    try tb.remove("hello");
    try std.testing.expectEqual(null, try tb.get("hello"));
}

const Step = union(enum) {
    Insert: struct {
        key: std.ArrayList(u8),
        value: std.ArrayList(u8),
    },
    Remove: struct {
        key: std.ArrayList(u8),
    },

    fn dump(self: *const Step) void {
        // TODO
        _ = self;
    }
};

fn random_step(rng: std.Random, alloc: Allocator, values: *InsertedValues) !Step {
    const enum_info = @typeInfo(Step).@"union";
    const count = enum_info.fields.len;
    const step = rng.int(u8) % count;
    const remove_exisiting = rng.int(u8) % 2;

    const random_key = try generate_random_text(rng, 0, 30, alloc);
    const value = try generate_random_text(rng, 0, 30, alloc);

    try values.append(alloc, .{ .key = random_key.items, .value = value.items });

    return switch (step) {
        0 => Step{
            .Insert = .{
                .key = random_key,
                .value = value,
            },
        },
        1 => Step{
            .Remove = .{
                .key = blk: {
                    if (remove_exisiting == 1) {
                        const idx = rng.int(usize) % values.items.len;
                        var new_arr = try std.ArrayList(u8).initCapacity(alloc, 0);

                        try new_arr.appendSlice(alloc, values.items[idx].key);
                        break :blk new_arr;
                    } else {
                        break :blk random_key;
                    }
                },
            },
        },
        else => @panic(""),
    };
}

fn random_size(rng: std.Random, start: usize, end: usize) usize {
    const random = rng.int(usize);
    const range_len = end - start;

    return start + (random % range_len);
}

fn generate_random_text(rng: std.Random, start: usize, end: usize, alloc: Allocator) !std.ArrayList(u8) {
    const size = random_size(rng, start, end);
    var res = try std.ArrayList(u8).initCapacity(alloc, size);

    for (0..size) |_| {
        // Take lower-case ascii chars: a-z. The range is 97 - 122.
        const range_len = 122 - 97 + 1;
        try res.append(alloc, rng.int(u8) % range_len + 97);
    }

    return res;
}

const InsertedValues = std.ArrayList(struct { key: []const u8, value: []const u8 });

test "HashTable equivalence" {
    const debug = false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seed = std.time.timestamp();
    var prng = std.Random.DefaultPrng.init(@bitCast(seed));
    const rng = prng.random();

    var tb = try MemTable.new(allocator, null);
    var table = std.StringArrayHashMap([]const u8).init(allocator);
    var inserted_pairs = try InsertedValues.initCapacity(allocator, 0);

    if (debug) {
        std.debug.print("Seed = {}\n", .{seed});
    }

    for (0..1000) |_| {
        const step = try random_step(rng, allocator, &inserted_pairs);

        if (debug) {
            step.dump();
        }

        switch (step) {
            .Insert => |i| {
                try tb.put(i.key.items, i.value.items);
                try table.put(i.key.items, i.value.items);
            },
            .Remove => |rm| {
                try tb.remove(rm.key.items);
                _ = table.swapRemove(rm.key.items);
            },
        }

        var iter = table.iterator();
        while (iter.next()) |next| {
            const value = try tb.get(next.key_ptr.*);
            try std.testing.expectEqualSlices(u8, value.?, next.value_ptr.*);
        }
    }
}
