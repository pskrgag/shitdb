const std = @import("std");
const MemTable = @import("storage").MemTable;
const Wal = @import("wal.zig").Wal;
const WalEntry = @import("wal.zig").WalEntry;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").MemTableOpts;
const GetResult = @import("storage").GetResult;
const KeyValue = @import("storage").KeyValue;
const KVSeq = @import("storage").KVSeq;
const FileSeq = @import("storage").manifest.FileSeq;
const fi = @import("fault_injection");
const Version = @import("version.zig").Version;
const VersionEdit = @import("version.zig").VersionEdit;

/// Memtable + WAL
pub const WalTable = struct {
    table: MemTable,
    wal: Wal,
    seq: FileSeq,
    io: std.Io,

    /// Constructs new WAL+MemTable
    pub fn new(
        dir: std.Io.Dir,
        user_opts: ?MemTableOpts,
        seq: FileSeq,
        version: ?*Version,
        io: std.Io,
        alloc: Allocator,
    ) !*WalTable {
        const self = try alloc.create(WalTable);

        self.table = try MemTable.new(alloc, io, user_opts);
        self.wal = try Wal.new(dir, seq, version, io, alloc);
        self.seq = seq;
        self.io = io;

        return self;
    }

    /// Opens existing WAL
    pub fn open(
        dir: std.Io.Dir,
        user_opts: MemTableOpts,
        seq: FileSeq,
        io: std.Io,
        alloc: Allocator,
    ) !*WalTable {
        const self = try alloc.create(WalTable);

        self.table = try MemTable.new(alloc, io, user_opts);
        self.wal = try Wal.open(dir, seq, io, alloc);

        self.seq = seq;
        self.io = io;

        try self.wal.replay_to(self, io);
        return self;
    }

    pub fn put_but_record(self: *WalTable, key: []const u8, value: []const u8, seq: KVSeq) !void {
        try self.table.put(key, value, seq);
    }

    pub fn remove_but_record(self: *WalTable, key: []const u8, seq: KVSeq) !void {
        try self.table.remove(key, seq);
    }

    /// Puts value from the memtable and records it into WAL
    pub fn put(self: *WalTable, key: []const u8, value: []const u8, seq: KVSeq) !void {
        const entry: WalEntry = .{ .Add = .{ .key = key, .value = value, .seq = seq } };

        try self.wal.record(entry, self.io);
        try self.table.put(key, value, seq);
        fi.crash("after_wal");
    }

    /// Removes value from the memtable and records it into WAL
    pub fn remove(self: *WalTable, key: []const u8, seq: KVSeq) !void {
        const entry: WalEntry = .{ .Remove = .{ .key = key, .seq = seq } };

        try self.wal.record(entry, self.io);
        try self.table.remove(key, seq);
        fi.crash("after_wal");
    }

    /// Retrieves value from the memtable
    pub fn get(self: *WalTable, key: []const u8, seq: KVSeq, alloc: Allocator) !GetResult {
        return try self.table.get(key, seq, alloc);
    }

    /// Returns maximum key
    pub fn max(self: *WalTable) ?KeyValue {
        return self.table.max();
    }

    /// Returns minimal key
    pub fn min(self: *WalTable) ?KeyValue {
        return self.table.min();
    }

    /// Returns minimal key
    pub fn max_seq(self: *WalTable) KVSeq {
        return self.table.max_seq;
    }

    /// Deinits table
    pub fn deinit(self: *WalTable, alloc: Allocator) void {
        self.wal.deinit(self.io);
        self.table.deinit(alloc);
        alloc.destroy(self);
    }
};
