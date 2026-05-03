const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const generic_utils = b.addModule("generic_utils", .{
        .root_source_file = b.path("src/generic_utils.zig"),
        .target = target,
    });
    const merging_iterator = b.addModule("merging_iterator ", .{
        .root_source_file = b.path("src/merging_iterator/iterator.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "generic_utils", .module = generic_utils },
        },
    });

    const skiplist = b.addModule("skiplist", .{
        .root_source_file = b.path("src/skiplist/skiplist.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "generic_utils", .module = generic_utils },
        },
    });

    const test_utils = b.addModule("test_utils", .{
        .root_source_file = b.path("src/test_utils.zig"),
        .target = target,
    });

    const storage = b.addModule("storage", .{
        .root_source_file = b.path("src/storage/memtable.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "skiplist", .module = skiplist },
            .{ .name = "test_utils", .module = test_utils },
            .{ .name = "merging_iterator", .module = merging_iterator },
        },
    });

    const db = b.addModule("db", .{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "storage", .module = storage },
            .{ .name = "test_utils", .module = test_utils },
        },
    });

    const skiplist_tests = b.addTest(.{
        .root_module = skiplist,
    });
    const run_skiplist_tests = b.addRunArtifact(skiplist_tests);

    const memtable_tests = b.addTest(.{
        .root_module = storage,
    });
    const run_memtable_tests = b.addRunArtifact(memtable_tests);

    const db_tests = b.addTest(.{
        .root_module = db,
    });
    const run_db_tests = b.addRunArtifact(db_tests);
    const iter_tests = b.addTest(.{
        .root_module = merging_iterator,
    });
    const run_iter_tests = b.addRunArtifact(iter_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_skiplist_tests.step);
    test_step.dependOn(&run_memtable_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_iter_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
