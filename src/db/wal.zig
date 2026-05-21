const std = @import("std");
const File = std.Io.File;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const WalTable = @import("wal_table.zig").WalTable;
const Version = @import("version.zig").Version;
const VersionEdit = @import("version.zig").VersionEdit;

const AddMagic: u8 = 0x10;
const RemoveMagic: u8 = 0x12;

pub const WalEntry = union(enum) {
    // Added key value
    Add: struct {
        key: []const u8,
        value: []const u8,
        seq: usize,
    },

    // Removed key
    Remove: struct {
        key: []const u8,
        seq: usize,
    },

    fn full_size(self: *const WalEntry) usize {
        return switch (*self) {
            .Add => |add| @sizeOf(usize) + add.key.len + @sizeOf(usize) + add.value.len + @sizeOf(usize),
            .Remove => |rem| rem.key.len + @sizeOf(usize),
        };
    }
};

pub const Wal = struct {
    // WAL file
    file: File,

    fn file_name(alloc: Allocator, seq: usize) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq});
        return res;
    }

    pub fn open(dir: Dir, seq: usize, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.openFile(io, name, .{ .mode = .read_write });
        return .{ .file = file };
    }

    pub fn new(dir: Dir, seq: usize, version: ?*Version, io: Io, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = try dir.createFile(io, name, .{ .read = true });

        if (version) |v| {
            var edit = try VersionEdit.empty(alloc);

            edit.add_wal = seq;
            try v.apply(edit, alloc);
        }

        return .{ .file = file };
    }

    pub fn record(self: *Wal, entry: WalEntry, io: Io) !void {
        // TODO: I really don't know how to pass an allocator here. Let's keep small on-stack buffer for now
        // and maybe measure some perf.
        var buf: [64 * 1024]u8 = undefined;
        var fw = self.file.writerStreaming(io, &buf);
        const w = &fw.interface;

        switch (entry) {
            .Add => |add| {
                try w.writeAll(&std.mem.toBytes(AddMagic));
                try w.writeAll(&std.mem.toBytes(add.key.len));
                try w.writeAll(add.key);
                try w.writeAll(&std.mem.toBytes(add.value.len));
                try w.writeAll(add.value);
                try w.writeAll(&std.mem.toBytes(add.seq));
            },
            .Remove => |rem| {
                try w.writeAll(&std.mem.toBytes(RemoveMagic));
                try w.writeAll(&std.mem.toBytes(rem.key.len));
                try w.writeAll(rem.key);
                try w.writeAll(&std.mem.toBytes(rem.seq));
            },
        }

        try w.flush();
    }

    pub fn replay_to(self: *const Wal, to: *WalTable, io: std.Io) !void {
        const stat = try self.file.stat(io);
        const size = stat.size;

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

                    const seq = std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little);
                    iter += @sizeOf(usize);

                    try to.put_but_record(key, value, seq);
                },
                RemoveMagic => {
                    if (size - iter < @sizeOf(usize))
                        return error.InvalidFormat;

                    const seq = std.mem.readInt(usize, mmap[iter..][0..@sizeOf(usize)], .little);
                    iter += @sizeOf(usize);

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
    const name = try Wal.file_name(alloc, seq);
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
    const name = try Wal.file_name(alloc, seq);
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

fn expectReplayInvalidFormat(dir: Dir, seq: usize, data: []const u8, alloc: Allocator) !void {
    try writeWalFile(dir, seq, data, alloc);

    var wal = try Wal.open(dir, seq, testing_io, alloc);
    defer wal.file.close(testing_io);

    var target = try WalTable.new(dir, null, seq + 1000, null, testing_io, alloc);
    defer target.deinit(alloc);

    try std.testing.expectError(error.InvalidFormat, wal.replay_to(target, testing_io));
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

    var wal = try Wal.new(dir, 1, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = 7 } }, testing_io);

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

    var wal = try Wal.new(dir, 2, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Remove = .{ .key = "beta", .seq = 42 } }, testing_io);

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

    var wal = try Wal.new(dir, 3, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = 7 } }, testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = 8 } }, testing_io);

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

    try std.testing.expectEqual(RemoveMagic, data[pos]);
    pos += 1;
    const remove_size = readUsize(data[pos .. pos + @sizeOf(usize)]);
    try std.testing.expectEqual(@as(usize, 5), remove_size);
    pos += @sizeOf(usize);
    try std.testing.expectEqualSlices(u8, "alpha", data[pos .. pos + remove_size]);
    pos += remove_size;
    try std.testing.expectEqual(@as(usize, 8), readUsize(data[pos .. pos + @sizeOf(usize)]));
    pos += @sizeOf(usize);

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

    var wal = try Wal.new(dir, 4, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = 7 } }, testing_io);

    var target = try WalTable.new(dir, null, 5, null, testing_io, allocator);
    defer target.deinit(allocator);
    try wal.replay_to(target, testing_io);

    const value = try target.get("alpha", 7, allocator);
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

    var wal = try Wal.new(dir, 6, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = 8 } }, testing_io);

    var target = try WalTable.new(dir, null, 7, null, testing_io, allocator);
    defer target.deinit(allocator);
    try wal.replay_to(target, testing_io);

    const value = try target.get("alpha", 8, allocator);
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

    var wal = try Wal.new(dir, 8, null, testing_io, allocator);
    defer wal.file.close(testing_io);
    try wal.record(.{ .Add = .{ .key = "alpha", .value = "one", .seq = 7 } }, testing_io);
    try wal.record(.{ .Remove = .{ .key = "alpha", .seq = 8 } }, testing_io);

    var target = try WalTable.new(dir, null, 9, null, testing_io, allocator);
    defer target.deinit(allocator);
    try wal.replay_to(target, testing_io);

    const removed = try target.get("alpha", 8, allocator);
    try std.testing.expectEqual(@as(@TypeOf(removed), .Removed), removed);

    const old_value = try target.get("alpha", 7, allocator);
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
