const std = @import("std");
const MemTable = @import("memtable.zig").MemTable;
const GetResult = @import("memtable.zig").GetResult;
const KeyValue = @import("memtable.zig").KeyValue;
const KeyValueOwned = @import("memtable.zig").KeyValueOwned;
const KVSeq = @import("memtable.zig").KVSeq;
const Allocator = std.mem.Allocator;
const merging_iterator = @import("merging_iterator");
const manifest = @import("manifest.zig");
const FileMeta = manifest.FileMeta;
const FileSeq = manifest.FileSeq;
const KeyOwned = manifest.KeyOwned;
const Storage = @import("storage.zig").Storage;
const SSTableFile = @import("ssfile.zig").SSTableFile;
const Mmap = @import("mmap_wrapper.zig").Mmap;

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
// |         Utility       |
// |                       |
// |      min_key          |
// |      max_key          |
// +-----------------------+
// |         Meta          |
// |                       |
// |   min_size            |
// |   max_size            |
// |   index_offset        |
// |   index_size          |
// |   lvl                 |
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

const MetaBlock = packed struct {
    min_size: usize,
    max_size: usize,
    index_offset: usize,
    index_size: usize,
    magic: usize,
    lvl: u8,
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

pub const OutputFileSource = struct {
    ctx: *anyopaque,
    nextFile: *const fn (ctx: *anyopaque) anyerror!FileSeq,
};

/// Result of merging sstables
pub const MergeResult = std.ArrayList(FileMeta);

pub const SSTable = struct {
    file: SSTableFile,
    mmap: Mmap,
    lvl: usize,
    min_key: []const u8,
    max_key: []const u8,
    max_seq: ?KVSeq,

    const Self = @This();

    const BlockMeta = struct {
        last_key: []const u8,
        size: usize,
    };

    const ValuesMeta = struct {
        blocks: std.ArrayList(BlockMeta),
        data_size: usize,
    };

    const WriteKVIter = struct {
        blocks: std.ArrayList(BlockMeta),
        file: [*]u8,
        last: []const u8,
        block_written: usize,
        data_size: usize,
        target_size: ?usize = null,
        min: ?KeyValue,
        max: ?KeyValue,
        max_seq: ?KVSeq,

        fn init(file: [*]u8, target_size: ?usize, alloc: Allocator) !WriteKVIter {
            return .{
                .file = file,
                .last = undefined,
                .block_written = 0,
                .target_size = target_size,
                .data_size = 0,
                .blocks = try std.ArrayList(BlockMeta).initCapacity(alloc, 0),
                .min = null,
                .max = null,
                .max_seq = null,
            };
        }

        fn written(self: *const WriteKVIter) usize {
            return self.data_size;
        }

        fn write_one(self: *WriteKVIter, key: *const KeyValue, force: bool, alloc: Allocator) !bool {
            const key_value_size = key.full_size();

            if (self.target_size) |ts| {
                if (!force and self.data_size + key_value_size > ts)
                    return false;
            }

            if (self.max_seq == null) {
                self.max_seq = key.as_seq();
            } else {
                if (self.max_seq.?.get() < key.as_seq().get())
                    self.max_seq = key.as_seq();
            }

            if (self.min == null) {
                std.debug.assert(self.max == null);

                self.min = KeyValue{ .data = self.file };
                self.max = self.min;
            } else {
                if (self.min.?.cmp(key) == .gt) {
                    self.min = KeyValue{ .data = self.file };
                } else if (self.max.?.cmp(key) == .lt) {
                    self.max = KeyValue{ .data = self.file };
                }
            }

            @memcpy(self.file[0..key_value_size], key.data[0..key_value_size]);
            self.file = self.file[key_value_size..];

            self.last = key.as_key();
            self.data_size += key_value_size;
            self.block_written += key_value_size;

            if (self.block_written > BlockSize) {
                try self.blocks.append(
                    alloc,
                    BlockMeta{ .last_key = self.last, .size = self.block_written },
                );
                self.block_written = 0;
            }

            return true;
        }

        fn finalize(self: *WriteKVIter, alloc: Allocator) !ValuesMeta {
            if (self.block_written != 0) {
                try self.blocks.append(
                    alloc,
                    BlockMeta{ .last_key = self.last, .size = self.block_written },
                );
            }

            return .{ .data_size = self.data_size, .blocks = self.blocks };
        }
    };

    fn meta_from_file(file: []const u8) MetaBlock {
        var mt: MetaBlock = undefined;

        @memcpy(std.mem.asBytes(&mt), file[file.len - @sizeOf(MetaBlock) ..]);
        return mt;
    }

    fn meta(self: *const Self) !MetaBlock {
        const mt = Self.meta_from_file(self.mmap.data);

        if (mt.magic != Magic)
            return error.CorruptedFile;

        return mt;
    }

    fn calculate_file_size(tbl: *const MemTable) usize {
        var iter = tbl.table.iterator();
        var total_size: usize = 0;
        var current_block: usize = 0;
        var last: *KeyValue = undefined;

        while (iter.next()) |key| {
            total_size += key.full_size();
            current_block += key.full_size();

            if (current_block > BlockSize) {
                total_size += BlockIndex.total_size(key.as_key().len);
                current_block = 0;
            }

            last = key;
        }

        if (current_block > 0) {
            total_size += BlockIndex.total_size(last.as_key().len);
        }

        return total_size + @sizeOf(MetaBlock) + tbl.max().?.as_key().len + tbl.min().?.as_key().len;
    }

    fn write_values(tbl: *const MemTable, file: [*]u8, alloc: Allocator) !WriteKVIter {
        var iter = tbl.table.iterator();
        var write_iter = try WriteKVIter.init(file, null, alloc);

        while (iter.next()) |key| {
            const can_more = try write_iter.write_one(key, true, alloc);
            std.debug.assert(can_more);
        }

        return write_iter;
    }

    fn min_key_from_file(file: []const u8) []const u8 {
        const mt = Self.meta_from_file(file);

        return file[file.len - @sizeOf(MetaBlock) - mt.max_size - mt.min_size .. file.len - @sizeOf(MetaBlock) - mt.max_size];
    }

    fn max_key_from_file(file: []const u8) []const u8 {
        const mt = Self.meta_from_file(file);

        return file[file.len - @sizeOf(MetaBlock) - mt.max_size .. file.len - @sizeOf(MetaBlock)];
    }

    fn write_min_max(iter: WriteKVIter, file: [*]u8) usize {
        const min_len = iter.min.?.as_key().len;
        const max_len = iter.max.?.as_key().len;

        @memcpy(file, iter.min.?.as_key());
        @memcpy(file + min_len, iter.max.?.as_key());

        return min_len + max_len;
    }

    fn finalize_table(
        iter: WriteKVIter,
        file: *SSTableFile,
        file_data: []u8,
        lvl: u8,
        io: std.Io,
        alloc: Allocator,
    ) !usize {
        var i = iter;
        var values_meta = try i.finalize(alloc);
        const index_size = write_index(values_meta, file_data.ptr + iter.data_size);
        const min_max_size = write_min_max(iter, file_data.ptr + iter.data_size + index_size);

        try Self.write_meta(file_data.ptr + iter.data_size + index_size + min_max_size, MetaBlock{
            .index_offset = values_meta.data_size,
            .index_size = index_size,
            .min_size = iter.min.?.as_key().len,
            .max_size = iter.max.?.as_key().len,
            .magic = Magic,
            .lvl = lvl,
        });

        const file_size = iter.data_size + index_size + min_max_size + @sizeOf(MetaBlock);
        // Set real size of the file
        try file.set_length(io, file_size);
        // Sync data
        try std.posix.msync(@alignCast(file_data), std.posix.MSF.SYNC);
        // Sync file metadata as well
        try file.sync(io);

        values_meta.blocks.deinit(alloc);
        return file_size;
    }

    fn write_index(value_meta: ValuesMeta, file_: [*]u8) usize {
        var index_size: usize = 0;
        var offset: usize = 0;
        var file = file_;

        for (value_meta.blocks.items) |mt| {
            const block_idx = BlockIndex{
                .size = mt.size,
                .offset = offset,
                .key_size = mt.last_key.len,
            };
            const block_idx_ptr = std.mem.asBytes(&block_idx);

            @memcpy(file[0..@sizeOf(BlockIndex)], block_idx_ptr);
            file = file[@sizeOf(BlockIndex)..];

            @memcpy(file[0..mt.last_key.len], mt.last_key);
            file = file[mt.last_key.len..];

            offset += mt.size;

            index_size += @sizeOf(BlockIndex);
            index_size += mt.last_key.len;
        }

        return index_size;
    }

    fn write_meta(file: [*]u8, m: MetaBlock) !void {
        @memcpy(file[0..@sizeOf(MetaBlock)], std.mem.asBytes(&m));
    }

    fn read_block_first_key(block: []const u8) []const u8 {
        const kv: KeyValue = KeyValue{ .data = block.ptr };
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
                        const next_block: *align(1) const BlockIndex =
                            @ptrCast(@alignCast(next_block_data.ptr));
                        const next_key =
                            next_block_data[@sizeOf(BlockIndex) .. @sizeOf(BlockIndex) + next_block.key_size];

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
            var kv: KeyValue = KeyValue{ .data = iter.ptr };
            var current_key = kv.as_key();

            // Walk until we find element with biggest sequence number.
            if (std.mem.order(u8, key, current_key) == .eq) {
                while (iter.len > 0) {
                    const next = iter[kv.full_size()..];

                    if (next.len == 0)
                        break;

                    const next_kv = KeyValue{ .data = next.ptr };
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

    /// Return an iterator over key-value pairs
    pub fn iterator(self: *const Self) Iterator {
        const mt = self.meta() catch @panic("Opened corrupted file");

        return .{ .data = self.mmap.data[0..mt.index_offset] };
    }

    /// Opens existing SSTable in read-only mode
    pub fn open(storage: *Storage, fmeta: FileMeta, io: std.Io, alloc: Allocator) !Self {
        var file = try storage.open_sstable(fmeta, io, alloc);
        errdefer file.close(io);

        const mmap = try Mmap.init(file, .ro);
        const mt = Self.meta_from_file(mmap.data);

        return .{
            .mmap = mmap,
            .file = file,
            .lvl = @intCast(mt.lvl),
            .min_key = Self.min_key_from_file(mmap.data),
            .max_key = Self.max_key_from_file(mmap.data),
            .max_seq = null,
        };
    }

    /// Creates new SSTable
    pub fn create(
        storage: *Storage,
        fmeta: FileMeta,
        tbl: *const MemTable,
        io: std.Io,
        alloc: Allocator,
    ) !Self {
        var file = try storage.create_sstable(fmeta.file_seq, fmeta.lvl, io, alloc);

        errdefer {
            file.close(io);
            storage.unlink_sstable(fmeta, io, alloc) catch @panic("todo");
        }

        // Resize file to reduce I/O and use mmap
        const total_size = Self.calculate_file_size(tbl);
        try file.set_length(io, total_size);

        var mmap = try Mmap.init(file, .rw);
        errdefer mmap.deinit();

        const iter = try Self.write_values(tbl, mmap.data.ptr, alloc);
        const real_size = try Self.finalize_table(iter, &file, mmap.data, fmeta.lvl, io, alloc);

        std.debug.assert(real_size == mmap.data.len);
        std.debug.assert(iter.min.?.cmp(&tbl.min().?) == .eq);
        std.debug.assert(iter.max.?.cmp(&tbl.max().?) == .eq);

        return .{
            .mmap = mmap,
            .file = file,
            .lvl = @intCast(fmeta.lvl),
            .min_key = iter.min.?.as_key(),
            .max_key = iter.max.?.as_key(),
            .max_seq = iter.max_seq,
        };
    }

    /// Finds value in SSTable
    pub fn find_value(self: *Self, key: []const u8, alloc: Allocator) !GetResult {
        const meta_block = try self.meta();
        const index = self.mmap.data[meta_block.index_offset .. meta_block.index_offset + meta_block.index_size];

        // We found a block that may contain a value. Try to find a value there
        if (Self.find_block_candidate(index, key, self.mmap.data)) |blk| {
            return try Self.find_value_in_block(
                self.mmap.data[blk.offset .. blk.offset + blk.size],
                key,
                alloc,
            );
        }

        return .NotFound;
    }

    /// Merges SSTables into one
    pub fn merge(
        storage: *Storage,
        next_file: OutputFileSource,
        io: std.Io,
        tables: []const SSTable,
        merged_lvl: u8,
        target_size: usize,
        alloc: Allocator,
    ) !MergeResult {
        var iters = try std.ArrayList(merging_iterator.IteratorWrapper(KeyValue)).initCapacity(
            alloc,
            tables.len,
        );
        defer iters.deinit(alloc);
        var res = try MergeResult.initCapacity(alloc, 0);
        errdefer res.deinit(alloc);

        var iter_wrappers = try std.ArrayList(Iterator).initCapacity(alloc, tables.len);
        var total_size: usize = 0;
        defer iter_wrappers.deinit(alloc);

        for (tables) |*i| {
            // We need extra array, since IteratorWrapper accepts pointer
            iter_wrappers.append(alloc, i.iterator()) catch unreachable;

            // This is safe, since iter_wrappers has pre-allocated capacity.
            iters.append(
                alloc,
                merging_iterator.IteratorWrapper(KeyValue).init(&iter_wrappers.items[iter_wrappers.items.len - 1]),
            ) catch unreachable;

            total_size += i.file.size;
        }

        var iter = merging_iterator.MergeIterator(KeyValue).new(iters.items);
        var prev: ?KeyValue = null;

        while (iter.peek() != null or prev != null) {
            const file_seq = try next_file.nextFile(next_file.ctx);
            var file = try storage.create_sstable(file_seq, merged_lvl, io, alloc);
            defer file.close(io);

            // TODO: this is not great hack, but let's leave it for now.
            try file.set_length(io, target_size * 2);

            var mmap = try Mmap.init(file, .rw);
            defer mmap.deinit();
            var write_iter = try WriteKVIter.init(mmap.data.ptr, target_size, alloc);

            while (iter.peek()) |key| {
                if (prev) |p| {
                    // Case 1: key == prev_key. Need to keep the newest value (with bigger seq)
                    // Case 2: key != prev_key. Since iterator produces sorted values we won't see this key.
                    if (std.mem.eql(u8, p.as_key(), key.as_key())) {
                        if (key.as_seq().get() > p.as_seq().get()) {
                            prev = key;
                        }

                        _ = iter.next();
                    } else {
                        // Dump value to the new SSTable.
                        const full = try write_iter.write_one(&p, false, alloc) == false;

                        if (full) {
                            break;
                        }

                        prev = iter.next();
                    }
                } else {
                    prev = iter.next();
                }
            }

            if (prev) |p| {
                if (iter.peek() == null) {
                    const can_more = try write_iter.write_one(&p, true, alloc);
                    std.debug.assert(can_more);
                    prev = null;
                }
            }

            // This might happen with empty tables, but don't care for now
            std.debug.assert(write_iter.max_seq != null);
            std.debug.assert(write_iter.max != null);
            std.debug.assert(write_iter.min != null);

            _ = try Self.finalize_table(
                write_iter,
                &file,
                mmap.data,
                merged_lvl,
                io,
                alloc,
            );
            // std.debug.assert(real_size <= total_size);

            var min_kv = try KeyOwned.from_kv(write_iter.min.?, alloc);
            errdefer min_kv.deinit(alloc);

            var max_kv = try KeyOwned.from_kv(write_iter.max.?, alloc);
            errdefer max_kv.deinit(alloc);

            try res.append(alloc, FileMeta{
                .file_seq = file_seq,
                .min = min_kv,
                .max = max_kv,
                .lvl = merged_lvl,
                .value_seq = write_iter.max_seq.?,
            });
        }

        return res;
    }

    pub fn min(self: *const SSTable) []const u8 {
        return self.min_key;
    }

    pub fn max(self: *const SSTable) []const u8 {
        return self.max_key;
    }

    pub fn maximum_seq(self: *const SSTable) KVSeq {
        return self.max_seq.?;
    }

    /// Closes SSTable
    pub fn deinit(self: *Self, io: std.Io) void {
        self.file.close(io);
    }
};

fn lvl_name(alloc: Allocator, lvl: usize, num: usize) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "lvl{}{}.ss", .{ lvl, num });
}

fn generate_lvl_name(alloc: Allocator, lvl: usize) ![]const u8 {
    return lvl_name(alloc, lvl, @atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
}

fn test_file_meta(alloc: Allocator, lvl: u8, tbl: *const MemTable) !FileMeta {
    const file_seq = @atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic);

    return .{
        .lvl = lvl,
        .file_seq = FileSeq.init(file_seq),
        .value_seq = KVSeq.init(0),
        .min = try KeyOwned.from_kv(tbl.min().?, alloc),
        .max = try KeyOwned.from_kv(tbl.max().?, alloc),
    };
}

fn test_output_file_source(seq: *FileSeq) OutputFileSource {
    return .{
        .ctx = seq,
        .nextFile = struct {
            fn next(ctx: *anyopaque) !FileSeq {
                const ptr: *FileSeq = @ptrCast(@alignCast(ctx));
                const res = ptr.*;

                ptr.* = FileSeq.init(ptr.get() + 1);
                return res;
            }
        }.next,
    };
}

fn test_deinit_merge_result(res: *MergeResult, alloc: Allocator) void {
    for (res.items) |*meta| {
        meta.deinit(alloc);
    }
    res.deinit(alloc);
}

fn repeatChar(allocator: std.mem.Allocator, char: u8, count: usize) ![]u8 {
    const result = try allocator.alloc(u8, count);

    @memset(result, char);
    return result;
}

const testing_io = std.testing.io;

test "Simple find and create" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_db") catch {};
    try cwd.createDirPath(testing_io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_db") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_db", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    inline for (1..200) |i| {
        try tb.put("a" ** i, "a" ** i, KVSeq.init(0));
    }

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);

    var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
    defer table.deinit(testing_io);
    const to_find = [_][]const u8{ "a" ** 1, "a" ** 20, "a" ** 51, "a" ** 100, "a" ** 150, "a" ** 132 };

    for (to_find) |i| {
        const val = try table.find_value(i, allocator);

        try expect_founded_value(val, i, allocator);
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

test "SSTable persists min and max keys" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_sstable_min_max") catch {};
    try cwd.createDirPath(testing_io, "test_sstable_min_max");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_sstable_min_max") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_sstable_min_max", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    try tb.put("m", "middle", KVSeq.init(1));
    try tb.put("z", "last", KVSeq.init(2));
    try tb.put("a", "first", KVSeq.init(3));

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);
    {
        var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
        defer table.deinit(testing_io);

        try std.testing.expectEqualSlices(u8, "a", table.min());
        try std.testing.expectEqualSlices(u8, "z", table.max());
    }

    {
        var table = try SSTable.open(&storage, meta, testing_io, allocator);
        defer table.deinit(testing_io);

        try std.testing.expectEqualSlices(u8, "a", table.min());
        try std.testing.expectEqualSlices(u8, "z", table.max());
    }
}

test "SSTable min and max keys include tombstones" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_sstable_min_max_tombstones") catch {};
    try cwd.createDirPath(testing_io, "test_sstable_min_max_tombstones");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_sstable_min_max_tombstones") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_sstable_min_max_tombstones", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    try tb.remove("a", KVSeq.init(1));
    try tb.put("m", "middle", KVSeq.init(2));
    try tb.remove("z", KVSeq.init(3));

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);
    {
        var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
        defer table.deinit(testing_io);

        try std.testing.expectEqualSlices(u8, "a", table.min());
        try std.testing.expectEqualSlices(u8, "z", table.max());
    }

    {
        var table = try SSTable.open(&storage, meta, testing_io, allocator);
        defer table.deinit(testing_io);

        try std.testing.expectEqualSlices(u8, "a", table.min());
        try std.testing.expectEqualSlices(u8, "z", table.max());
    }
}

test "Remove" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_db") catch {};
    try cwd.createDirPath(testing_io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_db") catch {
            @panic("gg");
        };
    }
    const dir = try cwd.openDir(testing_io, "test_db", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    try tb.put("b" ** 10, "b" ** 10, KVSeq.init(1));
    try tb.remove("b" ** 10, KVSeq.init(2));

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);

    var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
    defer table.deinit(testing_io);

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
    cwd.deleteTree(testing_io, "test_db") catch {};
    try cwd.createDirPath(testing_io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_db") catch {
            @panic("gg");
        };
    }
    const dir = try cwd.openDir(testing_io, "test_db", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    try tb.put("b" ** (BlockSize / 4), "b" ** (BlockSize / 4), KVSeq.init(1));
    try tb.put("b" ** (BlockSize / 4), "d" ** (BlockSize / 4), KVSeq.init(2));
    try tb.put("b" ** (BlockSize / 4), "c" ** (BlockSize / 4), KVSeq.init(3));
    try tb.put("b" ** (BlockSize / 4), "d" ** (BlockSize / 4), KVSeq.init(4));

    {
        var meta = try test_file_meta(allocator, 0, &tb);
        defer meta.deinit(allocator);
        var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
        defer table.deinit(testing_io);

        const val = try table.find_value("b" ** (BlockSize / 4), allocator);
        try expect_founded_value(val, "d" ** (BlockSize / 4), allocator);
    }

    {
        try tb.remove("b" ** (BlockSize / 4), KVSeq.init(5));

        var meta = try test_file_meta(allocator, 0, &tb);
        defer meta.deinit(allocator);
        var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
        defer table.deinit(testing_io);

        const val = try table.find_value("b" ** (BlockSize / 4), allocator);
        try expect_deleted(val);
    }
}

test "Merge" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const Repeats: usize = 150;

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_db") catch {};
    try cwd.createDirPath(testing_io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_db") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_db", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);
    inline for (1..Repeats) |i| {
        try tb.put("ab" ** ((i * 2) - 1), "ba" ** ((i * 2) - 1), KVSeq.init(i));
    }

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);
    var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
    defer table.deinit(testing_io);

    var tb1 = try MemTable.new(allocator, testing_io, .{});
    defer tb1.deinit(allocator);

    inline for (1..Repeats) |i| {
        try tb1.put("ab" ** (i * 2), "ba" ** (i * 2), KVSeq.init(Repeats + i));
    }

    var meta1 = try test_file_meta(allocator, 0, &tb1);
    defer meta1.deinit(allocator);
    var table1 = try SSTable.create(&storage, meta1, &tb1, testing_io, allocator);
    defer table1.deinit(testing_io);

    var merged_seq = FileSeq.init(@atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
    var merge_res = try SSTable.merge(
        &storage,
        test_output_file_source(&merged_seq),
        testing_io,
        &[2]SSTable{ table, table1 },
        1,
        1 << 30,
        allocator,
    );
    defer test_deinit_merge_result(&merge_res, allocator);

    try std.testing.expectEqual(@as(usize, 1), merge_res.items.len);

    var merged = try SSTable.open(&storage, merge_res.items[0], testing_io, allocator);
    defer merged.deinit(testing_io);

    {
        inline for (1..Repeats) |i| {
            const val = try merged.find_value("ab" ** i, allocator);
            try expect_founded_value(val, "ba" ** i, allocator);
        }
    }
}

test "Merged SSTable persists min and max keys" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_sstable_merge_min_max") catch {};
    try cwd.createDirPath(testing_io, "test_sstable_merge_min_max");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_sstable_merge_min_max") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_sstable_merge_min_max", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);
    try tb.put("b", "left", KVSeq.init(1));
    try tb.put("m", "middle", KVSeq.init(2));

    var tb1 = try MemTable.new(allocator, testing_io, .{});
    defer tb1.deinit(allocator);
    try tb1.remove("a", KVSeq.init(3));
    try tb1.put("z", "right", KVSeq.init(4));

    var merged_seq = FileSeq.init(@atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));
    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);
    var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
    defer table.deinit(testing_io);
    var meta1 = try test_file_meta(allocator, 0, &tb1);
    defer meta1.deinit(allocator);
    var table1 = try SSTable.create(&storage, meta1, &tb1, testing_io, allocator);
    defer table1.deinit(testing_io);

    var merge_res = try SSTable.merge(
        &storage,
        test_output_file_source(&merged_seq),
        testing_io,
        &[_]SSTable{
            table,
            table1,
        },
        1,
        1 << 30,
        allocator,
    );
    defer test_deinit_merge_result(&merge_res, allocator);

    {
        try std.testing.expectEqual(@as(usize, 1), merge_res.items.len);
        try std.testing.expectEqualSlices(u8, "a", merge_res.items[0].min.data);
        try std.testing.expectEqualSlices(u8, "z", merge_res.items[0].max.data);
    }

    {
        var merged = try SSTable.open(&storage, merge_res.items[0], testing_io, allocator);
        defer merged.deinit(testing_io);

        try std.testing.expectEqualSlices(u8, "a", merged.min());
        try std.testing.expectEqualSlices(u8, "z", merged.max());
    }
}

fn expect_founded_value(val: GetResult, expected: []const u8, allocator: Allocator) !void {
    switch (val) {
        .Found => |v| {
            try std.testing.expectEqualSlices(u8, v, expected);
            defer allocator.free(v);
        },
        else => {
            // std.debug.print("Failed to find value on iter {}\n", .{i});
            try std.testing.expect(false);
        },
    }
}

fn expect_deleted(val: GetResult) !void {
    switch (val) {
        .Removed => {},
        else => {
            // std.debug.print("Failed to find value on iter {}\n", .{i});
            try std.testing.expect(false);
        },
    }
}

fn expect_notfound(val: GetResult) !void {
    switch (val) {
        .NotFound => {},
        else => {
            // std.debug.print("Failed to find value on iter {}\n", .{i});
            try std.testing.expect(false);
        },
    }
}

test "Merge with remove and overlapping regions" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing_io, "test_db") catch {};
    try cwd.createDirPath(testing_io, "test_db");
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, "test_db") catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, "test_db", .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    var tb1 = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);
    defer tb1.deinit(allocator);

    var merged_seq = FileSeq.init(@atomicRmw(u64, &Lvl0Count, .Add, 1, .monotonic));

    try tb.put("a", "a", KVSeq.init(0));
    try tb.put("b", "b", KVSeq.init(1));
    try tb.put("c", "c", KVSeq.init(2));
    try tb.remove("b", KVSeq.init(3));

    try tb1.put("b", "b", KVSeq.init(5));
    try tb1.remove("a", KVSeq.init(6));
    try tb1.put("c", "cc", KVSeq.init(7));

    var meta = try test_file_meta(allocator, 0, &tb);
    defer meta.deinit(allocator);
    var table = try SSTable.create(&storage, meta, &tb, testing_io, allocator);
    defer table.deinit(testing_io);
    var meta1 = try test_file_meta(allocator, 0, &tb1);
    defer meta1.deinit(allocator);
    var table1 = try SSTable.create(&storage, meta1, &tb1, testing_io, allocator);
    defer table1.deinit(testing_io);

    var merge_res = try SSTable.merge(
        &storage,
        test_output_file_source(&merged_seq),
        testing_io,
        &[_]SSTable{ table, table1 },
        1,
        1 << 30,
        allocator,
    );
    defer test_deinit_merge_result(&merge_res, allocator);

    try std.testing.expectEqual(@as(usize, 1), merge_res.items.len);

    var merged = try SSTable.open(&storage, merge_res.items[0], testing_io, allocator);
    defer merged.deinit(testing_io);

    try expect_founded_value(try merged.find_value("b", allocator), "b", allocator);
    try expect_deleted(try merged.find_value("a", allocator));
    try expect_deleted(try merged.find_value("a", allocator));
    try expect_founded_value(try merged.find_value("c", allocator), "cc", allocator);
    try expect_notfound(try merged.find_value("aaa", allocator));
    try expect_notfound(try merged.find_value("bb", allocator));
}

test "Merge produces more than one file" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const dir_name = "merge_produces_more_than_1_file";

    cwd.deleteTree(testing_io, dir_name) catch {};
    try cwd.createDirPath(testing_io, dir_name);
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, dir_name) catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, dir_name, .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    var full_size: usize = 0;
    const kv_size: usize = 1000;

    inline for (97..100) |i| {
        const ch: u8 = @intCast(i);
        const s = [_]u8{ch} ** kv_size;

        full_size += kv_size * 2;
        try tb.put(&s, &s, KVSeq.init(i));
    }

    var tb1 = try MemTable.new(allocator, testing_io, .{});
    defer tb1.deinit(allocator);

    inline for (101..103) |i| {
        const ch: u8 = @intCast(i);
        const s = [_]u8{ch} ** kv_size;

        full_size += kv_size * 2;
        try tb1.put(&s, &s, KVSeq.init(i));
    }

    var meta1 = try test_file_meta(allocator, 0, &tb);
    defer meta1.deinit(allocator);
    var meta2 = try test_file_meta(allocator, 0, &tb1);
    defer meta2.deinit(allocator);

    var table1 = try SSTable.create(
        &storage,
        meta1,
        &tb,
        testing_io,
        allocator,
    );
    defer table1.deinit(testing_io);

    var table2 = try SSTable.create(
        &storage,
        meta2,
        &tb1,
        testing_io,
        allocator,
    );
    defer table2.deinit(testing_io);

    var merged_seq = FileSeq.init(@atomicRmw(u64, &Lvl0Count, .Add, 2, .monotonic));
    var merged = try SSTable.merge(
        &storage,
        test_output_file_source(&merged_seq),
        testing_io,
        &[_]SSTable{ table1, table2 },
        1,
        full_size / 4,
        allocator,
    );

    defer {
        for (merged.items) |*i| {
            i.deinit(allocator);
        }
        merged.deinit(allocator);
    }

    try std.testing.expect(merged.items.len >= 3);
}

test "Merge does not hand on same keys" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const dir_name = "merge_not_hungs_on_same_keys";

    cwd.deleteTree(testing_io, dir_name) catch {};
    try cwd.createDirPath(testing_io, dir_name);
    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, dir_name) catch {
            @panic("gg");
        };
    }

    const dir = try cwd.openDir(testing_io, dir_name, .{});
    var storage = try Storage.new(dir, 100, allocator);
    defer storage.deinit(testing_io, allocator);

    var tb = try MemTable.new(allocator, testing_io, .{});
    defer tb.deinit(allocator);

    var full_size: usize = 0;
    const kv_size: usize = 1000;

    inline for (97..100) |i| {
        const ch: u8 = @intCast(i);
        const s = [_]u8{ch} ** kv_size;

        full_size += kv_size * 2;
        try tb.put(&s, &s, KVSeq.init(i));
    }

    var tb1 = try MemTable.new(allocator, testing_io, .{});
    defer tb1.deinit(allocator);

    inline for (97..100) |i| {
        const ch: u8 = @intCast(i);
        const s = [_]u8{ch} ** kv_size;

        full_size += kv_size * 2;
        try tb1.put(&s, &s, KVSeq.init(i * 2));
    }

    var meta1 = try test_file_meta(allocator, 0, &tb);
    defer meta1.deinit(allocator);
    var meta2 = try test_file_meta(allocator, 0, &tb1);
    defer meta2.deinit(allocator);

    var table1 = try SSTable.create(
        &storage,
        meta1,
        &tb,
        testing_io,
        allocator,
    );
    defer table1.deinit(testing_io);

    var table2 = try SSTable.create(
        &storage,
        meta2,
        &tb1,
        testing_io,
        allocator,
    );
    defer table2.deinit(testing_io);

    var merged_seq = FileSeq.init(@atomicRmw(u64, &Lvl0Count, .Add, 2, .monotonic));
    var merged = try SSTable.merge(
        &storage,
        test_output_file_source(&merged_seq),
        testing_io,
        &[_]SSTable{ table1, table2 },
        1,
        full_size / 4,
        allocator,
    );

    defer {
        for (merged.items) |*i| {
            i.deinit(allocator);
        }
        merged.deinit(allocator);
    }

    try std.testing.expect(merged.items.len == 2);
}
