const std = @import("std");

// Wrapper that erases the concrete type

pub fn IteratorWrapper(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) ?T,
        key_: ?T,

        fn init(ptr: anytype) IteratorWrapper {
            const Ptr = @TypeOf(ptr);
            const gen = struct {
                fn next(p: *anyopaque) ?T {
                    const self: Ptr = @ptrCast(@alignCast(p));
                    return self.next();
                }
            };
            return .{
                .ptr = ptr,
                .nextFn = gen.next,
                .key_ = null,
            };
        }

        fn key(self: *const IteratorWrapper) ?T {
            return self.key_;
        }

        fn next(self: *IteratorWrapper) ?T {
            self.key_ = self.nextFn(self.ptr);
            return self.key_;
        }
    };
}

fn MergeIterator(comptime T: type) type {
    return struct {
        iterators: std.ArrayList(*anyopaque),

        const Self = @This();

        pub fn new(iters: std.ArrayList(IteratorWrapper)) Self {
            return .{ .iterators = iters };
        }

        pub fn next(self: *Self) ?T {
            var val: ?T = null;

            for (self.iterators) |i| {

            }
        }
    };
}
