const std = @import("std");
const MemTable = @import("storage").MemTable;
const Wal = @import("wal.zig").Wal;
const WalEntry = @import("wal.zig").WalEntry;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").MemTableOpts;
const GetResult = @import("storage").GetResult;
const KeyValue = @import("storage").KeyValue;

/// Memtable + WAL
pub const WalTable = struct {
    table: MemTable,
    wal: Wal,
    seq: usize,
    io: std.Io,

    /// Constructs new WAL+MemTable
    pub fn new(
        dir: std.Io.Dir,
        user_opts: ?MemTableOpts,
        seq: usize,
        io: std.Io,
        alloc: Allocator,
    ) !*WalTable {
        const self = try alloc.create(WalTable);

        self.table = try MemTable.new(alloc, user_opts);
        self.wal = try Wal.new(dir, seq, io, alloc);
        self.seq = seq;
        self.io = io;

        return self;
    }

    /// Puts value from the memtable and records it into WAL
    pub fn put(self: *WalTable, key: []const u8, value: []const u8, seq: usize) !void {
        const entry: WalEntry = .{ .Add = .{ .key = key, .value = value, .seq = seq } };

        try self.wal.record(entry, self.io);
        try self.table.put(key, value, seq);
    }

    /// Removes value from the memtable and records it into WAL
    pub fn remove(self: *WalTable, key: []const u8, seq: usize) !void {
        const entry: WalEntry = .{ .Remove = .{ .key = key, .seq = seq } };

        try self.wal.record(entry, self.io);
        try self.table.remove(key, seq);
    }

    /// Retrieves value from the memtable
    pub fn get(self: *WalTable, key: []const u8, seq: usize, alloc: Allocator) !GetResult {
        return try self.table.get(key, seq, alloc);
    }

    /// Returns maximum key
    pub fn max(self: *WalTable) ?*const KeyValue {
        return self.table.max();
    }

    /// Returns minimal key
    pub fn min(self: *WalTable) ?*const KeyValue {
        return self.table.min();
    }

    /// Deinits table
    pub fn deinit(self: *WalTable, alloc: Allocator) void {
        self.table.deinit(alloc);
        alloc.destroy(self);
    }
};
