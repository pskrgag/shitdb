const std = @import("std");
const utils = @import("utils.zig");
const Writer = std.fs.File.Writer;
const Allocator = std.mem.Allocator;
const data_as_u8_const_ptr = utils.data_as_u8_const_ptr;

const AddMagic = 0x10;
const NextFileNumberMagic = 0x12;

pub const ManifestRecord = union(enum) {
    Add: struct { lvl: u8, name: []const u8, smallest: []const u8, largest: []const u8 },
    Delete: struct {
        name: []const u8,
        lvl: u8,
    },
    NextFileNumber: usize,

    const Self = @This();

    fn string_size(str: []const u8) usize {
        return 8 + str.len;
    }

    fn full_size(self: *const ManifestRecord) usize {
        var full: usize = 0;

        switch (self) {
            .Add => |add| {
                full = ManifestRecord.string_size(add.name) + 1 + ManifestRecord.string_size(add.smallest) + ManifestRecord.string_size(add.largest);
            },
            .Delete => |del| {
                full = ManifestRecord.string_size(del.name) + 1;
            },
            .NextFileNumber => |num| {
                full = @sizeOf(num);
            },
        }

        return full + 1;
    }

    fn putBytes(buf: []u8, pos: *usize, bytes: []const u8) void {
        std.debug.assert(bytes.len <= buf.len - pos.*);

        @memcpy(buf[pos.* .. pos.* + bytes.len], bytes);
        pos.* += bytes.len;
    }

    fn putInt(
        comptime T: type,
        buf: []u8,
        pos: *usize,
        value: T,
    ) void {
        const n = @sizeOf(T);

        const dst: *[n]u8 = buf[pos.* .. pos.* + n];
        std.mem.writeInt(T, dst, value, .little);
        pos.* += n;
    }

    fn serialize(self: *ManifestRecord, alloc: Allocator) ![]const u8 {
        const size = self.full_size();
        const data = try alloc.alloc(u8, size);
        const pos = 0;

        switch (self) {
            .Add => |add| {
                Self.putInt(u8, data, &pos, AddMagic);
                Self.putInt(u8, data, &pos, add.lvl);

                Self.putInt(usize, data, &pos, add.name.len);
                Self.putBytes(data, &pos, add.name.ptr);

                Self.putInt(usize, data, &pos, add.smallest.len);
                Self.putBytes(data, &pos, add.smallest.ptr);

                Self.putInt(usize, data, &pos, add.largest.len);
                Self.putBytes(data, &pos, add.largest.ptr);

                return data;
            },
            .NextFileNumber => |next| {
                Self.putInt(u8, data, &pos, NextFileNumberMagic);
                Self.putInt(u8, data, &pos, next);
            },
            .Delete => |add| {
                _ = add;
            },
        }
    }
};
