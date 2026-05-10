const std = @import("std");
const utils = @import("utils.zig");
const KeyValueOwned = @import("memtable.zig").KeyValueOwned;
const KeyValue = @import("memtable.zig").KeyValue;
const Writer = std.fs.File.Writer;
const Allocator = std.mem.Allocator;
const data_as_u8_const_ptr = utils.data_as_u8_const_ptr;

const AddMagic = 0x10;
const NextFileNumberMagic = 0x12;
const NextSeqNumberMagic = 0x13;

pub const FileMeta = struct {
    name: []const u8,
    max: KeyValueOwned,
    min: KeyValueOwned,
    lvl: u8,
    seq: usize,

    pub fn less_than(ctx: void, lhs: FileMeta, rhs: FileMeta) bool {
        _ = ctx;

        if (lhs.lvl != rhs.lvl)
            return lhs.lvl < rhs.lvl;

        return lhs.seq > rhs.seq;
    }
};

pub const ManifestRecord = union(enum) {
    AddFile: FileMeta,
    DeleteFile: struct {
        seq: usize,
        lvl: u8,
    },
    NextFileNumber: usize,
    NextSeqNumber: usize,

    const Self = @This();

    fn string_size(str: []const u8) usize {
        return 8 + str.len;
    }

    fn full_size(self: *const ManifestRecord) usize {
        var full: usize = 0;

        switch (self.*) {
            .AddFile => |add| {
                full = ManifestRecord.string_size(add.name) + @sizeOf(u8) + @sizeOf(usize) + ManifestRecord.string_size(add.max.data) + ManifestRecord.string_size(add.min.data);
            },
            .DeleteFile => |a| {
                full = @sizeOf(@TypeOf(a));
            },
            .NextFileNumber => |num| {
                full = @sizeOf(@TypeOf(num));
            },
            .NextSeqNumber => |num| {
                full = @sizeOf(@TypeOf(num));
            },
        }

        return full + 1;
    }

    fn put_bytes(buf: *[]u8, bytes: []const u8) void {
        @memcpy(buf.*[0..bytes.len], bytes);
        buf.* = buf.*[bytes.len..];
    }

    fn put_slice(buf: *[]u8, bytes: []const u8) void {
        Self.put_int(usize, buf, bytes.len);
        Self.put_bytes(buf, bytes);
    }

    fn put_int(
        comptime T: type,
        buf: *[]u8,
        value: T,
    ) void {
        const n = @sizeOf(T);
        const dst: *[n]u8 = buf.*[0..][0..n];

        std.mem.writeInt(T, dst, value, .little);
        buf.* = buf.*[n..];
    }

    fn get_bytes(buf: *[]const u8, len: usize) []const u8 {
        std.debug.assert(len <= buf.*.len);

        const res = buf.*[0..len];
        buf.* = buf.*[len..];
        return res;
    }

    fn get_slice(buf: *[]const u8) []const u8 {
        const size = Self.get_int(usize, buf);
        return Self.get_bytes(buf, size);
    }

    fn get_int(
        comptime T: type,
        buf: *[]const u8,
    ) T {
        const n = @sizeOf(T);
        std.debug.assert(n <= buf.*.len);

        const src: *const [n]u8 = buf.*[0..][0..n];
        const res = std.mem.readInt(T, src, .little);

        buf.* = buf.*[n..];
        return res;
    }

    pub fn serialize_to(self: *const ManifestRecord, dst: *std.ArrayList(u8), alloc: Allocator) !void {
        const size = self.full_size();
        try dst.resize(alloc, dst.items.len + size);

        var data = dst.items[dst.items.len - size ..];

        switch (self.*) {
            .AddFile => |add| {
                Self.put_int(u8, &data, AddMagic);
                Self.put_int(u8, &data, add.lvl);
                Self.put_int(usize, &data, add.seq);

                Self.put_slice(&data, add.name);
                Self.put_slice(&data, add.max.data);
                Self.put_slice(&data, add.min.data);
            },
            .NextFileNumber => |next| {
                Self.put_int(u8, &data, NextFileNumberMagic);
                Self.put_int(usize, &data, next);
            },
            .NextSeqNumber => |next| {
                Self.put_int(u8, &data, NextSeqNumberMagic);
                Self.put_int(usize, &data, next);
            },
            .DeleteFile => |add| {
                _ = add;
            },
        }
    }

    pub fn deserialize_from(data: []const u8, alloc: Allocator) !std.ArrayList(Self) {
        var res = try std.ArrayList(Self).initCapacity(alloc, 0);
        var iter = data;

        while (iter.len > 0) {
            const magic = Self.get_int(u8, &iter);

            switch (magic) {
                AddMagic => {
                    const lvl = Self.get_int(u8, &iter);
                    const seq = Self.get_int(usize, &iter);
                    const name = Self.get_slice(&iter);
                    const max = Self.get_slice(&iter);
                    const min = Self.get_slice(&iter);

                    try res.append(alloc, .{ .AddFile = .{
                        .lvl = lvl,
                        .name = try alloc.dupe(u8, name),
                        .min = try KeyValueOwned.from_kv(&KeyValue{ .data = min.ptr }, alloc),
                        .max = try KeyValueOwned.from_kv(&KeyValue{ .data = max.ptr }, alloc),
                        .seq = seq,
                    } });
                },
                NextFileNumberMagic => {
                    const filenum = Self.get_int(usize, &iter);
                    try res.append(alloc, .{ .NextFileNumber = filenum });
                },
                NextSeqNumberMagic => {
                    const filenum = Self.get_int(usize, &iter);
                    try res.append(alloc, .{ .NextSeqNumber = filenum });
                },
                else => return error.CorruptedData,
            }
        }

        return res;
    }
};
