const std = @import("std");
const Allocator = std.mem.Allocator;
const FileMeta = @import("storage").manifest.FileMeta;

pub const MaxSupportedLvls: usize = 5;

/// Compaction options specified by the user
///
/// For now only leveling is supported.
pub const CompactionOptions = struct {
    // Maximum level of sstables
    max_lvl: usize = 2,
    // Maximum number of lvl0 sstables.
    max_lvl0: usize = 5,
    // Target size for one sstable.
    sstable_target_size: usize = 2 << 20,
    // LVL1 compaction threshold (10 Mb by default)
    lvl1_byte_threshold: usize = 10 << 20,
    // LVL > 1 compaction threshold multiplier
    fanout: usize = 10,

    pub fn sanitize(self: *const CompactionOptions) !void {
        if (self.max_lvl0 < 1)
            return error.InvalidMaxLvl;

        if (self.max_lvl0 < 1)
            return error.InvalidMaxLvl0;

        if (self.lvl1_byte_threshold < 1)
            return error.InvalidLvl1Threshold;

        if (self.sstable_target_size < 1)
            return error.InvalidSstableTargetSize;

        if (self.fanout < 2)
            return error.InvalidFanout;
    }
};

pub const CompactionPlan = struct {
    input_files: std.ArrayList(FoundFile),
    overlap_files: std.ArrayList(FoundFile),
    dst_lvl: u8,

    const FoundFile = struct {
        meta: FileMeta,
        idx: usize,
    };

    fn find_cadidates_lvl0(files: []FileMeta, alloc: Allocator, lvl: u8) !std.ArrayList(FoundFile) {
        var res = try std.ArrayList(FoundFile).initCapacity(alloc, 2);
        var found: usize = 0;

        for (files, 0..) |file, idx| {
            if (file.lvl == lvl) {
                try res.append(alloc, .{ .meta = file, .idx = idx });
                found += 1;

                if (found == 2)
                    break;
            }
        }

        std.debug.assert(found == 2);
        return res;
    }

    fn find_cadidates(files: []FileMeta, alloc: Allocator, lvl: u8) !std.ArrayList(FoundFile) {
        if (lvl == 0) {
            return CompactionPlan.find_cadidates_lvl0(files, alloc, lvl);
        } else {
            @panic("todo");
        }
    }

    fn should_compact_lvl0(files: []FileMeta, opts: CompactionOptions) bool {
        var count: usize = 0;

        for (files) |f| {
            if (f.lvl == 0) {
                count += 1;
            }
        }

        return count > opts.max_lvl0;
    }

    fn should_compact(files: []FileMeta, opts: CompactionOptions) ?u8 {
        if (CompactionPlan.should_compact_lvl0(files, opts)) {
            return 0;
        }

        return null;
    }

    pub fn new(files: []FileMeta, opts: CompactionOptions, alloc: Allocator) !?CompactionPlan {
        if (CompactionPlan.should_compact(files, opts)) |lvl| {
            var candidates = try CompactionPlan.find_cadidates(files, alloc, lvl);
            errdefer candidates.deinit(alloc);

            var next_lvl_files = try std.ArrayList(FoundFile).initCapacity(alloc, 0);
            errdefer next_lvl_files.deinit(alloc);

            for (files, 0..) |file, idx| {
                if (file.lvl == lvl + 1) {
                    var should_consider = false;

                    for (candidates.items) |candidate| {
                        should_consider |= file.key_range_overlap(
                            candidate.meta.min.data,
                            candidate.meta.max.data,
                        );
                        if (should_consider)
                            break;
                    }

                    if (should_consider)
                        try next_lvl_files.append(alloc, .{ .meta = file, .idx = idx });
                }
            }

            return .{
                .dst_lvl = lvl + 1,
                .input_files = candidates,
                .overlap_files = next_lvl_files,
            };
        } else {
            return null;
        }
    }

    pub fn deinit(self: *CompactionPlan, alloc: Allocator) void {
        self.overlap_files.deinit(alloc);
        self.input_files.deinit(alloc);
    }
};
