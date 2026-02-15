const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("storage").MemTable;

const KeyValue = struct {
    // Active MemTable
    active: *MemTable,
    // Root folder
    path: []const u8,

    const Self = @This();

    pub fn new(path: []const u8, alloc: Allocator) !Self {
        return .{ .active = try MemTable.new(alloc, null), .path = path };
    }
};

test {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const new = try KeyValue.new("test", allocator);
    _ = new;
}
