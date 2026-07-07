const std = @import("std");
const KeyValueOwned = @import("memtable.zig").KeyValueOwned;
const KeyValue = @import("memtable.zig").KeyValue;
const KVSeq = @import("memtable.zig").KVSeq;
const Writer = std.Io.File.Writer;
const Allocator = std.mem.Allocator;

const AddMagic = 0x10;
const NextFileNumberMagic = 0x12;
const NextSeqNumberMagic = 0x13;
const AddWalMagic = 0x14;
const DeleteFileMagic = 0x15;

pub const FileSeq = packed struct(usize) {
    value: usize,

    pub fn init(v: usize) FileSeq {
        return .{ .value = v };
    }

    pub fn get(self: *const FileSeq) usize {
        return self.value;
    }
};

pub const KeyOwned = struct {
    data: []const u8,

    pub fn from_kv(kv: KeyValue, alloc: Allocator) !KeyOwned {
        const full_size = kv.as_key().len;
        const ptr = try alloc.alloc(u8, full_size);

        @memcpy(ptr, kv.as_key());
        return .{ .data = ptr };
    }

    pub fn from_raw(data: []const u8, alloc: Allocator) !KeyOwned {
        const full_size = data.len;
        const ptr = try alloc.alloc(u8, full_size);

        @memcpy(ptr, data);
        return .{ .data = ptr };
    }

    pub fn deinit(self: *KeyOwned, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

pub fn alloc_sstable_name(seq: FileSeq, alloc: Allocator) ![]const u8 {
    const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{seq.get()});
    return res;
}

pub const FileMeta = struct {
    max: KeyOwned,
    min: KeyOwned,
    lvl: u8,
    file_seq: FileSeq,
    value_seq: KVSeq,

    // min < self.max && self.min < max
    pub fn key_range_overlap(self: *const FileMeta, min: []const u8, max: []const u8) bool {
        const first = std.mem.order(u8, min, self.max.data);
        const second = std.mem.order(u8, self.min.data, max);

        return (first == .lt or first == .eq) and (second == .lt or second == .eq);
    }

    pub fn deinit(self: *FileMeta, alloc: Allocator) void {
        self.max.deinit(alloc);
        self.min.deinit(alloc);
    }

    pub fn less_than(ctx: void, lhs: FileMeta, rhs: FileMeta) bool {
        _ = ctx;

        if (lhs.lvl != rhs.lvl)
            return lhs.lvl < rhs.lvl;

        return lhs.file_seq.get() > rhs.file_seq.get();
    }

    pub fn serialize_size(self: *const FileMeta) usize {
        return ManifestRecord.string_size(self.max.data) +
            ManifestRecord.string_size(self.min.data) +
            @sizeOf(@TypeOf(self.lvl)) +
            @sizeOf(@TypeOf(self.file_seq)) +
            @sizeOf(@TypeOf(self.value_seq));
    }
};

// The current design of manifest:
//
// - AddWal(N)  -> there is WAL file for MemTable with file number N
// - AddFile(N) -> that SSTable was created, meaning that Wal(N) is no longer needed
//   (can be eventually deleted)
pub const ManifestRecord = union(enum) {
    AddFile: FileMeta,
    DeleteFile: FileSeq,
    NextFileNumber: FileSeq,
    NextSeqNumber: usize,
    AddWal: FileSeq,

    const Self = @This();

    fn string_size(str: []const u8) usize {
        return 8 + str.len;
    }

    fn full_size(self: *const ManifestRecord) usize {
        var full: usize = 0;

        switch (self.*) {
            .AddFile => |add| {
                full = add.serialize_size();
            },
            .AddWal => |a| {
                full = @sizeOf(@TypeOf(a));
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
                Self.put_int(usize, &data, add.file_seq.get());
                Self.put_int(usize, &data, add.value_seq.get());

                Self.put_slice(&data, add.max.data);
                Self.put_slice(&data, add.min.data);
            },
            .NextFileNumber => |next| {
                Self.put_int(u8, &data, NextFileNumberMagic);
                Self.put_int(usize, &data, next.get());
            },
            .NextSeqNumber => |next| {
                Self.put_int(u8, &data, NextSeqNumberMagic);
                Self.put_int(usize, &data, next);
            },
            .DeleteFile => |del| {
                Self.put_int(u8, &data, DeleteFileMagic);
                Self.put_int(usize, &data, del.get());
            },
            .AddWal => |wal| {
                Self.put_int(u8, &data, AddWalMagic);
                Self.put_int(usize, &data, wal.get());
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
                    const file_seq = FileSeq.init(Self.get_int(usize, &iter));
                    const value_seq = KVSeq.init(Self.get_int(usize, &iter));
                    const max = Self.get_slice(&iter);
                    const min = Self.get_slice(&iter);

                    try res.append(alloc, .{ .AddFile = .{
                        .lvl = lvl,
                        .min = try KeyOwned.from_raw(min, alloc),
                        .max = try KeyOwned.from_raw(max, alloc),
                        .file_seq = file_seq,
                        .value_seq = value_seq,
                    } });
                },
                NextFileNumberMagic => {
                    const filenum = FileSeq.init(Self.get_int(usize, &iter));
                    try res.append(alloc, .{ .NextFileNumber = filenum });
                },
                NextSeqNumberMagic => {
                    const filenum = Self.get_int(usize, &iter);
                    try res.append(alloc, .{ .NextSeqNumber = filenum });
                },
                AddWalMagic => {
                    const wal = FileSeq.init(Self.get_int(usize, &iter));
                    try res.append(alloc, .{ .AddWal = wal });
                },
                DeleteFileMagic => {
                    const deleted = FileSeq.init(Self.get_int(usize, &iter));
                    try res.append(alloc, .{ .DeleteFile = deleted });
                },
                else => return error.CorruptedData,
            }
        }

        return res;
    }
};
