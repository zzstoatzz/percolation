import argparse
import json
import os
from itertools import product
from pathlib import Path
from typing import Any

import matplotlib.animation as animation
import matplotlib.collections as mcoll
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import LinearSegmentedColormap


def load_percolation() -> (
    tuple[dict[str, Any], np.ndarray, np.ndarray, np.ndarray, np.ndarray]
):
    meta = json.load(Path("percolation.json").open("r"))
    size = meta["size"]
    sites = size * size
    total_states = meta["total_states"]
    top_n = int(os.getenv("TOP_N", 3))

    # Load roots, sizes, and top sizes
    roots = np.fromfile("roots.bin", dtype=np.uint32).reshape(total_states, sites)
    sizes = np.fromfile("sizes.bin", dtype=np.uint32).reshape(total_states, sites)
    top_sizes = np.fromfile("top_sizes.bin", dtype=np.uint32).reshape(
        total_states, top_n
    )

    bonds_dtype = np.dtype([("direction", "u1"), ("row", "<u4"), ("col", "<u4")])
    bonds = np.frombuffer(Path("bonds.bin").read_bytes(), dtype=bonds_dtype)

    return meta, roots, sizes, bonds, top_sizes


def animate_percolation(save_path=None, interval=50, dpi=100):
    meta, roots, sizes, bonds, top_sizes = load_percolation()
    L = meta["size"]
    p = meta["p"]
    n_top = top_sizes.shape[1]  # Get number of top clusters from data

    # Create figure with two subplots side by side
    fig = plt.figure(figsize=(16, 8), facecolor="white")
    grid = plt.GridSpec(1, 2, width_ratios=[1, 1], wspace=0.3)

    # Grid subplot
    ax_grid = fig.add_subplot(grid[0])
    ax_grid.set_facecolor("#f5f5f5")
    ax_grid.set(xlim=(-0.5, L - 0.5), ylim=(L - 0.5, -0.5), xticks=[], yticks=[])

    # Cluster sizes subplot
    ax_sizes = fig.add_subplot(grid[1])
    ax_sizes.set_facecolor("#f5f5f5")
    ax_sizes.set_xlabel("Step")
    ax_sizes.set_ylabel("Cluster Size")
    ax_sizes.grid(True, alpha=0.3)

    # Setup grid lines
    grid_lines = np.arange(-0.5, L + 0.5, 1)
    ax_grid.hlines(
        grid_lines, -0.5, L - 0.5, color="#e0e0e0", linewidth=0.5, alpha=0.4, zorder=0
    )
    ax_grid.vlines(
        grid_lines, -0.5, L - 0.5, color="#e0e0e0", linewidth=0.5, alpha=0.4, zorder=0
    )

    coords = np.array(list(product(range(L), range(L))))

    base_node_size = np.clip(800 / L, 5, 50)
    marker_size = np.clip(15 / L, 0.5, 2)

    static_x, static_y = coords.T
    ax_grid.plot(
        static_x, static_y, "o", markersize=marker_size, color="#d0d0d0", alpha=0.3
    )

    horizontal_mask = bonds["direction"] == 1
    bond_segments = np.empty((len(bonds), 2, 2))

    bond_segments[horizontal_mask] = np.array(
        [
            [(c, r), (c + 1, r)]
            for r, c in zip(
                bonds["row"][horizontal_mask], bonds["col"][horizontal_mask]
            )
        ]
    )
    bond_segments[~horizontal_mask] = np.array(
        [
            [(c, r), (c, r + 1)]
            for r, c in zip(
                bonds["row"][~horizontal_mask], bonds["col"][~horizontal_mask]
            )
        ]
    )

    bond_collection = mcoll.LineCollection(
        [], color="#1B5299", alpha=0.3, linewidth=max(0.25, marker_size / 2), zorder=1
    )
    ax_grid.add_collection(bond_collection)

    cluster_scatter = ax_grid.scatter(
        coords[:, 0], coords[:, 1], s=0, zorder=2, alpha=0.8
    )

    step_text = ax_grid.text(
        0.02,
        1.02,
        "Initial Grid",
        transform=ax_grid.transAxes,
        bbox=dict(facecolor="white", alpha=0.8, edgecolor="none"),
        verticalalignment="top",
    )

    # Initialize cluster size tracking
    steps = np.arange(len(roots))
    lines = []
    labels = [f"#{i+1} Largest" for i in range(n_top)]
    colors = plt.cm.Set2(np.linspace(0, 1, n_top))  # Use colormap for n colors

    for i in range(n_top):
        (line,) = ax_sizes.plot([], [], label=labels[i], color=colors[i], linewidth=2)
        lines.append(line)

    ax_sizes.legend()
    ax_sizes.set_xlim(0, len(roots))

    max_cluster_size = np.max(top_sizes)
    ax_sizes.set_ylim(0, max_cluster_size * 1.1)

    colors = [
        "#E5E5E5",  # Light gray for unconnected
        "#4363d8",  # Blue
        "#3cb44b",  # Green
        "#ffe119",  # Yellow
        "#f58231",  # Orange
        "#e6194B",  # Red
    ]

    n_bins = 256
    custom_cmap = LinearSegmentedColormap.from_list(
        "cluster_sizes", colors[1:], N=n_bins
    )
    unconnected_color = colors[0]

    def init():
        bond_collection.set_segments([])
        cluster_scatter.set_sizes(np.full(L * L, base_node_size))
        cluster_scatter.set_facecolors(
            np.full((L * L, 4), [*plt.matplotlib.colors.to_rgb(unconnected_color), 0.5])
        )
        for line in lines:
            line.set_data([], [])
        return [cluster_scatter, step_text, bond_collection] + lines

    def update(frame):
        state_sizes = sizes[frame]

        if frame > 0:
            bond_collection.set_segments(bond_segments[:frame])

        # A site is unconnected if its cluster size is 1
        unconnected = state_sizes == 1
        connected_mask = ~unconnected

        # Initialize all colors as unconnected with 0.5 opacity
        all_colors = np.full(
            (L * L, 4), [*plt.matplotlib.colors.to_rgb(unconnected_color), 0.5]
        )
        node_sizes = np.full(L * L, base_node_size)

        if np.any(connected_mask):
            # Only compute colors for connected sites
            max_size = state_sizes[connected_mask].max()
            size_ratios = state_sizes[connected_mask] / max_size

            # Get base colors from colormap
            color_scale = np.power(
                size_ratios, 0.7
            )  # Adjusted power for better color distribution
            connected_colors = custom_cmap(color_scale)

            # Scale opacity between 0.5 and 1.0 based on cluster size
            connected_colors[:, 3] = 0.5 + 0.5 * size_ratios

            all_colors[connected_mask] = connected_colors

            # Adjust sizes for connected sites
            size_scale = np.power(state_sizes[connected_mask] / max_size, 0.5)
            node_sizes[connected_mask] *= 0.5 + 0.5 * size_scale

        cluster_scatter.set_offsets(coords)
        cluster_scatter.set_sizes(node_sizes)
        cluster_scatter.set_facecolors(all_colors)

        step_text.set_text(f"Step {frame}, p={p:.2f}")

        # Update cluster size lines using pre-computed top sizes
        current_step = steps[: frame + 1]
        for i, line in enumerate(lines):
            line.set_data(current_step, top_sizes[: frame + 1, i])

        return [cluster_scatter, step_text, bond_collection] + lines

    ani = animation.FuncAnimation(
        fig,
        update,
        frames=len(roots),
        init_func=init,
        interval=interval,
        blit=True,
        cache_frame_data=False,
    )

    if save_path:
        writer = animation.PillowWriter(fps=1000 / interval)
        ani.save(save_path, writer=writer, dpi=dpi)
    else:
        plt.show(block=True)

    plt.close()
    return ani


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Visualize percolation animation")
    parser.add_argument(
        "--save", type=str, help="Path to save the animation (e.g. animation.gif)"
    )
    parser.add_argument(
        "--interval", type=int, default=50, help="Animation interval in milliseconds"
    )
    parser.add_argument("--dpi", type=int, default=100, help="DPI for saved animation")

    args = parser.parse_args()
    animate_percolation(args.save, args.interval, args.dpi)
