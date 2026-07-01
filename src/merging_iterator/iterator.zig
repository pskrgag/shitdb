const std = @import("std");
const compare_keys = @import("generic_utils").compare_keys;

pub fn IteratorWrapper(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        next_fn: *const fn (ptr: *anyopaque) ?T,
        peek_fn: *const fn (ptr: *anyopaque) ?T,

        pub fn init(ptr: anytype) IteratorWrapper(T) {
            const Ptr = @TypeOf(ptr);
            const gen = struct {
                fn next(p: *anyopaque) ?T {
                    const self: Ptr = @ptrCast(@alignCast(p));
                    return self.next();
                }

                fn peek(p: *anyopaque) ?T {
                    const self: Ptr = @ptrCast(@alignCast(p));
                    return self.peek();
                }
            };
            return .{
                .ptr = @ptrCast(ptr),
                .next_fn = gen.next,
                .peek_fn = gen.peek,
            };
        }

        fn next(self: *IteratorWrapper(T)) ?T {
            return self.next_fn(self.ptr);
        }

        fn peek(self: *IteratorWrapper(T)) ?T {
            return self.peek_fn(self.ptr);
        }
    };
}

pub fn MergeIterator(comptime T: type) type {
    return struct {
        iterators: []IteratorWrapper(T),

        const Self = @This();

        pub fn new(iters: []IteratorWrapper(T)) Self {
            return .{ .iterators = iters };
        }

        fn next_iter(self: *Self) ?*IteratorWrapper(T) {
            var val: ?T = null;
            var iter: ?*IteratorWrapper(T) = null;

            for (self.iterators) |*i| {
                if (i.peek()) |candidate| {
                    if (val) |v| {
                        if (compare_keys(T, T, candidate, v) == .lt) {
                            val = candidate;
                            iter = i;
                        }
                    } else {
                        val = candidate;
                        iter = i;
                    }
                }
            }

            if (val != null) {
                std.debug.assert(iter != null);
                return iter.?;
            } else {
                return null;
            }
        }

        pub fn next(self: *Self) ?T {
            if (self.next_iter()) |i| {
                return i.next();
            } else {
                return null;
            }
        }

        pub fn peek(self: *Self) ?T {
            if (self.next_iter()) |i| {
                return i.peek();
            } else {
                return null;
            }
        }
    };
}

const SliceIter = struct {
    slice: []const u8,

    fn next(self: *SliceIter) ?u8 {
        if (self.slice.len > 0) {
            const res = self.slice[0];

            self.slice = self.slice[1..];
            return res;
        } else {
            return null;
        }
    }

    fn peek(self: *SliceIter) ?u8 {
        if (self.slice.len > 0) {
            const res = self.slice[0];
            return res;
        } else {
            return null;
        }
    }
};

test "Basic" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const arr1 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const arr2 = [_]u8{ 9, 10, 11, 12, 13, 14, 15 };

    {
        var arr1_iter = SliceIter{ .slice = arr1[0..] };
        var arr2_iter = SliceIter{ .slice = arr2[0..] };

        var array = try std.ArrayList(IteratorWrapper(u8)).initCapacity(allocator, 0);
        defer array.deinit(allocator);

        try array.append(allocator, IteratorWrapper(u8).init(&arr1_iter));
        try array.append(allocator, IteratorWrapper(u8).init(&arr2_iter));

        var iter = MergeIterator(u8).new(array.items);

        for (1..16) |i| {
            try std.testing.expectEqual(i, iter.next().?);
        }
    }

    {
        var arr1_iter = SliceIter{ .slice = arr1[0..] };
        var arr2_iter = SliceIter{ .slice = arr2[0..] };

        var array = try std.ArrayList(IteratorWrapper(u8)).initCapacity(allocator, 0);
        defer array.deinit(allocator);
        try array.append(allocator, IteratorWrapper(u8).init(&arr2_iter));
        try array.append(allocator, IteratorWrapper(u8).init(&arr1_iter));

        var iter = MergeIterator(u8).new(array.items);

        for (1..16) |i| {
            try std.testing.expectEqual(i, iter.next().?);
        }
    }
}

test "Zig-zag" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const arr1 = [_]u8{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const arr2 = [_]u8{ 2, 4, 6, 8, 10, 12, 14, 16 };

    {
        var arr1_iter = SliceIter{ .slice = arr1[0..] };
        var arr2_iter = SliceIter{ .slice = arr2[0..] };

        var array = try std.ArrayList(IteratorWrapper(u8)).initCapacity(allocator, 0);
        defer array.deinit(allocator);

        try array.append(allocator, IteratorWrapper(u8).init(&arr1_iter));
        try array.append(allocator, IteratorWrapper(u8).init(&arr2_iter));

        var iter = MergeIterator(u8).new(array.items);

        for (1..16) |i| {
            try std.testing.expectEqual(i, iter.next().?);
        }
    }
}
