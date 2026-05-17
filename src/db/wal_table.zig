const std = @import("std");
const MemTable = @import("storage").MemTable;
const Wal = @import("wal.zig").Wal;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").MemTableOpts;
const GetResult = @import("storage").GetResult;
const KeyValue = @import("storage").KeyValue;

/// Memtable + WAL
pub const WalTable = struct {
    table: MemTable,
    wal: Wal,
    seq: usize,

    /// Constructs new WAL+MemTable
    pub fn new(dir: std.Io.Dir, user_opts: ?MemTableOpts, seq: usize, alloc: Allocator) !*WalTable {
        const self = try alloc.create(WalTable);

        self.table = try MemTable.new(alloc, user_opts);
        self.wal = try Wal.new(dir, seq, alloc);
        self.seq = seq;

        return self;
    }

    /// Puts value from the memtable and records it into WAL
    pub fn put(self: *WalTable, key: []const u8, value: []const u8, seq: usize) !void {
        try self.table.put(key, value, seq);
    }

    /// Removes value from the memtable and records it into WAL
    pub fn remove(self: *WalTable, key: []const u8, seq: usize) !void {
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
