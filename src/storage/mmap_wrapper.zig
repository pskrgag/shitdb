const std = @import("std");
const SSTableFile = @import("ssfile.zig").SSTableFile;

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

pub const GrowableMmap = struct {
    data: []u8,
    file: *SSTableFile,
    offset: usize,

    pub fn init(file: *SSTableFile, start_size: usize, opts: MmapOptions, io: std.Io) !GrowableMmap {
        try file.set_length(io, start_size);

        std.debug.assert(file.size == start_size);

        const d = try std.posix.mmap(
            null,
            start_size,
            opts.to_prot(),
            .{ .TYPE = .SHARED },
            file.file.handle,
            0,
        );

        return .{ .data = d, .file = file, .offset = 0 };
    }

    pub fn push(self: *GrowableMmap, new_data: []const u8, io: std.Io) !void {
        const new_offset = self.offset + new_data.len;
        var offset: ?usize = null;

        // HACK: new_data may point inside self.data array as an optimization. In case of push
        // this data could be moved via mremap, which will likely end up with PF.

        if (@intFromPtr(self.data.ptr) <= @intFromPtr(new_data.ptr) and
            @intFromPtr(self.data.ptr) + self.data.len >= @intFromPtr(new_data.ptr) + new_data.len)
        {
            offset = @intFromPtr(new_data.ptr) - @intFromPtr(self.data.ptr);
        }

        if (new_offset > self.data.len) {
            const old_size = self.file.size;
            const diff = new_offset - self.data.len;
            const new_size = old_size + diff * 3;

            std.debug.assert(new_size > old_size);
            try self.file.set_length(io, new_size);

            // Resize the mmap
            self.data = try std.posix.mremap(
                @alignCast(self.data.ptr),
                old_size,
                new_size,
                .{ .MAYMOVE = true },
                null,
            );
        }

        std.debug.assert(self.offset + new_data.len <= self.data.len);

        if (offset) |off| {
            @memcpy(self.data[self.offset .. self.offset + new_data.len], self.data[off .. off + new_data.len]);
        } else {
            @memcpy(self.data[self.offset .. self.offset + new_data.len], new_data);
        }

        self.offset += new_data.len;
    }

    pub fn current_offset(self: *const GrowableMmap) usize {
        return self.offset;
    }

    pub fn offset_ptr(self: *const GrowableMmap, offset: usize) [*]u8 {
        std.debug.assert(offset < self.data.len);
        return self.data.ptr + offset;
    }

    pub fn into_mmap(self: GrowableMmap) Mmap {
        return .{ .data = self.data };
    }

    pub fn deinit(self: *GrowableMmap) void {
        std.posix.munmap(@alignCast(self.data));
    }

    pub fn finalize(self: *GrowableMmap, io: std.Io) !void {
        // Sync data
        try std.posix.msync(@alignCast(self.data), std.posix.MSF.SYNC);
        // Set real size of the file
        try self.file.set_length(io, self.offset);
        // Sync file metadata as well
        try self.file.sync(io);
    }
};
