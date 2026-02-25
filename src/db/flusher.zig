const std = @import("std");
const MemTable = @import("storage").MemTable;
const DoublyLinkedList = std.DoublyLinkedList;

pub const Flusher = struct {
    list: DoublyLinkedList,

    pub fn new() Flusher {
        return .{ .list = DoublyLinkedList{ .first = null, .last = null } };
    }

    pub fn insert(self: *Flusher, table: *MemTable) void {
        self.list.append(&table.node);
    }

    pub fn get(self: *Flusher, key: []const u8) ?[]const u8 {
        var current = self.list.first;
        while (current) |node| {
            const table: *MemTable = @fieldParentPtr("node", node);
            const val = try table.get(key);

            switch (val) {
                .Found => |v| {
                    return v;
                },
                .Removed => return null,
                .NotFound => {},
            }

            current = node.next;
        }

        return null;
    }
};
