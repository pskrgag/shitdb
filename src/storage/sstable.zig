const std = @import("std");
const utils = @import("utils.zig");
const MemTable = @import("memtable.zig").MemTable;
const KeyValue = @import("memtable.zig").KeyValue;
const Allocator = std.mem.Allocator;

pub const BlockSize = 4 << 10;
const Magic: usize = 0xdeadbeefdeadbaba;
var Lvl0Count: u64 = 0;

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

fn lvl_name(alloc: Allocator, lvl: usize, num: usize) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "lvl{}{}.ss", .{ lvl, num });
}

fn generate_lvl_name(alloc: Allocator, lvl: usize) ![]const u8 {
    return lvl_name(alloc, lvl, @atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
}

const SSTable = struct {
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

    fn write_index(meta: ValuesMeta, file: *[]u8) usize {
        var index_size: usize = 0;
        var offset: usize = 0;

        // Data blocks are written. Now create index block
        for (meta.blocks.items) |mt| {
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

    fn write_meta(file: *[]u8, meta: MetaBlock) !void {
        @memcpy(file.*[0..@sizeOf(MetaBlock)], utils.data_as_u8_const_ptr(&meta));
    }

    fn find_block_candidate(index: []const u8, key: []const u8) ?struct { offset: usize, size: usize } {
        var iter = index;

        while (iter.len > 0) {
            const block: *align(1) const BlockIndex = @ptrCast(@alignCast(iter.ptr));
            const current_key = iter[@sizeOf(BlockIndex) .. @sizeOf(BlockIndex) + block.key_size];

            std.debug.assert(block.key_size > 0);
            switch (std.mem.order(u8, key, current_key)) {
                .eq, .lt => {
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

    fn find_value_in_block(block_data: []const u8, key: []const u8) ?[]const u8 {
        var iter = block_data;

        while (iter.len > 0) {
            const kv: KeyValue = KeyValue{ .data = @ptrCast(@alignCast(iter.ptr)) };
            const current_key = kv.as_key();

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

    pub fn create(dir: *std.fs.Dir, name: []const u8, tbl: *const MemTable, alloc: Allocator) !Self {
        const file = try dir.createFile(name, .{
            .truncate = true,
            .read = true,
        });
        defer file.close();

        // Resize file to reduce I/O and use mmap
        const total_size = Self.calculate_file_size(tbl);
        try file.setEndPos(total_size);

        var mmap = try std.posix.mmap(null, total_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, file.handle, 0);
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

    pub fn find_value(self: *const Self, key: []const u8, alloc: Allocator) !?std.ArrayList(u8) {
        var meta: MetaBlock = undefined;
        @memcpy(utils.data_as_u8_ptr(&meta), self.file[self.file.len - @sizeOf(MetaBlock) ..]);

        if (meta.magic != Magic)
            return error.CorruptedFile;

        // We found a block that may contain a value. Try to find a value there
        if (Self.find_block_candidate(self.file[meta.index_offset .. meta.index_offset + meta.index_size], key)) |blk| {
            if (Self.find_value_in_block(self.file[blk.offset .. blk.offset + blk.size], key)) |val| {
                var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

                try res.appendSlice(alloc, val);
                return res;
            } else {
                return null;
            }
        }

        return null;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.path);
        std.posix.munmap(@ptrCast(@alignCast(self.file)));
    }
};

test "Simple find and create" {
    var arena = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.fs.cwd();
    try cwd.makePath("test_db");
    defer {
        std.fs.cwd().deleteTree("test_db") catch {
            @panic("gg");
        };
    }

    var dir = try cwd.openDir("test_db", .{});
    defer dir.close();

    var tb = try MemTable.new(allocator, null);
    defer tb.deinit(allocator);
    const name = try generate_lvl_name(allocator, 0);

    inline for (1..200) |i| {
        try tb.put("a" ** i, "a" ** i);
    }

    var table = try SSTable.create(&dir, name, tb, allocator);
    defer table.deinit(allocator);
    const to_find = [_][]const u8{ "a" ** 1, "a" ** 20, "a" ** 51, "a" ** 100, "a" ** 150, "a" ** 132 };

    for (to_find) |i| {
        var val = (try table.find_value(i, allocator)).?;
        defer val.deinit(allocator);

        try std.testing.expectEqualSlices(u8, i, val.items);
    }

    const to_find_non_present = [_][]const u8{ "a" ** 201, "b", "c", "d" ** 100 };
    for (to_find_non_present) |i| {
        try std.testing.expectEqual(try table.find_value(i, allocator), null);
    }
}
