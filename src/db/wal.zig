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

    fn file_name(alloc: Allocator, seq: FileSeq) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        return res;
    }

    pub fn open(dir: Dir, seq: FileSeq, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.openFile(io, name, .{ .mode = .read_write });
        return .{ .file = file };
    }

    pub fn new(dir: Dir, seq: FileSeq, version: ?*Version, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.createFile(io, name, .{ .read = true });

        if (version) |v| {
            var edit = try VersionEdit.empty(alloc);
            defer edit.deinit(alloc);

            edit.add_wal = seq;
            try v.apply(edit, dir, io, alloc);
        }

        return .{ .file = file };
    }

    pub fn record(self: *Wal, entry: WalEntry, alloc: Allocator, io: Io) !void {
        // Here we rely on Linux behavior regarding concurrent file writes from the threads of the _same process_.
        //
        // man 2 write:
        //        Among  the  APIs  subsequently  listed  are  write()  and  writev(2).   And among the effects that 
        //        should be atomic across threads (and processes) are updates of the file offset.
        //
        // So we allocate enough heap buffer, write to it and atomically dump it to the disk. Test at the end sanity-checks
        // this behavior.

        const buf = try alloc.alloc(u8, entry.full_size());
        defer alloc.free(buf);

        var fw = self.file.writerStreaming(io, buf);
        const w = &fw.interface;

        switch (entry) {
            .Add => |add| {
                try w.writeAll(&std.mem.toBytes(AddMagic));
                try w.writeAll(&std.mem.toBytes(add.key.len));
                try w.writeAll(add.key);
                try w.writeAll(&std.mem.toBytes(add.value.len));
                try w.writeAll(add.value);
                try w.writeAll(&std.mem.toBytes(add.seq.get()));
                try w.writeAll(&std.mem.toBytes(entry.checksum()));
            },
            .Remove => |rem| {
                try w.writeAll(&std.mem.toBytes(RemoveMagic));
                try w.writeAll(&std.mem.toBytes(rem.key.len));
                try w.writeAll(rem.key);
                try w.writeAll(&std.mem.toBytes(rem.seq.get()));
                try w.writeAll(&std.mem.toBytes(entry.checksum()));
            },
        }

        try w.flush();

        // tho in case of that error things would be quite fun...
        try self.file.sync(io);
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
                else => return error.InvalidFormat,
            }
        }
    }

    pub fn deinit(self: *Wal, io: std.Io) void {
        self.file.close(io);
    }
};

// AI SLOP! (thanks for attention)

const testing_io = std.testing.io;

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
    defer target.deinit(alloc);

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

    var wal = try Wal.new(dir, FileSeq.init(1), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }, allocator, testing_io);

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

    var wal = try Wal.new(dir, FileSeq.init(2), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Remove = .{ .key = "beta", .seq = KVSeq.init(42) } }, allocator, testing_io);

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

    var wal = try Wal.new(dir, FileSeq.init(3), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }, allocator, testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } }, allocator, testing_io);

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

    var wal = try Wal.new(dir, FileSeq.init(4), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }, allocator, testing_io);

    var target = try WalTable.new(dir, null, FileSeq.init(5), null, testing_io, allocator);
    defer target.deinit(allocator);
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

    var wal = try Wal.new(dir, FileSeq.init(6), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } }, allocator, testing_io);

    var target = try WalTable.new(dir, null, FileSeq.init(7), null, testing_io, allocator);
    defer target.deinit(allocator);
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

    var wal = try Wal.new(dir, FileSeq.init(8), null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = KVSeq.init(7) } }, allocator, testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = KVSeq.init(8) } }, allocator, testing_io);

    var target = try WalTable.new(dir, null, FileSeq.init(9), null, testing_io, allocator);
    defer target.deinit(allocator);
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

        try wal.record(entry, alloc, testing_io);
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

    var wal = try Wal.new(dir, FileSeq.init(0), null, testing_io, allocator);
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
    defer target.deinit(allocator);

    try wal.replay_to(&target, testing_io);
}
