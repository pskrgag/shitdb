const std = @import("std");
const MemTable = @import("storage").memtable.MemTable;
const Wal = @import("wal.zig").Wal;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").memtable.MemTableOpts;
const WalOpts = @import("wal.zig").WalOpts;
const GetResult = @import("storage").memtable.GetResult;
const KeyValue = @import("storage").memtable.KeyValue;
const KVSeq = @import("storage").memtable.KVSeq;
const FileSeq = @import("storage").manifest.FileSeq;
const Version = @import("version.zig").Version;
const Value = std.atomic.Value;
const SleepingCounter = @import("sleeping_count.zig").SleepingCounter;
const Transaction = @import("manager.zig").Transaction;
const test_utils = @import("test_utils");
const SmallVec = @import("adt").SmallVec;
const PendingWrite = @import("manager.zig").PendingWrite;
const Slot = @import("storage").memtable.Slot;
const Storage = @import("storage").storage.Storage;

const SlotArray = SmallVec(Slot, 30);

pub const State = enum(u8) {
    active,
    immutable,
};

pub const WalTableCommitResult = struct {
    // Need memtable rotation
    need_rotate: bool,
    // WAL commit failed. Need direct flush
    wal_failed: bool = false,
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
        storage: *Storage,
        memtable_opts: MemTableOpts,
        wal_opts: WalOpts,
        seq: FileSeq,
        version: ?*Version,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        return .{
            .table = try MemTable.new(alloc, io, memtable_opts),
            .wal = try Wal.new(storage, seq, version, wal_opts, io, alloc),
            .seq = seq,
            .io = io,
            .state = Value(State).init(.active),
            .in_progress = SleepingCounter.init(),
            .count = Value(usize).init(0),
        };
    }

    /// Opens existing WAL
    pub fn open(
        storage: *Storage,
        memtable_opts: MemTableOpts,
        wal_opts: WalOpts,
        seq: FileSeq,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        var self = WalTable{
            .table = try MemTable.new(alloc, io, memtable_opts),
            .wal = try Wal.open_with_opts(storage, seq, wal_opts, io, alloc),
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
        keyvalue: anyerror!Slot,
        trans: *Transaction,
        req: *PendingWrite,
        kvarray: *SlotArray,
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
    pub fn commit(self: *WalTable, trans: *Transaction, alloc: Allocator) WalTableCommitResult {
        var full = true;
        var iter = trans.iter();
        var slots = SlotArray.init();
        var commited = Transaction{};
        defer slots.deinit(alloc);

        // Pre-allocate as much as possible in the memtable allocator. If it's not possible
        // to allocate, these pending writes will be left for future.
        while (iter.next()) |i| {
            switch (i.op) {
                .Put => |p| {
                    const kv = self.table.allocate_put_slot(p.key, p.value, p.seq);
                    const res = WalTable.append_kv(kv, trans, i, &slots, &full, alloc);

                    switch (res) {
                        .Continue => continue,
                        .Break => break,
                        .None => {},
                    }
                },
                .Remove => |p| {
                    const kv = self.table.allocate_remove_slot(p.key, p.seq);
                    const res = WalTable.append_kv(kv, trans, i, &slots, &full, alloc);

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

        // At this point we have entries that fit into memtable. Try to commit them to WAL.
        self.wal.commit(commited, self.io) catch {
            // If WAL commit failed, we can try to commit into MemTable and then flush it. This we
            // can overcome WAL failures.
            for (slots.items()) |slot| {
                self.table.commit_slot(slot) catch @panic("must not panic here");
            }

            return .{ .need_rotate = !full, .wal_failed = true };
        };

        test_utils.Injections.fault_injection.crash(.after_wal);

        // And then commit to active table. It must not fail, since memory was reserved.
        for (slots.items()) |slot| {
            self.table.commit_slot(slot) catch @panic("must not panic here");
        }

        return .{
            .need_rotate = !full,
        };
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
        try self.wal.deinit(alloc, self.io);
        self.table.deinit(alloc);
    }
};
