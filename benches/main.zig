const std = @import("std");
const zbench = @import("zbench");
const skiplist = @import("skiplist.zig");
const db = @import("db.zig");
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Terminal = std.Io.Terminal;

const DefaultDir = ".bench";
const ResultFile = "bench_result.json";

const Config = struct {
    save_result: bool,
    dir: []const u8,

    fn default() Config {
        return .{ .save_result = false, .dir = DefaultDir };
    }
};

const Percentiles = struct {
    p75: u64,
    p99: u64,
    p995: u64,
};

const TimeStat = struct {
    units: []const u8,
    total: u64,
    mean: u64,
    stddev: u64,
    min: u64,
    max: u64,
    percentiles: Percentiles,
};

const Result = struct {
    name: []const u8,
    timing_statistics: TimeStat,
    timings: []const u64,
};

const Results = []const Result;

fn openOrCreateDir(io: std.Io, path: []const u8) !Dir {
    const cwd = Dir.cwd();
    const opts = Dir.OpenOptions{ .iterate = true };

    return cwd.openDir(io, path, opts) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDir(io, path, .default_dir);
            return try cwd.openDir(io, path, opts);
        },
        else => return err,
    };
}

fn diff_two_vals(T: type, new: T, old: T) f64 {
    const dff: i128 = @as(i128, @intCast(new)) - @as(i128, @intCast(old));

    // std.debug.print("DIFF = {} NEW = {}, OLD = {} \n", .{ dff, new, old });
    return (@as(f64, @floatFromInt(dff)) / @as(f64, @floatFromInt(old))) * 100;
}

fn print_diff_value(term: Terminal, writer: *std.Io.Writer, label: []const u8, value: f64) !void {
    try writer.print("{s}: ", .{label});

    if (value < 0) {
        try term.setColor(.green);
    } else if (value > 0) {
        try term.setColor(.red);
    }

    try writer.print("{d:.03}%\n", .{value});

    if (value != 0) {
        try term.setColor(.reset);
    }
}

fn diff(term: Terminal, writer: *std.Io.Writer, res_new: *const Result, res_old: *const Result) !void {
    std.debug.assert(std.mem.eql(u8, res_new.name, res_old.name));

    try writer.print("Diff for test '{s}'\n", .{res_old.name});

    try print_diff_value(term, writer, "Total", diff_two_vals(
        u64,
        res_new.timing_statistics.total,
        res_old.timing_statistics.total,
    ));

    try print_diff_value(term, writer, "Mean", diff_two_vals(
        u64,
        res_new.timing_statistics.mean,
        res_old.timing_statistics.mean,
    ));

    try print_diff_value(term, writer, "p75", diff_two_vals(
        u64,
        res_new.timing_statistics.percentiles.p75,
        res_old.timing_statistics.percentiles.p75,
    ));

    try print_diff_value(term, writer, "p99", diff_two_vals(
        u64,
        res_new.timing_statistics.percentiles.p99,
        res_old.timing_statistics.percentiles.p99,
    ));
}

fn diff_two_runs(term: Terminal, writer: *std.Io.Writer, res_new: Results, res_old: Results) !void {
    for (res_new) |res| {
        for (res_old) |res_o| {
            if (std.mem.eql(u8, res.name, res_o.name)) {
                try diff(term, writer, &res, &res_o);
            }
        }
    }
}

fn compare_with_previous(
    io: std.Io,
    stdout: std.Io.File,
    dir: Dir,
    res_new: Results,
    alloc: Allocator,
) !void {
    const st = dir.statFile(io, ResultFile, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const res_old_buffer = try alloc.alloc(u8, st.size);
    defer alloc.free(res_old_buffer);

    const res_old_data = try dir.readFile(io, ResultFile, res_old_buffer);
    std.debug.assert(res_old_buffer.len == res_old_data.len);

    const res_old = try std.json.parseFromSlice(Results, alloc, res_old_data, .{ .allocate = .alloc_always });
    defer res_old.deinit();

    var diff_buffer: [4096]u8 = undefined;
    var diff_file_writer = stdout.writer(io, &diff_buffer);
    const diff_writer = &diff_file_writer.interface;
    const terminal_mode = try Terminal.Mode.detect(io, stdout, false, false);
    const terminal: Terminal = .{ .writer = diff_writer, .mode = terminal_mode };

    try diff_two_runs(terminal, diff_writer, res_new, res_old.value);
    try diff_writer.flush();
}

fn run(bench: zbench.Benchmark, config: Config, alloc: Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout: std.Io.File = .stdout();

    try zbench.prettyPrintHeader(io, stdout, 1000);

    const dir = try openOrCreateDir(io, config.dir);
    var wa = std.Io.Writer.Allocating.init(alloc);
    defer wa.deinit();
    var writer = &wa.writer;

    try writer.writeAll("[");
    var iter = try bench.iterator();
    var i: usize = 0;
    while (try iter.next(io)) |step| switch (step) {
        .progress => {},
        .result => |x| {
            defer x.deinit();
            defer i += 1;
            if (0 < i) try writer.writeAll(", ");

            try x.prettyPrint(io, stdout, 1000);
            try x.writeJSON(writer);
        },
    };

    try writer.writeAll("]\n");

    const res_new = try std.json.parseFromSlice(Results, alloc, wa.written(), .{ .allocate = .alloc_always });
    defer res_new.deinit();

    try compare_with_previous(io, stdout, dir, res_new.value, alloc);

    if (config.save_result) {
        try dir.writeFile(
            io,
            .{ .data = wa.written(), .sub_path = ResultFile, .flags = .{ .truncate = true } },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var config = Config.default();

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--save"))
            config.save_result = true;
    }

    const allocator = gpa.allocator();

    var bench = zbench.Benchmark.init(allocator, .{
        .max_iterations = 1024,
        .time_budget_ns = 500_000_000,
    });
    defer bench.deinit();

    try skiplist.add_benches(&bench);
    try db.add_benches(&bench);

    try run(bench, config, allocator);
}
