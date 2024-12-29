const std = @import("std");
const root = @import("root.zig");
const utils = @import("utils.zig");

pub fn main() !void {
    const total_start = utils.getTimeUs();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse and validate configuration
    const cfg = try utils.parseArgs(allocator);
    std.debug.print("\nGrid size: {d}x{d} ({d} sites)\n", .{ cfg.size, cfg.size, cfg.size * cfg.size });
    std.debug.print("Bond probability: {d:.2}\n", .{cfg.p});
    std.debug.print("Random seed: {d}\n", .{cfg.seed});
    std.debug.print("Output directory: {s}\n", .{cfg.out_dir});
    std.debug.print("Tracking top {d} clusters\n\n", .{cfg.top_n});

    // Ensure output directory exists
    try utils.ensureOutputDir(cfg.out_dir);

    // Initialize percolation
    const init_start = utils.getTimeUs();
    var perc = try root.Percolation.init(allocator, cfg.size, cfg.seed);
    defer perc.deinit();
    utils.logTiming(init_start, "Percolation init");

    // Generate and shuffle bonds
    const gen_start = utils.getTimeUs();
    var bonds = try utils.generateBonds(&perc, cfg, allocator);
    defer bonds.deinit();
    utils.logTiming(gen_start, "Bond generation and shuffling");

    // Write metadata
    const json_start = utils.getTimeUs();
    try utils.writeMetadata(allocator, cfg, bonds.items.len);
    utils.logTiming(json_start, "JSON metadata");

    // Prepare state storage
    const states_init_start = utils.getTimeUs();
    var states = std.ArrayList(utils.State).init(allocator);
    defer {
        for (states.items) |*state| {
            state.deinit();
        }
        states.deinit();
    }

    // Store initial state
    try utils.captureState(&states, &perc, cfg.size, cfg.top_n);
    utils.logTiming(states_init_start, "States initialization");

    // Process bonds and capture states
    const process_start = utils.getTimeUs();
    var bonds_processed: usize = 0;
    const progress_interval = bonds.items.len / 10;

    for (bonds.items) |bond| {
        perc.uf.merge(bond.site1, bond.site2);
        try utils.captureState(&states, &perc, cfg.size, cfg.top_n);

        bonds_processed += 1;
        if (progress_interval > 0 and bonds_processed % progress_interval == 0) {
            const percent = bonds_processed * 100 / bonds.items.len;
            std.debug.print("Processing bonds: {d}% ({d}/{d})\n", .{ percent, bonds_processed, bonds.items.len });
        }
    }
    utils.logTiming(process_start, "Bond processing and state capture");

    // Write output files
    const write_start = utils.getTimeUs();
    try utils.writeBondsAndStates(allocator, bonds.items, states.items, cfg);
    utils.logTiming(write_start, "File writing");
    utils.logTiming(total_start, "Total execution");
}
