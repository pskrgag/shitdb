const std = @import("std");
const utils = @import("utils.zig");
const MemTable = @import("memtable.zig").MemTable;
const GetResult = @import("memtable.zig").GetResult;
const KeyValue = @import("memtable.zig").KeyValue;
const KeyValueOwned = @import("memtable.zig").KeyValueOwned;
const Allocator = std.mem.Allocator;
const merging_iterator = @import("merging_iterator");
const io = std.Options.debug_io;

pub const BlockSize = 4 << 10;
const Magic: usize = 0xdeadbeefdeadbaba;
var Lvl0Count: u64 = 0;

// Layout of the SStable:
//
// +-----------------------+
// |    Data block 1       |
// +-----------------------+
// |    Data block 2       |
// +-----------------------+
//         ...
// +-----------------------+
// |    Data block N       |
// +-----------------------+
// |         Index         |
// +-----------------------+
// |         Meta          |
// |                       |
// |   index_offset        |
// |   index_size          |
// |   magic               |
// +-----------------------+
//
//
// Index layout
// +-----------------------+
// |    BlockIndex 1       |
// |                       |
// |   offset              |
// |   size                |
// |   key_size            |
// |   key[]               |
// +-----------------------+
//         ...
// +-----------------------+
// |    BlockIndex N       |
// |                       |
// |   offset              |
// |   size                |
// |   key_size            |
// |   key[]               |
// +-----------------------+

const BlockIndex = packed struct {
    offset: usize,
    size: usize,
    key_size: usize,
    // key[]

    pub fn total_size(key_size: usize) usize {
        return @sizeOf(BlockIndex) + key_size;
    }
};

const MetaBlock = extern struct {
    index_offset: usize,
    index_size: usize,
    magic: usize,
};

const Block = struct {
    offset: usize,
    size: usize,
};

pub const Iterator = struct {
    data: []const u8,

    pub fn next(self: *Iterator) ?KeyValue {
        if (self.data.len > 0) {
            const kv: KeyValue = KeyValue{ .data = self.data.ptr };

            self.data = self.data[kv.full_size()..];
            return kv;
        } else {
            return null;
        }
    }

    pub fn peek(self: *Iterator) ?KeyValue {
        if (self.data.len > 0) {
            return KeyValue{ .data = self.data.ptr };
        } else {
            return null;
        }
    }
};

pub const SSTable = struct {
    path: []const u8,
    file: []u8,
    lvl: usize,

    const Self = @This();

    const BlockMeta = struct {
        last_key: []const u8,
        size: usize,
    };

    const ValuesMeta = struct {
        blocks: std.ArrayList(BlockMeta),
        data_size: usize,
    };

    fn meta(self: *const Self) MetaBlock {
        var mt: MetaBlock = undefined;

        @memcpy(utils.data_as_u8_ptr(&mt), self.file[self.file.len - @sizeOf(MetaBlock) ..]);
        return mt;
    }

    fn calculate_file_size(tbl: *const MemTable) usize {
        var iter = tbl.table.iterator();
        var total_size: usize = 0;
        var data_size: usize = 0;
        var current_block: usize = 0;
        var last: *KeyValue = undefined;

        while (iter.next()) |key| {
            total_size += key.full_size();
            current_block += key.full_size();
            data_size += key.full_size();

            if (current_block > BlockSize) {
                total_size += BlockIndex.total_size(key.as_key().len);
                current_block = 0;
            }

            last = key;
        }

        if (current_block > 0) {
            total_size += BlockIndex.total_size(last.as_key().len);
        }

        return total_size + @sizeOf(MetaBlock);
    }

    fn write_values(tbl: *const MemTable, file: *[]u8, alloc: Allocator) !ValuesMeta {
        var block_written: usize = 0;
        var data_size: usize = 0;
        var blocks = try std.ArrayList(BlockMeta).initCapacity(alloc, 0);
        var last: []const u8 = undefined;
        var iter = tbl.table.iterator();

        while (iter.next()) |key| {
            const key_value_size = key.full_size();

            @memcpy(file.*[0..key_value_size], key.data[0..key_value_size]);
            file.* = file.*[key_value_size..];

            last = key.as_key();
            data_size += key_value_size;
            block_written += key_value_size;

            // Finalize block
            if (block_written > BlockSize) {
                try blocks.append(alloc, BlockMeta{ .last_key = last, .size = block_written });
                block_written = 0;
            }
        }

        if (block_written != 0) {
            try blocks.append(alloc, BlockMeta{ .last_key = last, .size = block_written });
        }

        return .{ .data_size = data_size, .blocks = blocks };
    }

    fn write_index(value_meta: ValuesMeta, file: *[]u8) usize {
        var index_size: usize = 0;
        var offset: usize = 0;

        // Data blocks are written. Now create index block
        for (value_meta.blocks.items) |mt| {
            const block_idx = BlockIndex{ .size = mt.size, .offset = offset, .key_size = mt.last_key.len };
            const block_idx_ptr = utils.data_as_u8_const_ptr(&block_idx);

            @memcpy(file.*[0..@sizeOf(BlockIndex)], block_idx_ptr);
            file.* = file.*[@sizeOf(BlockIndex)..];

            @memcpy(file.*[0..mt.last_key.len], mt.last_key);
            file.* = file.*[mt.last_key.len..];

            offset += mt.size;

            index_size += @sizeOf(BlockIndex);
            index_size += mt.last_key.len;
        }

        return index_size;
    }

    fn write_meta(file: *[]u8, m: MetaBlock) !void {
        @memcpy(file.*[0..@sizeOf(MetaBlock)], utils.data_as_u8_const_ptr(&m));
    }

    fn read_block_first_key(block: []const u8) []const u8 {
        const kv: KeyValue = KeyValue{ .data = @ptrCast(@alignCast(block.ptr)) };
        return kv.as_key();
    }

    fn find_block_candidate(index: []const u8, key: []const u8, file: []const u8) ?Block {
        var iter = index;

        while (iter.len > 0) {
            var block: *align(1) const BlockIndex = @ptrCast(@alignCast(iter.ptr));
            const current_key = iter[@sizeOf(BlockIndex) .. @sizeOf(BlockIndex) + block.key_size];

            std.debug.assert(block.key_size > 0);
            switch (std.mem.order(u8, key, current_key)) {
                .eq => {
                    // There is a small catch. Imagine following
                    //
                    // Now block points to block1
                    //
                    //        [block1]                       [block2]
                    // [key|add, key|add, key|remove]    [key|add......]
                    //
                    // 1) If next block::key == key, then the newest value is indeed in next blocks
                    // 2) Otherwise if block.first_key() == key then the newest value is in the next block.

                    while (true) {
                        // Next block does not exist
                        if (iter.len == @sizeOf(BlockIndex) + block.key_size) {
                            return .{ .offset = block.offset, .size = block.size };
                        }

                        const next_block_data = iter[@sizeOf(BlockIndex) + block.key_size ..];
                        const next_block: *align(1) const BlockIndex = @ptrCast(@alignCast(next_block_data.ptr));
                        const next_key = next_block_data[@sizeOf(BlockIndex) .. @sizeOf(BlockIndex) + next_block.key_size];

                        if (std.mem.order(u8, next_key, key) == .eq) {
                            // Definitely not in the current block
                            iter = next_block_data;
                            block = next_block;
                        } else {
                            // Read first key of the block. If it matches then pick next block
                            const block_data = file[block.offset .. block.offset + block.size];
                            const next_first_key = Self.read_block_first_key(block_data);

                            if (std.mem.order(u8, next_first_key, key) == .eq) {
                                iter = next_block_data;
                                block = next_block;
                            } else {
                                break;
                            }
                        }
                    }

                    return .{ .offset = block.offset, .size = block.size };
                },
                .lt => {
                    // Found the block where to key may be present.
                    return .{ .offset = block.offset, .size = block.size };
                },
                .gt => {
                    // This block does not contain a key. Go forward.
                },
            }

            iter = iter[@sizeOf(BlockIndex) + block.key_size ..];
        }

        return null;
    }

    fn find_value_in_block(block_data: []const u8, key: []const u8, alloc: Allocator) !GetResult {
        var iter = block_data;

        while (iter.len > 0) {
            var kv: KeyValue = KeyValue{ .data = @ptrCast(@alignCast(iter.ptr)) };
            var current_key = kv.as_key();

            // Walk until we find element with biggest sequence number.
            if (std.mem.order(u8, key, current_key) == .eq) {
                while (iter.len > 0) {
                    const next = iter[kv.full_size()..];

                    if (next.len == 0)
                        break;

                    const next_kv = KeyValue{ .data = @ptrCast(@alignCast(next.ptr)) };
                    const next_key = next_kv.as_key();

                    if (std.mem.order(u8, next_key, current_key) == .eq) {
                        iter = next;
                        current_key = next_key;
                        kv = next_kv;
                    } else {
                        break;
                    }
                }
            }

            switch (std.mem.order(u8, key, current_key)) {
                .eq => {
                    switch (kv.as_type()) {
                        .Delete => return .Removed,
                        .Add => {
                            const value = kv.as_value().?;
                            var res = try std.ArrayList(u8).initCapacity(alloc, value.len);

                            try res.appendSlice(alloc, value);
                            return GetResult{ .Found = res.items };
                        },
                    }
                },
                .gt => {
                    // key is less then current_key. Go forward
                },
                .lt => {
                    // key is greater. It's missing in this block
                    return .NotFound;
                },
            }

            iter = iter[kv.full_size()..];
        }

        return .NotFound;
    }

    pub fn iterator(self: *Self) Iterator {
        const mt = self.meta();

        return .{ .data = self.file[0..mt.index_offset] };
    }

    pub fn open(dir: std.Io.Dir, name: []const u8) !Self {
        const file = try dir.openFile(io, name, .{});
        defer file.close(io);

        const stat = try file.stat(io);

        const mmap = try std.posix.mmap(null, stat.size, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0);
        return .{ .path = name, .file = mmap, .lvl = 0 };
    }

    pub fn create(dir: std.Io.Dir, name: []const u8, tbl: *const MemTable, alloc: Allocator) !Self {
        const file = try dir.createFile(io, name, .{
            .truncate = true,
            .read = true,
            .exclusive = true,
        });
        defer file.close(io);

        // Resize file to reduce I/O and use mmap
        const total_size = Self.calculate_file_size(tbl);
        try file.setLength(io, total_size);

        var mmap = try std.posix.mmap(null, total_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, file.handle, 0);
        const mmap_copy = mmap;

        var values_meta = try Self.write_values(tbl, @ptrCast(&mmap), alloc);
        defer values_meta.blocks.deinit(alloc);

        const index_size = write_index(values_meta, @ptrCast(&mmap));

        // Create metablock
        try Self.write_meta(@ptrCast(&mmap), MetaBlock{
            .index_offset = values_meta.data_size,
            .index_size = index_size,
            .magic = Magic,
        });

        return .{ .path = name, .file = mmap_copy, .lvl = 0 };
    }

    pub fn find_value(self: *const Self, key: []const u8, alloc: Allocator) !GetResult {
        const meta_block = self.meta();

        if (meta_block.magic != Magic)
            return error.CorruptedFile;

        const index = self.file[meta_block.index_offset .. meta_block.index_offset + meta_block.index_size];

        // We found a block that may contain a value. Try to find a value there
        if (Self.find_block_candidate(index, key, self.file)) |blk| {
            return try Self.find_value_in_block(self.file[blk.offset .. blk.offset + blk.size], key, alloc);
        }

        return .NotFound;
    }

    pub fn merge(dir: *std.Io.Dir, name: []const u8, self: Self, other: Self) !Self {
        const iters = [_]merging_iterator.IteratorWrapper(KeyValue){ self.iterator(), other.iterator() };
        const iter = merging_iterator.MergeIterator(KeyValue).new(iters);
        const file = try dir.createFile(io, name, .{
            .truncate = true,
            .read = true,
        });
        defer file.close(io);

        std.debug.assert(self.lvl == other.lvl);

        const total_size = self.file.len + other.file.len;
        try file.setLength(io, total_size);

        var mmap = try std.posix.mmap(null, total_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, file.handle, 0);
        const mmap_copy = mmap;

        while (iter.next()) |key| {
            const key_value_size = key.full_size();

            @memcpy(mmap[0..key_value_size], key.data[0..key_value_size]);
            mmap = mmap[key_value_size..];
        }

        return .{ .file = mmap_copy, .path = name, .lvl = self.lvl + 1 };
    }

    pub fn deinit(self: *Self) void {
        // alloc.free(self.path);
        std.posix.munmap(@ptrCast(@alignCast(self.file)));
    }
};

fn lvl_name(alloc: Allocator, lvl: usize, num: usize) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "lvl{}{}.ss", .{ lvl, num });
}

fn generate_lvl_name(alloc: Allocator, lvl: usize) ![]const u8 {
    return lvl_name(alloc, lvl, @atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
}

fn repeatChar(allocator: std.mem.Allocator, char: u8, count: usize) ![]u8 {
    const result = try allocator.alloc(u8, count);
    @memset(result, char);
    return result;
}

test "Simple find and create" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db") catch {
            @panic("gg");
        };
    }

    var dir = try cwd.openDir(io, "test_db", .{});
    defer dir.close(io);

    var tb = try MemTable.new(allocator, null);
    defer tb.deinit(allocator);
    const name = try generate_lvl_name(allocator, 0);
    defer allocator.free(name);

    inline for (1..200) |i| {
        try tb.put("a" ** i, "a" ** i, 0);
    }

    var table = try SSTable.create(dir, name, tb, allocator);
    defer table.deinit();
    const to_find = [_][]const u8{ "a" ** 1, "a" ** 20, "a" ** 51, "a" ** 100, "a" ** 150, "a" ** 132 };

    for (to_find) |i| {
        const val = try table.find_value(i, allocator);

        switch (val) {
            .Found => |v| {
                try std.testing.expectEqualSlices(u8, i, v);
                defer allocator.free(v);
            },
            else => @panic("Unexpected return"),
        }
    }

    const to_find_non_present = [_][]const u8{ "a" ** 201, "b", "c", "d" ** 100 };
    for (to_find_non_present) |i| {
        try std.testing.expectEqual(try table.find_value(i, allocator), .NotFound);
    }

    var iter = table.iterator();
    var i: usize = 1;

    while (iter.next()) |kv| {
        const expected = try repeatChar(allocator, 'a', i);
        defer allocator.free(expected);

        try std.testing.expectEqualSlices(u8, kv.as_key(), expected);
        try std.testing.expectEqualSlices(u8, kv.as_value().?, expected);
        i += 1;
    }

    try std.testing.expectEqual(i, 200);
}

test "Merge" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db") catch {
            @panic("gg");
        };
    }

    var dir = try cwd.openDir(io, "test_db", .{});
    defer dir.close(io);

    var tb = try MemTable.new(allocator, null);
    defer tb.deinit(allocator);
    const name = try generate_lvl_name(allocator, 0);
    defer allocator.free(name);

    inline for (1..200) |i| {
        try tb.put("a" ** (i * 2 + 1), "a" ** (i * 2 + 1), i);
    }
    var table = try SSTable.create(dir, name, tb, allocator);
    defer table.deinit();

    var tb1 = try MemTable.new(allocator, null);
    defer tb1.deinit(allocator);

    inline for (1..200) |i| {
        try tb1.put("ab" ** (i * 2), "ba" ** (i * 2), i);
    }
    const name1 = try generate_lvl_name(allocator, 201);
    defer allocator.free(name1);
    var table1 = try SSTable.create(dir, name1, tb, allocator);
    defer table1.deinit();
}

test "Remove" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db") catch {
            @panic("gg");
        };
    }
    var dir = try cwd.openDir(io, "test_db", .{});
    defer dir.close(io);

    var tb = try MemTable.new(allocator, null);
    defer tb.deinit(allocator);
    const name = try generate_lvl_name(allocator, 0);
    defer allocator.free(name);

    try tb.put("b" ** 10, "b" ** 10, 1);
    try tb.remove("b" ** 10, 2);

    var table = try SSTable.create(dir, name, tb, allocator);
    defer table.deinit();

    const val = try table.find_value("b" ** 10, allocator);
    switch (val) {
        .Removed => {},
        else => {
            std.debug.print("val {}\n", .{val});
            @panic("Unexpected return");
        },
    }
}

test "Remove more than one block" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db") catch {
            @panic("gg");
        };
    }
    var dir = try cwd.openDir(io, "test_db", .{});
    defer dir.close(io);

    var tb = try MemTable.new(allocator, null);
    defer tb.deinit(allocator);

    try tb.put("b" ** (BlockSize / 4), "b" ** (BlockSize / 4), 1);
    try tb.put("b" ** (BlockSize / 4), "d" ** (BlockSize / 4), 2);
    try tb.put("b" ** (BlockSize / 4), "c" ** (BlockSize / 4), 3);
    try tb.put("b" ** (BlockSize / 4), "d" ** (BlockSize / 4), 4);

    {
        const name = try generate_lvl_name(allocator, 0);
        defer allocator.free(name);
        var table = try SSTable.create(dir, name, tb, allocator);
        defer table.deinit();

        const val = try table.find_value("b" ** (BlockSize / 4), allocator);
        switch (val) {
            .Found => |v| {
                try std.testing.expectEqualSlices(u8, "d" ** (BlockSize / 4), v);
                defer allocator.free(v);
            },
            else => {
                std.debug.print("val {}\n", .{val});
                @panic("Unexpected return");
            },
        }
    }

    {
        const name = try generate_lvl_name(allocator, 1);
        defer allocator.free(name);

        try tb.remove("b" ** (BlockSize / 4), 5);

        var table = try SSTable.create(dir, name, tb, allocator);
        defer table.deinit();

        const val = try table.find_value("b" ** (BlockSize / 4), allocator);
        switch (val) {
            .Removed => {},
            else => {
                std.debug.print("val {}\n", .{val});
                @panic("Unexpected return");
            },
        }
    }
}
