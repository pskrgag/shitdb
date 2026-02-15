const std = @import("std");
const utils = @import("utils.zig");
const MemTable = @import("memtable.zig").MemTable;
const KeyValue = @import("memtable.zig").KeyValue;
const Allocator = std.mem.Allocator;

pub const BlockSize = 4 << 10;
const Magic: usize = 0xdeadbeefdeadbaba;
var Lvl0Count: u64 = 0;

const MetaBlock = extern struct {
    data_offset: usize,
    data_size: usize,

    index_offset: usize,
    index_size: usize,
    magic: usize,
};

fn is_lvl0_name(name: []const u8) bool {
    return std.mem.startsWith(u8, "lvl0", name) and std.mem.endsWith(u8, ".ss", name);
}

fn lvl0_name(alloc: Allocator, num: usize) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "lvl0{}.ss", .{num});
}

fn generate_lvl0_name(alloc: Allocator) ![]const u8 {
    return lvl0_name(alloc, @atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
}

pub fn create(tbl: *const MemTable, alloc: Allocator) !void {
    const cwd = std.fs.cwd();
    try cwd.makePath("test_db");

    var dir = try cwd.openDir("test_db", .{});
    defer dir.close();

    const name = try generate_lvl0_name(alloc);
    defer alloc.free(name);

    const file = try dir.createFile(name, .{
        .truncate = true,
    });
    defer file.close();

    var blocks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    var block_written: usize = 0;
    var last: []const u8 = undefined;
    var iter = tbl.table.iterator();
    var data_size: usize = 0;

    while (iter.next()) |key| {
        const key_value_size = key.full_size();

        std.debug.assert(block_written != 0 or (try file.getPos()) % BlockSize == 0);
        std.debug.assert(key_value_size < BlockSize);

        // Finalize block
        if (block_written + key_value_size > BlockSize) {
            try blocks.append(alloc, last);
            try file.seekBy(@intCast(BlockSize - block_written));
            block_written = 0;
        }

        try file.writeAll(key.data[0..key_value_size]);
        last = key.as_key();

        data_size += key_value_size;
        block_written += key_value_size;
        std.debug.assert((try file.getPos()) % BlockSize == block_written);
    }

    try blocks.append(alloc, last);
    try file.seekBy(@intCast(BlockSize - block_written));

    std.debug.assert((try file.getPos()) % BlockSize == 0);
    var index_size: usize = 0;

    // Data blocks are written. Now create index block
    for (blocks.items) |key| {
        std.debug.assert((try file.getPos()) % 8 == 0);

        // For each block save last key in that block
        try file.writeAll(utils.data_as_u8_const_ptr(&key.len));
        try file.writeAll(key);

        if (key.len % 8 != 0)
            try file.seekBy(@intCast(8 - key.len % 8));

        index_size += utils.round_up(key.len, 8) + 8;
    }

    // Create metablock
    const meta = MetaBlock{
        .data_offset = 0,
        .data_size = data_size,

        .index_offset = blocks.items.len * BlockSize,
        .index_size = index_size,
        .magic = Magic,
    };
    try file.writeAll(utils.data_as_u8_const_ptr(&meta));
}

fn find_block_candidate(index: []const u8, key: []const u8) ?usize {
    var iter = index;
    var block_idx: usize = 0;

    while (iter.len > 0) {
        const key_size: *const u64 = @ptrCast(@alignCast(iter.ptr));
        const current_key = iter[8 .. 8 + key_size.*];

        std.debug.assert(key_size.* > 0);
        switch (std.mem.order(u8, key, current_key)) {
            .eq, .lt => {
                // Found the block where to key may be present.
                return block_idx;
            },
            .gt => {
                // This block does not contain a key. Go forward.
            },
        }

        block_idx += 1;
        iter = iter[utils.round_up(key_size.*, 8) + 8 ..];
    }

    return null;
}

fn find_value_in_block(block_data: []const u8, key: []const u8) ?[]const u8 {
    var iter = block_data;

    while (iter.len > 0) {
        const kv: KeyValue = KeyValue{ .data = @ptrCast(@alignCast(iter.ptr)) };
        const current_key = kv.as_key();

        if (kv.as_key().len == 0)
            break;

        switch (std.mem.order(u8, key, current_key)) {
            .eq => return kv.as_value(),
            .gt => {
                // key is less then current_key. Go forward
            },
            .lt => {
                // key is greater. It's missing in this block
                return null;
            },
        }

        std.debug.assert(kv.full_size() % 8 == 0);
        iter = iter[kv.full_size()..];
    }

    return null;
}

fn find_value(path: []const u8, key: []const u8, alloc: Allocator) !?std.ArrayList(u8) {
    const cwd = std.fs.cwd();

    var dir = try cwd.openDir("test_db", .{});
    defer dir.close();

    const file = try dir.openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    const meta_offset = size - @sizeOf(MetaBlock);
    try file.seekTo(meta_offset);

    var meta: MetaBlock = undefined;
    _ = try file.readAll(utils.data_as_u8_ptr(&meta));

    if (meta.magic != Magic)
        return error.CorruptedFile;

    const index = try alloc.alignedAlloc(u8, std.mem.Alignment.@"8", meta.index_size);
    defer alloc.free(index);

    try file.seekTo(meta.index_offset);
    _ = try file.readAll(index);

    // We found a block that may contain a value. Try to find a value there
    if (find_block_candidate(index, key)) |block| {
        const block_data = try alloc.alignedAlloc(u8, std.mem.Alignment.@"8", BlockSize);
        defer alloc.free(block_data);

        try file.seekTo(block * BlockSize);
        _ = try file.readAll(block_data);

        if (find_value_in_block(block_data, key)) |val| {
            var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

            try res.appendSlice(alloc, val);
            return res;
        } else {
            return null;
        }
    }

    return null;
}

fn clean_up_db() !void {
    try std.fs.cwd().deleteTree("test_db");
}

test "Simple find and create" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tb = try MemTable.new(allocator, null);

    inline for (1..200) |i| {
        try tb.put("a" ** i, "a" ** i);
    }

    try create(tb, allocator);
    const name = try lvl0_name(allocator, 0);
    defer allocator.free(name);

    const to_find = [_][]const u8{ "a" ** 1, "a" ** 100, "a" ** 150, "a" ** 132 };
    for (to_find) |i| {
        var val = (try find_value(name, i, allocator)).?;
        defer val.deinit(allocator);

        try std.testing.expectEqualSlices(u8, i, val.items);
    }

    const to_find_non_present = [_][]const u8{ "a" ** 201, "b", "c", "d" ** 100 };
    for (to_find_non_present) |i| {
        try std.testing.expectEqual(try find_value(name, i, allocator), null);
    }

    try clean_up_db();
}
