const std = @import("std");
const MemTable = @import("storage").MemTable;
const Wal = @import("wal.zig").Wal;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").MemTableOpts;
const GetResult = @import("storage").GetResult;
const KeyValue = @import("storage").KeyValue;
const KVSeq = @import("storage").KVSeq;
const FileSeq = @import("storage").manifest.FileSeq;
const Version = @import("version.zig").Version;
const Value = std.atomic.Value;
const SleepingCounter = @import("sleeping_count.zig").SleepingCounter;
const Transaction = @import("manager.zig").Transaction;
const test_utils = @import("test_utils");
const SmallVec = @import("adt").SmallVec;
const PendingWrite = @import("manager.zig").PendingWrite;

const KvArray = SmallVec(KeyValue, 30);

pub const State = enum(u8) {
    active,
    immutable,
};

/// Memtable + WAL
pub const WalTable = struct {
    table: MemTable,
    wal: Wal,
    seq: FileSeq,
    io: std.Io,
    state: Value(State),
    count: Value(usize),
    in_progress: SleepingCounter,

    /// Constructs new WAL+MemTable
    pub fn new(
        dir: std.Io.Dir,
        user_opts: ?MemTableOpts,
        seq: FileSeq,
        version: ?*Version,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        const opts = user_opts orelse MemTableOpts.default();

        return .{
            .table = try MemTable.new(alloc, io, opts),
            .wal = try Wal.new(dir, seq, version, io, alloc),
            .seq = seq,
            .io = io,
            .state = Value(State).init(.active),
            .in_progress = SleepingCounter.init(),
            .count = Value(usize).init(0),
        };
    }

    /// Opens existing WAL
    pub fn open(
        dir: std.Io.Dir,
        user_opts: MemTableOpts,
        seq: FileSeq,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        var self = WalTable{
            .table = try MemTable.new(alloc, io, user_opts),
            .wal = try Wal.open(dir, seq, io, alloc),
            .seq = seq,
            .io = io,
            .state = Value(State).init(.active),
            .in_progress = SleepingCounter.init(),
            .count = Value(usize).init(0),
        };

        try self.wal.replay_to(&self, io);
        return self;
    }

    fn get_state(self: *WalTable) State {
        const s = self.state.load(.monotonic);

        // Sanity check that enum is sane (table was not freed or smth. See memset in deinit)
        std.debug.assert(std.enums.fromInt(State, @intFromEnum(s)) != null);
        return s;
    }

    fn assert_active(self: *WalTable) void {
        std.debug.assert(self.get_state() == .active);
    }

    pub fn make_immune(self: *WalTable) void {
        const prev = self.state.swap(.immutable, .release);

        // After that all attempts to write must fail.
        std.debug.assert(prev == .active);
    }

    /// Special wrapper for WAL replay
    pub fn put_but_record(self: *WalTable, key: []const u8, value: []const u8, seq: KVSeq) !void {
        _ = self.count.fetchAdd(1, .monotonic);
        self.assert_active();
        try self.table.put(key, value, seq);
    }

    /// Special wrapper for WAL replay
    pub fn remove_but_record(self: *WalTable, key: []const u8, seq: KVSeq) !void {
        _ = self.count.fetchAdd(1, .monotonic);
        self.assert_active();
        try self.table.remove(key, seq);
    }

    pub fn wait_no_users(self: *WalTable) void {
        self.in_progress.wait_zero();
    }

    const Action = enum {
        None,
        Continue,
        Break,
    };

    // This function must not return an error!
    fn append_kv(
        keyvalue: anyerror!KeyValue,
        trans: *Transaction,
        req: *PendingWrite,
        kvarray: *KvArray,
        full: *bool,
        alloc: Allocator,
    ) Action {
        const kv = keyvalue catch |e| {
            if (e == error.MemTableFull) {
                full.* = false;
                return .Break;
            }

            trans.abort(req, e);
            return .Continue;
        };

        kvarray.append(alloc, kv) catch |e| {
            // Stop pushing to the array and break out of the loop.
            trans.abort(req, e);
            full.* = false;
            return .Break;
        };

        return .None;
    }

    /// Tries to commit transaction. May commit only part of it
    pub fn commit(self: *WalTable, trans: *Transaction, alloc: Allocator) !bool {
        var full = true;
        var iter = trans.iter();
        var kvs = KvArray.init();
        var commited = Transaction{};
        defer kvs.deinit(alloc);

        // Pre-allocate as much as possible in the memtable allocator. If it's not possible
        // to allocate, these pending writes will be left for future.
        while (iter.next()) |i| {
            switch (i.op) {
                .Put => |p| {
                    const kv = self.table.create_add_kv(p.key, p.value, p.seq);
                    const res = WalTable.append_kv(kv, trans, i, &kvs, &full, alloc);

                    switch (res) {
                        .Continue => continue,
                        .Break => break,
                        .None => {},
                    }
                },
                .Remove => |p| {
                    const kv = self.table.create_remove_kv(p.key, p.seq);
                    const res = WalTable.append_kv(kv, trans, i, &kvs, &full, alloc);

                    switch (res) {
                        .Continue => continue,
                        .Break => break,
                        .None => {},
                    }
                },
            }

            trans.ops.remove(&i.active_node);
            commited.push_active(i);
        }

        errdefer |e| {
            // If appending to WAL failed we have to mark the whole transaction as failed.
            commited.mark_error(e);
        }

        // At this point we have entries that fit into memtable. Try to commit them to WAL.
        try self.wal.commit(commited, self.io, alloc);

        test_utils.Injections.fault_injection.crash(.after_wal);

        // And then commit to active table. It must not fail, since memory was reserved.
        for (kvs.items()) |kv| {
            self.table.put_kv(kv) catch @panic("must not panic here");
        }

        return full;
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
        return self.table.max_seq.load(.monotonic);
    }

    /// Number of entries
    pub fn len(self: *WalTable) usize {
        return self.count.load(.monotonic);
    }

    /// Deinits table
    pub fn deinit(self: *WalTable, alloc: Allocator) !void {
        try self.wal.deinit(self.io);
        self.table.deinit(alloc);
    }
};
