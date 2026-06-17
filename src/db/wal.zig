const std = @import("std");
const File = std.Io.File;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const WalTable = @import("wal_table.zig").WalTable;
const Version = @import("version.zig").Version;
const VersionEdit = @import("version.zig").VersionEdit;
const Crc32 = std.hash.Crc32;
const KVSeq = @import("storage").KVSeq;
const FileSeq = @import("storage").manifest.FileSeq;
const KeyValue = @import("storage").KeyValue;
const Value = std.atomic.Value;
const BufferWriter = @import("buffer_writer.zig").BufferWriter;
const test_utils = @import("test_utils");
const fi = test_utils.Injections.fault_injection;

const AddMagic: u8 = 0x10;
const RemoveMagic: u8 = 0x12;

pub const WalEntry = union(enum) {
    // Added key value
    Add: struct {
        key: []const u8,
        value: []const u8,
        seq: KVSeq,
    },

    // Removed key
    Remove: struct {
        key: []const u8,
        seq: KVSeq,
    },

    // Since we know in advance how many bytes of payload we will have, we can can precompute
    // maximum amount of data user can write.
    fn precalculate_size(memtable_size: usize) usize {
        // Given the smallest key we can calculate how many WAL records we will have.
        const min_kv_size = KeyValue.calculate_size("a", null);
        const max_records = (memtable_size / min_kv_size) + 1;
        const wal_max_overhead = (WalEntry{ .Add = .{
            .key = "a",
            .value = "a",
            .seq = KVSeq.init(0),
        } }).full_size() - 2;

        return memtable_size + max_records * wal_max_overhead;
    }

    fn string_size(slice: []const u8) usize {
        return 8 + slice.len;
    }

    fn full_size(self: *const WalEntry) usize {
        var size: usize = 0;

        switch (self.*) {
            .Add => |add| {
                size += @sizeOf(@TypeOf(AddMagic));
                size += WalEntry.string_size(add.key);
                size += WalEntry.string_size(add.value);
                size += @sizeOf(@TypeOf(add.seq));
                size += 4; // checksum.
            },
            .Remove => |rem| {
                size += @sizeOf(@TypeOf(RemoveMagic));
                size += WalEntry.string_size(rem.key);
                size += @sizeOf(@TypeOf(rem.seq));
                size += 4; // checksum.
            },
        }

        return size;
    }

    fn checksum(self: *const WalEntry) u32 {
        var hash = Crc32.init();

        switch (self.*) {
            .Add => |add| {
                hash.update(add.key);
                hash.update(add.value);
                hash.update(&std.mem.toBytes(add.seq.get()));
            },
            .Remove => |rem| {
                hash.update(rem.key);
                hash.update(&std.mem.toBytes(rem.seq.get()));
            },
        }

        return hash.final();
    }
};

pub const Wal = struct {
    // WAL file
    file: File,
    // Offset within file
    offset: Value(usize),
    // Mmaped file
    data: ?[]u8,

    fn file_name(alloc: Allocator, seq: FileSeq) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        return res;
    }

    pub fn open(dir: Dir, seq: FileSeq, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.openFile(io, name, .{ .mode = .read_write });
        return .{ .file = file, .offset = Value(usize).init(0), .data = null };
    }

    pub fn is_wal_name(name: []const u8) bool {
        return std.mem.startsWith(u8, name, "WAL") and std.mem.endsWith(u8, name, ".sst");
    }

    pub fn unlink(dir: Dir, seq: FileSeq, io: std.Io, alloc: Allocator) !void {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        try dir.deleteFile(io, name);
    }

    pub fn new(
        dir: Dir,
        seq: FileSeq,
        version: ?*Version,
        memtable_size: usize,
        io: Io,
        alloc: Allocator,
    ) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.createFile(io, name, .{ .read = true });
        errdefer file.close(io);
        const file_size = WalEntry.precalculate_size(memtable_size);

        try file.setLength(io, file_size);
        const mmap = try std.posix.mmap(
            null,
            file_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(mmap);

        if (version) |v| {
            var edit = try VersionEdit.empty(alloc);
            defer edit.deinit(alloc);

            edit.add_wal = seq;
            try v.apply(edit, dir, io, alloc);
        }

        return .{
            .file = file,
            .offset = Value(usize).init(0),
            .data = mmap,
        };
    }

    pub fn record(self: *Wal, entry: WalEntry) !void {
        // TODO: This makes parsing a little bit harder than it should be. Imagine following:
        //
        //      T1:                                     T2:
        //
        //   new_offset = fetchAdd()
        //
        //                                            new_offset = fetchAdd();
        //                                            <writes data>
        //   crashes.
        //
        // It would mean that there is a hole in WAL.
        //
        // 1) Need a test for that
        // 2) Need a parsing fix.
        const my_offset = self.offset.fetchAdd(entry.full_size(), .monotonic);
        const data = self.data.?;
        var w = BufferWriter.init(data[my_offset .. my_offset + entry.full_size()]);

        std.debug.assert(my_offset + entry.full_size() <= self.data.?.len);

        fi.crash(.after_wal_slot_allocation);
        test_utils.Scheduler.yield(.WalSlotAllocated);

        switch (entry) {
            .Add => |add| {
                w.writeAll(&std.mem.toBytes(AddMagic));
                w.writeAll(&std.mem.toBytes(add.key.len));
                w.writeAll(add.key);
                w.writeAll(&std.mem.toBytes(add.value.len));
                w.writeAll(add.value);
                w.writeAll(&std.mem.toBytes(add.seq.get()));
                w.writeAll(&std.mem.toBytes(entry.checksum()));
            },
            .Remove => |rem| {
                w.writeAll(&std.mem.toBytes(RemoveMagic));
                w.writeAll(&std.mem.toBytes(rem.key.len));
                w.writeAll(rem.key);
                w.writeAll(&std.mem.toBytes(rem.seq.get()));
                w.writeAll(&std.mem.toBytes(entry.checksum()));
            },
        }

        // TODO: this is insanely bad! I need to come up with better protocol here.
        {
            const page_size = std.heap.page_size_min;

            const dt = self.data.?;
            const base = @intFromPtr(dt.ptr);
            const mapped_end = base + dt.len;

            const start = @intFromPtr(w.buf.ptr);
            const end = start + w.buf.len;

            const aligned_start = std.mem.alignBackward(usize, start, page_size);
            const aligned_end = @min(std.mem.alignForward(usize, end, page_size), mapped_end);

            const off = aligned_start - base;
            const len = aligned_end - aligned_start;

            // tho in case of that error things would be quite fun...
            try std.posix.msync(@alignCast(dt[off .. off + len]), std.posix.MSF.SYNC);
        }
    }

    pub fn replay_to(self: *const Wal, to: *WalTable, io: std.Io) !void {
        const stat = try self.file.stat(io);
        const size = stat.size;

        if (size == 0)
            return;

        const mmap = try std.posix.mmap(
            null,
            size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            self.file.handle,
            0,
        );
        defer std.posix.munmap(mmap);

        var iter: usize = 0;

        while (iter != size) {
            const magic = mmap[iter];
            iter += 1;

            if (size - iter < @sizeOf(usize))
                return error.InvalidFormat;

            const key_size = std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little);
            iter += @sizeOf(usize);

            if (size - iter < key_size)
                return error.InvalidFormat;

            const key = mmap[iter .. iter + key_size];
            iter += key_size;

            switch (magic) {
                AddMagic => {
                    if (size - iter < @sizeOf(usize))
                        return error.InvalidFormat;

                    const value_size = std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little);
                    iter += @sizeOf(usize);

                    if (size - iter < value_size)
                        return error.InvalidFormat;

                    const value = mmap[iter .. iter + value_size];
                    iter += value_size;

                    if (size - iter < @sizeOf(usize))
                        return error.InvalidFormat;

                    const seq = KVSeq.init(std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little));
                    iter += @sizeOf(usize);

                    if (size - iter < @sizeOf(u32))
                        return error.InvalidFormat;

                    const checksum = std.mem.readInt(u32, mmap[iter..][0..@sizeOf(u32)], .little);
                    const entry = WalEntry{ .Add = .{ .seq = seq, .key = key, .value = value } };

                    if (checksum != entry.checksum())
                        return error.InvalidChecksum;

                    iter += @sizeOf(u32);
                    try to.put_but_record(key, value, seq);
                },
                RemoveMagic => {
                    if (size - iter < @sizeOf(usize))
                        return error.InvalidFormat;

                    const seq = KVSeq.init(std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little));
                    iter += @sizeOf(usize);

                    if (size - iter < @sizeOf(u32))
                        return error.InvalidFormat;

                    const checksum = std.mem.readInt(u32, mmap[iter..][0..@sizeOf(u32)], .little);
                    const entry = WalEntry{ .Remove = .{ .seq = seq, .key = key } };

                    if (checksum != entry.checksum())
                        return error.InvalidChecksum;

                    iter += @sizeOf(u32);
                    try to.remove_but_record(key, seq);
                },
                0 => return,
                else => return error.InvalidFormat,
            }
        }
    }

    pub fn deinit(self: *Wal, io: std.Io) !void {
        // Adjust file size to actually written amount.
        try self.file.setLength(io, self.offset.load(.monotonic));

        if (self.data) |data| {
            std.posix.munmap(@alignCast(data));
        }

        self.file.close(io);
    }
};

// AI SLOP! (thanks for attention)

const testing_io = std.testing.io;
const TestWalMemtableSize = 1 << 20;

fn openTestDir(dirname: []const u8) !Dir {
    const cwd = Dir.cwd();

    cwd.deleteTree(testing_io, dirname) catch {};
    try cwd.createDir(testing_io, dirname, .default_dir);
    return try cwd.openDir(testing_io, dirname, .{});
}

fn readWalFile(dir: Dir, seq: usize, alloc: Allocator) ![]u8 {
    const name = try Wal.file_name(alloc, FileSeq.init(seq));
    defer alloc.free(name);

    const file = try dir.openFile(testing_io, name, .{});
    defer file.close(testing_io);

    const stat = try file.stat(testing_io);
    const data = try alloc.alloc(u8, stat.size);
    errdefer alloc.free(data);

    _ = try file.readPositionalAll(testing_io, data, 0);
    return data;
}

fn writeWalFile(dir: Dir, seq: usize, data: []const u8, alloc: Allocator) !void {
    const name = try Wal.file_name(alloc, FileSeq.init(seq));
    defer alloc.free(name);

    const file = try dir.createFile(testing_io, name, .{
        .truncate = true,
        .read = true,
    });
    defer file.close(testing_io);

    try file.writePositionalAll(testing_io, data, 0);
}

fn readUsize(data: []const u8) usize {
    return std.mem.readInt(usize, data[0..@sizeOf(usize)], .little);
}

fn readU32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..@sizeOf(u32)], .little);
}

fn expectReplayInvalidFormat(dir: Dir, seq: usize, data: []const u8, alloc: Allocator) !void {
    try writeWalFile(dir, seq, data, alloc);

    var wal = try Wal.open(dir, FileSeq.init(seq), testing_io, alloc);
    defer wal.file.close(testing_io);

    var target = try WalTable.new(dir, null, FileSeq.init(seq + 1000), null, testing_io, alloc);
    defer target.deinit(alloc) catch unreachable;

    try std.testing.expectError(error.InvalidFormat, wal.replay_to(&target, testing_io));
}

test "WAL serializes add record" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_add_record";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(1), null, TestWalMemtableSize, testing_io, allocator);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } });
    try wal.deinit(testing_io);

    const data = try readWalFile(dir, 1, allocator);
    defer allocator.free(data);

    var pos: usize = 0;
    try std.testing.expectEqual(AddMagic, data[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(usize, 5), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "alpha", data[pos .. pos + 5]);
    pos += 5;
    try std.testing.expectEqual(@as(usize, 3), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "one", data[pos .. pos + 3]);
    pos += 3;
    try std.testing.expectEqual(@as(usize, 7), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqual(
        (WalEntry{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }).checksum(),
        readU32(data[pos .. pos + @sizeOf(u32)]),
    );
    pos += @sizeOf(u32);
    try std.testing.expectEqual(data.len, pos);
}

test "WAL serializes remove record" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_remove_record";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(2), null, TestWalMemtableSize, testing_io, allocator);
    try wal.record(.{ .Remove = .{ .key = "beta", .seq = KVSeq.init(42) } });
    try wal.deinit(testing_io);

    const data = try readWalFile(dir, 2, allocator);
    defer allocator.free(data);

    var pos: usize = 0;
    try std.testing.expectEqual(RemoveMagic, data[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(usize, 4), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "beta", data[pos .. pos + 4]);
    pos += 4;
    try std.testing.expectEqual(@as(usize, 42), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqual(
        (WalEntry{ .Remove = .{ .key = "beta", .seq = KVSeq.init(42) } }).checksum(),
        readU32(data[pos .. pos + @sizeOf(u32)]),
    );
    pos += @sizeOf(u32);
    try std.testing.expectEqual(data.len, pos);
}

test "WAL serializes records in append order" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_multiple_records";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(3), null, TestWalMemtableSize, testing_io, allocator);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } });
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } });
    try wal.deinit(testing_io);

    const data = try readWalFile(dir, 3, allocator);
    defer allocator.free(data);

    var pos: usize = 0;
    try std.testing.expectEqual(AddMagic, data[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(usize, 5), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "alpha", data[pos .. pos + 5]);
    pos += 5;
    try std.testing.expectEqual(@as(usize, 3), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "one", data[pos .. pos + 3]);
    pos += 3;
    try std.testing.expectEqual(@as(usize, 7), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqual(
        (WalEntry{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }).checksum(),
        readU32(data[pos .. pos + @sizeOf(u32)]),
    );
    pos += @sizeOf(u32);

    try std.testing.expectEqual(RemoveMagic, data[pos]);
    pos += 1;
    const remove_size = readUsize(data[pos .. pos + @sizeOf(usize)]);
    try std.testing.expectEqual(@as(usize, 5), remove_size);
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "alpha", data[pos .. pos + remove_size]);
    pos += remove_size;
    try std.testing.expectEqual(@as(usize, 8), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqual(
        (WalEntry{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } }).checksum(),
        readU32(data[pos .. pos + @sizeOf(u32)]),
    );
    pos += @sizeOf(u32);

    try std.testing.expectEqual(data.len, pos);
}

test "WAL replay restores add record into target table" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_add";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(4), null, TestWalMemtableSize, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } });

    var target = try WalTable.new(dir, null, FileSeq.init(5), null, testing_io, allocator);
    defer target.deinit(allocator) catch unreachable;
    try wal.replay_to(&target, testing_io);

    const value = try target.get("alpha", KVSeq.init(7), allocator);
    switch (value) {
        .Found => |v| {
            defer allocator.free(v);
            try std.testing.expectEqualSlices(u8, "one", v);
        },
        else => @panic("expected replayed value"),
    }
}

test "WAL replay restores remove record into target table" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_remove";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(6), null, TestWalMemtableSize, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } });

    var target = try WalTable.new(dir, null, FileSeq.init(7), null, testing_io, allocator);
    defer target.deinit(allocator) catch unreachable;
    try wal.replay_to(&target, testing_io);

    const value = try target.get("alpha", KVSeq.init(8), allocator);
    try std.testing.expectEqual(@as(@TypeOf(value), .Removed), value);
}

test "WAL replay applies later remove over earlier add" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_add_remove";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(8), null, TestWalMemtableSize, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } });
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } });

    var target = try WalTable.new(dir, null, FileSeq.init(9), null, testing_io, allocator);
    defer target.deinit(allocator) catch unreachable;
    try wal.replay_to(&target, testing_io);

    const removed = try target.get("alpha", KVSeq.init(8), allocator);
    try std.testing.expectEqual(@as(@TypeOf(removed), .Removed), removed);

    const old_value = try target.get("alpha", KVSeq.init(7), allocator);
    switch (old_value) {
        .Found => |v| {
            defer allocator.free(v);
            try std.testing.expectEqualSlices(u8, "one", v);
        },
        else => @panic("expected older sequence to see original value"),
    }
}

test "WAL replay rejects unknown record magic" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_bad_magic";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var data: [1 + @sizeOf(usize)]u8 = undefined;
    data[0] = 0xff;
    @memcpy(data[1..], &std.mem.toBytes(@as(usize, 0)));

    try expectReplayInvalidFormat(dir, 10, &data, allocator);
}

test "WAL replay rejects truncated record size" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_truncated_size";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    const data = [_]u8{ AddMagic, 1, 2, 3 };
    try expectReplayInvalidFormat(dir, 11, &data, allocator);
}

test "WAL replay rejects add record with truncated payload" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_truncated_add";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var data: [1 + @sizeOf(usize) + 2]u8 = undefined;
    data[0] = AddMagic;
    @memcpy(data[1 .. 1 + @sizeOf(usize)], &std.mem.toBytes(@as(usize, 8)));
    @memcpy(data[1 + @sizeOf(usize) ..], "xy");

    try expectReplayInvalidFormat(dir, 12, &data, allocator);
}

test "WAL replay rejects remove record without sequence number" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_truncated_remove_seq";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var data: [1 + @sizeOf(usize) + 5]u8 = undefined;
    data[0] = RemoveMagic;
    @memcpy(data[1 .. 1 + @sizeOf(usize)], &std.mem.toBytes(@as(usize, 5)));
    @memcpy(data[1 + @sizeOf(usize) ..], "alpha");

    try expectReplayInvalidFormat(dir, 13, &data, allocator);
}

var Stop = std.atomic.Value(bool).init(false);

fn thread_big_insert(wal: *Wal, c: u8, alloc: Allocator) !void {
    const key = try alloc.alloc(u8, 200 * 1024);
    defer alloc.free(key);

    const value = try alloc.alloc(u8, 200 * 1024);
    defer alloc.free(value);

    @memset(key, c);
    @memset(value, c);

    while (Stop.load(.monotonic) == false) {
        const entry: WalEntry = .{ .Add = .{ .key = key, .value = value, .seq = KVSeq.init(0) } };

        try wal.record(entry);
    }
}

test "WAL concurency" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_replay_truncated_remove_seq";
    const thread_count = 16;

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var threads = try std.ArrayList(std.Thread).initCapacity(allocator, thread_count);
    defer threads.deinit(allocator);

    var wal = try Wal.new(dir, FileSeq.init(0), null, 10 << 30, testing_io, allocator);
    const ch: u8 = 'a';

    for (0..thread_count) |i| {
        try threads.append(allocator, try std.Thread.spawn(.{}, thread_big_insert, .{
            &wal,
            ch + @as(u8, @intCast(i)),
            allocator,
        }));
    }

    try std.Io.sleep(testing_io, .fromSeconds(5), .awake);
    Stop.store(true, .monotonic);

    for (threads.items) |thread| {
        thread.join();
    }

    // Check WAL sanity
    var target = try WalTable.new(dir, null, FileSeq.init(0), null, testing_io, allocator);
    defer target.deinit(allocator) catch unreachable;

    try wal.replay_to(&target, testing_io);
}

fn push_to_wal(wal: *Wal, count: usize) !void {
    var key: [200]u8 = undefined;
    var value: [200]u8 = undefined;

    @memset(&key, 'a');
    @memset(&value, 'b');

    for (0..count) |_| {
        const entry: WalEntry = .{ .Add = .{
            .key = &key,
            .value = &value,
            .seq = KVSeq.init(0),
        } };

        try wal.record(entry);
    }
}

test "WAL hole" {
    const prefix_records = 1;
    const records_after_hole = 10;

    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_wal_hole_parsing";

    var dir = try openTestDir(dirname);
    defer {
        dir.close(testing_io);
        Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test wal dir");
        };
    }

    var wal = try Wal.new(dir, FileSeq.init(0), null, 10 << 30, testing_io, allocator);
    defer {
        wal.deinit(testing_io) catch @panic("oh oh");
    }

    try push_to_wal(&wal, prefix_records);

    var sched = try test_utils.Scheduler.Scheduler.new(allocator);
    defer sched.deinit(allocator);

    const first_writer = try sched.spawn(push_to_wal, .{ &wal, 1 }, allocator);
    const second_writer = try sched.spawn(push_to_wal, .{ &wal, records_after_hole }, allocator);

    sched.run_until_sleep(first_writer, .WalSlotAllocated);
    sched.run_until_done(second_writer, allocator);

    // Check WAL sanity.
    var target = try WalTable.new(dir, null, FileSeq.init(1), null, testing_io, allocator);
    defer target.deinit(allocator) catch @panic("oh oh");
    try wal.replay_to(&target, testing_io);

    try std.testing.expectEqual(@as(usize, prefix_records + records_after_hole), target.len());
}
