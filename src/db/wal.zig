const std = @import("std");
const BufferedFile = @import("io").BufferedFile;
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
const test_utils = @import("test_utils");
const fi = test_utils.Injections.fault_injection;
const Transaction = @import("manager.zig").Transaction;
const WriteOp = @import("manager.zig").WriteOp;
const PendingWrite = @import("manager.zig").PendingWrite;
const ei = test_utils.Injections.error_injection;

const AddMagic: u8 = 0x10;
const RemoveMagic: u8 = 0x12;

fn string_size(slice: []const u8) usize {
    return 8 + slice.len;
}

fn full_size(self: *const WriteOp) usize {
    var size: usize = 0;

    switch (self.*) {
        .Put => |add| {
            size += @sizeOf(@TypeOf(AddMagic));
            size += string_size(add.key);
            size += string_size(add.value);
            size += @sizeOf(@TypeOf(add.seq));
            size += 4; // checksum.
        },
        .Remove => |rem| {
            size += @sizeOf(@TypeOf(RemoveMagic));
            size += string_size(rem.key);
            size += @sizeOf(@TypeOf(rem.seq));
            size += 4; // checksum.
        },
    }

    return size;
}

fn checksum(self: *const WriteOp) u32 {
    var hash = Crc32.init();

    switch (self.*) {
        .Put => |add| {
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

/// WAL options
pub const WalOpts = struct {
    sync: bool = false,
};

pub const Wal = struct {
    // WAL file
    file: BufferedFile,
    // WAL user options
    opts: WalOpts,

    fn file_name(alloc: Allocator, seq: FileSeq) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        return res;
    }

    pub fn open(dir: Dir, seq: FileSeq, io: Io, alloc: Allocator) !Wal {
        return open_with_opts(dir, seq, .{}, io, alloc);
    }

    pub fn open_with_opts(dir: Dir, seq: FileSeq, opts: WalOpts, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.openFile(io, name, .{ .mode = .read_write });
        errdefer file.close(io);
        return .{ .file = BufferedFile.readonly(file), .opts = opts };
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
        opts: WalOpts,
        io: Io,
        alloc: Allocator,
    ) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.createFile(io, name, .{ .read = true });
        errdefer file.close(io);

        if (version) |v| {
            var edit = try VersionEdit.empty(alloc);
            defer edit.deinit(alloc);

            edit.add_wal = seq;
            try v.apply(edit, dir, io, alloc);
        }

        return .{
            .file = try BufferedFile.new(file, alloc),
            .opts = opts,
        };
    }

    pub fn commit(self: *Wal, trans: Transaction, io: std.Io, alloc: Allocator) !void {
        _ = alloc;

        {
            var i = trans.iter();
            while (i.next()) |e| {
                Wal.record(e.op, &self.file, io) catch @panic("must not fail");
            }
        }

        try ei.maybe_error(.wal_flush, self.file.flush(io));

        if (self.opts.sync)
            try ei.maybe_error(.wal_sync, self.file.sync(io));
    }

    // Records one entry to the buffer
    fn record(entry: WriteOp, w: *BufferedFile, io: std.Io) !void {
        switch (entry) {
            .Put => |add| {
                try w.append(&std.mem.toBytes(AddMagic), io);
                try w.append(&std.mem.toBytes(add.key.len), io);
                try w.append(add.key, io);
                try w.append(&std.mem.toBytes(add.value.len), io);
                try w.append(add.value, io);
                try w.append(&std.mem.toBytes(add.seq.get()), io);
                try w.append(&std.mem.toBytes(checksum(&entry)), io);
            },
            .Remove => |rem| {
                try w.append(&std.mem.toBytes(RemoveMagic), io);
                try w.append(&std.mem.toBytes(rem.key.len), io);
                try w.append(rem.key, io);
                try w.append(&std.mem.toBytes(rem.seq.get()), io);
                try w.append(&std.mem.toBytes(checksum(&entry)), io);
            },
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
            self.file.file.handle,
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

                    const check = std.mem.readInt(u32, mmap[iter..][0..@sizeOf(u32)], .little);
                    const entry = WriteOp{ .Put = .{ .seq = seq, .key = key, .value = value } };

                    if (check != checksum(&entry))
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

                    const check = std.mem.readInt(u32, mmap[iter..][0..@sizeOf(u32)], .little);
                    const entry = WriteOp{ .Remove = .{ .seq = seq, .key = key } };

                    if (check != checksum(&entry))
                        return error.InvalidChecksum;

                    iter += @sizeOf(u32);
                    try to.remove_but_record(key, seq);
                },
                else => return error.InvalidFormat,
            }
        }
    }

    pub fn deinit(self: *Wal, alloc: Allocator, io: std.Io) !void {
        self.file.close(alloc, io);
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
    defer wal.deinit(alloc, testing_io) catch unreachable;

    var target = try WalTable.new(dir, .{}, .{}, FileSeq.init(seq + 1000), null, testing_io, alloc);
    defer target.deinit(alloc) catch unreachable;

    try std.testing.expectError(error.InvalidFormat, wal.replay_to(&target, testing_io));
}

fn pushPut(trans: *Transaction, pending: *PendingWrite, key: []const u8, value: []const u8, seq: usize) void {
    pending.* = .{
        .op = .{ .Put = .{ .key = key, .value = value, .seq = KVSeq.init(seq) } },
        .done = false,
    };
    trans.push_active(pending);
}

fn pushRemove(trans: *Transaction, pending: *PendingWrite, key: []const u8, seq: usize) void {
    pending.* = .{
        .op = .{ .Remove = .{ .key = key, .seq = KVSeq.init(seq) } },
        .done = false,
    };
    trans.push_active(pending);
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

    var trans = Transaction{};
    var pending: PendingWrite = undefined;
    pushPut(&trans, &pending, "alpha", "one", 7);
    const entry = pending.op;

    var wal = try Wal.new(dir, FileSeq.init(1), null, .{}, testing_io, allocator);
    try wal.commit(trans, testing_io, allocator);
    try wal.deinit(allocator, testing_io);

    const data = try readWalFile(dir, 1, allocator);
    defer allocator.free(data);
    try std.testing.expectEqual(full_size(&entry), data.len);

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

    try std.testing.expectEqual(checksum(&entry), readU32(data[pos .. pos + @sizeOf(u32)]));
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

    var trans = Transaction{};
    var pending: PendingWrite = undefined;
    pushRemove(&trans, &pending, "beta", 42);
    const entry = pending.op;

    var wal = try Wal.new(dir, FileSeq.init(2), null, .{}, testing_io, allocator);
    try wal.commit(trans, testing_io, allocator);
    try wal.deinit(allocator, testing_io);

    const data = try readWalFile(dir, 2, allocator);
    defer allocator.free(data);
    try std.testing.expectEqual(full_size(&entry), data.len);

    var pos: usize = 0;
    try std.testing.expectEqual(RemoveMagic, data[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(usize, 4), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "beta", data[pos .. pos + 4]);
    pos += 4;
    try std.testing.expectEqual(@as(usize, 42), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);

    try std.testing.expectEqual(checksum(&entry), readU32(data[pos .. pos + @sizeOf(u32)]));
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

    var trans = Transaction{};
    var add: PendingWrite = undefined;
    var remove: PendingWrite = undefined;
    pushPut(&trans, &add, "alpha", "one", 7);
    pushRemove(&trans, &remove, "alpha", 8);
    const add_entry = add.op;
    const remove_entry = remove.op;

    var wal = try Wal.new(dir, FileSeq.init(3), null, .{}, testing_io, allocator);
    try wal.commit(trans, testing_io, allocator);
    try wal.deinit(allocator, testing_io);

    const data = try readWalFile(dir, 3, allocator);
    defer allocator.free(data);
    try std.testing.expectEqual(full_size(&add_entry) + full_size(&remove_entry), data.len);

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
    try std.testing.expectEqual(checksum(&add_entry), readU32(data[pos .. pos + @sizeOf(u32)]));
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
    try std.testing.expectEqual(checksum(&remove_entry), readU32(data[pos .. pos + @sizeOf(u32)]));
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

    var trans = Transaction{};
    var pending: PendingWrite = undefined;
    pushPut(&trans, &pending, "alpha", "one", 7);

    var wal = try Wal.new(dir, FileSeq.init(4), null, .{}, testing_io, allocator);
    defer wal.deinit(allocator, testing_io) catch unreachable;
    try wal.commit(trans, testing_io, allocator);

    var target = try WalTable.new(dir, .{}, .{}, FileSeq.init(5), null, testing_io, allocator);
    defer target.deinit(allocator) catch unreachable;
    try wal.replay_to(&target, testing_io);

    const value = try target.get("alpha", KVSeq.init(7), allocator);
    switch (value) {
        .Found => |v| {
            defer allocator.free(v);
            try std.testing.expectEqualSlices(u8, "one", v);
        },
        else => try std.testing.expect(false),
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

    var trans = Transaction{};
    var pending: PendingWrite = undefined;
    pushRemove(&trans, &pending, "alpha", 8);

    var wal = try Wal.new(dir, FileSeq.init(6), null, .{}, testing_io, allocator);
    defer wal.deinit(allocator, testing_io) catch unreachable;
    try wal.commit(trans, testing_io, allocator);

    var target = try WalTable.new(dir, .{}, .{}, FileSeq.init(7), null, testing_io, allocator);
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

    var trans = Transaction{};
    var add: PendingWrite = undefined;
    var remove: PendingWrite = undefined;
    pushPut(&trans, &add, "alpha", "one", 7);
    pushRemove(&trans, &remove, "alpha", 8);

    var wal = try Wal.new(dir, FileSeq.init(8), null, .{}, testing_io, allocator);
    defer wal.deinit(allocator, testing_io) catch unreachable;
    try wal.commit(trans, testing_io, allocator);

    var target = try WalTable.new(dir, .{}, .{}, FileSeq.init(9), null, testing_io, allocator);
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
        else => try std.testing.expect(false),
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
