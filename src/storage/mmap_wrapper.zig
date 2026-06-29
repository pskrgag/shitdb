const std = @import("std");

pub const MmapOptions = enum {
    ro,
    rw,

    fn to_prot(self: *const MmapOptions) std.posix.PROT {
        return switch (self.*) {
            .ro => .{ .READ = true },
            .rw => .{ .WRITE = true, .READ = true },
        };
    }
};

pub const Mmap = struct {
    data: []u8,

    pub fn init(file: anytype, opts: MmapOptions) !Mmap {
        const d = try std.posix.mmap(
            null,
            file.size,
            opts.to_prot(),
            .{ .TYPE = .SHARED },
            file.file.handle,
            0,
        );

        return .{ .data = d };
    }

    pub fn deinit(self: *Mmap) void {
        std.posix.munmap(@alignCast(self.data));
    }
};
