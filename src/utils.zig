const std = @import("std");
const root = @import("root.zig");

pub const Config = struct {
    size: usize,
    p: f64,
    seed: u64,
    out_dir: []const u8,
};

pub const State = struct {
    sizes: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !State {
        const sizes = try allocator.alloc(usize, size * size);
        return .{ .sizes = sizes, .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.sizes);
    }
};

pub fn captureState(states: *std.ArrayList(State), perc: *root.Percolation, size: usize) !void {
    var state = try State.init(states.allocator, size);

    var i: usize = 0;
    while (i < size * size) : (i += 1) {
        const root_val = perc.uf.find(i);
        state.sizes[i] = perc.uf.size[root_val];
    }

    try states.append(state);
}

pub fn ensureOutputDir(dir: []const u8) !void {
    try std.fs.cwd().makePath(dir);
}

pub fn writeMetadata(allocator: std.mem.Allocator, cfg: Config, total_bonds: usize) !void {
    var json_str = std.ArrayList(u8).init(allocator);
    defer json_str.deinit();

    try std.json.stringify(.{
        .size = cfg.size,
        .p = cfg.p,
        .seed = cfg.seed,
        .total_bonds = total_bonds,
        .total_states = total_bonds + 1,
    }, .{}, json_str.writer());

    const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "percolation.json" });
    defer allocator.free(meta_path);

    const meta_file = try std.fs.cwd().createFile(meta_path, .{});
    defer meta_file.close();
    try meta_file.writeAll(json_str.items);
}

pub fn writeBondsAndStates(
    allocator: std.mem.Allocator,
    bonds: []const root.Bond,
    states: []const State,
    cfg: Config,
) !void {
    const bonds_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "bonds.bin" });
    defer allocator.free(bonds_path);

    const states_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "states.bin" });
    defer allocator.free(states_path);

    // Write bonds
    const bonds_file = try std.fs.cwd().createFile(bonds_path, .{});
    defer bonds_file.close();
    var buffered_bonds = std.io.bufferedWriter(bonds_file.writer());
    const bonds_writer = buffered_bonds.writer();

    for (bonds, 0..) |bond, i| {
        const is_horizontal = bond.site2 == bond.site1 + 1;
        const row = bond.site1 / cfg.size;
        const col = bond.site1 % cfg.size;

        try bonds_writer.writeByte(if (is_horizontal) 1 else 0);
        try bonds_writer.writeInt(u32, @intCast(row), .little);
        try bonds_writer.writeInt(u32, @intCast(col), .little);

        if ((i + 1) % (bonds.len / 10) == 0) {
            const percent = (i + 1) * 100 / bonds.len;
            std.debug.print("Writing bonds: {d}% ({d}/{d})\n", .{ percent, i + 1, bonds.len });
        }
    }
    try buffered_bonds.flush();

    // Write states
    const states_file = try std.fs.cwd().createFile(states_path, .{});
    defer states_file.close();
    var buffered_states = std.io.bufferedWriter(states_file.writer());
    const states_writer = buffered_states.writer();

    // Pre-allocate buffer for entire state
    const buffer_size = cfg.size * cfg.size * @sizeOf(u32);
    var write_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(write_buffer);

    std.debug.print("Writing {d} states to file...\n", .{states.len});
    for (states, 0..) |state, i| {
        // Convert sizes to bytes
        for (state.sizes, 0..) |size_val, j| {
            const bytes = std.mem.asBytes(&@as(u32, @intCast(size_val)));
            @memcpy(write_buffer[j * 4 .. (j + 1) * 4], bytes);
        }

        try states_writer.writeAll(write_buffer);

        if ((i + 1) % (states.len / 10) == 0) {
            const percent = (i + 1) * 100 / states.len;
            std.debug.print("Writing states: {d}% ({d}/{d})\n", .{ percent, i + 1, states.len });
        }
    }
    try buffered_states.flush();
}

fn generateBonds(perc: *root.Percolation, cfg: Config, allocator: std.mem.Allocator) !std.ArrayList(root.Bond) {
    var bonds = std.ArrayList(root.Bond).init(allocator);
    try perc.generateBonds(cfg.p, &bonds);

    // Shuffle bonds
    var rng = std.rand.DefaultPrng.init(cfg.seed);
    const random = rng.random();
    var i: usize = bonds.items.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        const temp = bonds.items[i];
        bonds.items[i] = bonds.items[j];
        bonds.items[j] = temp;
    }

    return bonds;
}

fn printUsage() void {
    const usage =
        \\Usage: percolation [options]
        \\
        \\Options:
        \\  -s, --size <N>     Grid size (default: 10)
        \\  -p <float>         Bond probability [0.0-1.0] (default: 0.5)
        \\  --seed <N>         Random seed (default: timestamp)
        \\  --out <dir>        Output directory (default: ".")
        \\  -h, --help         Print this help message
        \\
        \\Environment Variables (fallback):
        \\  GRID_SIZE          Same as --size
        \\  P                  Same as -p
        \\  SEED              Same as --seed
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.skip();

    var config = Config{
        .size = 10,
        .p = 0.5,
        .seed = @intCast(std.time.timestamp()),
        .out_dir = ".",
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // First check environment variables as defaults
    if (env_map.get("GRID_SIZE")) |size_str| {
        config.size = try std.fmt.parseInt(usize, size_str, 10);
    }
    if (env_map.get("P")) |p_str| {
        config.p = try std.fmt.parseFloat(f64, p_str);
    }
    if (env_map.get("SEED")) |seed_str| {
        config.seed = try std.fmt.parseInt(u64, seed_str, 10);
    }

    // Then parse CLI args which override environment variables
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            const size_str = args.next() orelse {
                std.debug.print("Error: Missing value for size argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.size = try std.fmt.parseInt(usize, size_str, 10);
        } else if (std.mem.eql(u8, arg, "-p")) {
            const p_str = args.next() orelse {
                std.debug.print("Error: Missing value for p argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.p = try std.fmt.parseFloat(f64, p_str);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const seed_str = args.next() orelse {
                std.debug.print("Error: Missing value for seed argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.seed = try std.fmt.parseInt(u64, seed_str, 10);
        } else if (std.mem.eql(u8, arg, "--out")) {
            config.out_dir = args.next() orelse {
                std.debug.print("Error: Missing value for out argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
        }
    }

    // Validate configuration
    if (config.size < 2) {
        std.debug.print("Error: Grid size must be at least 2\n", .{});
        return error.InvalidArgument;
    }
    if (config.p < 0.0 or config.p > 1.0) {
        std.debug.print("Error: p must be between 0.0 and 1.0\n", .{});
        return error.InvalidArgument;
    }

    return config;
}

pub fn getTimeUs() i64 {
    return std.time.microTimestamp();
}

pub fn logTiming(start: i64, comptime msg: []const u8) void {
    const elapsed = getTimeUs() - start;
    std.debug.print("{s}: {d}ms\n", .{ msg, @as(f64, @floatFromInt(elapsed)) / 1000.0 });
}
