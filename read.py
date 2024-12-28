# /// script
# dependencies = ["numpy", "matplotlib"]
# ///

import json
import argparse
from itertools import product
from pathlib import Path

import matplotlib.animation as animation
import matplotlib.pyplot as plt
import numpy as np


def load_percolation():
    # Load metadata
    meta = json.load(Path("percolation.json").open("r"))
    size = meta["size"]
    sites = size * size

    # Read binary data
    data = np.fromfile("steps.bin", dtype=np.uint8)  # read as bytes first

    # Calculate sizes
    state_size = sites * 8  # 2 u32s per site

    # Separate states and bonds
    states = []
    bonds = []

    # Initial state
    pos = 0
    state_data = np.frombuffer(data[pos : pos + state_size], dtype=np.uint32)
    states.append(state_data.reshape(sites, 2))
    pos += state_size

    # Read bonds and subsequent states
    while pos < len(data):
        # Read bond
        direction = data[pos]
        pos += 1
        bond_data = np.frombuffer(data[pos : pos + 8], dtype=np.uint32)
        bonds.append((direction, bond_data[0], bond_data[1]))
        pos += 8

        # Read state
        state_data = np.frombuffer(data[pos : pos + state_size], dtype=np.uint32)
        states.append(state_data.reshape(sites, 2))
        pos += state_size

    return meta, np.array(states), bonds


def animate_percolation(save_path=None, interval=50, dpi=100):
    meta, states, bonds = load_percolation()
    L = meta["size"]
    p = meta["p"]

    fig, ax = plt.subplots(figsize=(8, 8))

    # Set up static elements once
    ax.grid(True)
    ax.set_xlim(-0.5, L - 0.5)
    ax.set_ylim(L - 0.5, -0.5)

    # Pre-compute coordinates for all nodes
    coords = np.array([(c, r) for r, c in product(range(L), range(L))])

    # Create static node markers once
    static_nodes = []
    for r, c in product(range(L), range(L)):
        node = ax.plot(c, r, "o", markersize=5, color="black", alpha=0.6)[0]
        static_nodes.append(node)

    # Create static elements for bonds
    bond_lines = [
        ax.plot([], [], "b-", linewidth=2, zorder=3)[0] for _ in range(len(bonds))
    ]

    # Create scatter plot for clusters with initial empty state
    cluster_scatter = ax.scatter(coords[:, 0], coords[:, 1], s=0, zorder=2)

    # Create a text box for step counter in lower left
    step_text = ax.text(
        0.02,
        0.98,
        "Initial Grid",
        transform=ax.transAxes,
        bbox=dict(facecolor="white", alpha=0.8, edgecolor="none"),
        verticalalignment="top",
    )

    def init():
        for line in bond_lines:
            line.set_data([], [])
        cluster_scatter.set_sizes(np.zeros(L * L))
        return [cluster_scatter, step_text] + bond_lines

    def update(frame):
        state = states[frame]
        roots = state[:, 0]
        sizes = state[:, 1]

        # Update visible bonds
        for i in range(frame):
            if i < len(bonds):
                direction, r, c = bonds[i]
                is_horizontal = direction == 1
                bond_lines[i].set_data(
                    [c, c + 1] if is_horizontal else [c, c],
                    [r, r] if is_horizontal else [r, r + 1],
                )

        # Update clusters efficiently
        unique_roots = np.unique(roots)
        root_to_idx = {r: i for i, r in enumerate(unique_roots)}
        cluster_indices = np.array([root_to_idx[r] for r in roots])

        cmap = plt.cm.viridis
        max_color = max(cluster_indices) if len(cluster_indices) > 0 else 1
        node_colors = cmap(cluster_indices / max_color)

        node_sizes = 150 * (sizes / sizes.max())

        cluster_scatter.set_offsets(coords)
        cluster_scatter.set_sizes(node_sizes)
        cluster_scatter.set_facecolors(node_colors)

        step_text.set_text(f"Step {frame}, p={p:.2f}")

        return [cluster_scatter, step_text] + bond_lines[:frame]

    ani = animation.FuncAnimation(
        fig,
        update,
        frames=len(states),
        init_func=init,
        interval=interval,
        blit=True,
        cache_frame_data=False,
    )

    if save_path:
        # Save animation
        writer = animation.PillowWriter(fps=1000/interval)  # Convert interval to fps
        ani.save(save_path, writer=writer, dpi=dpi)
    else:
        plt.show()
    
    return ani

def main():
    parser = argparse.ArgumentParser(description='Visualize percolation animation')
    parser.add_argument('--save', type=str, help='Path to save the animation (e.g. animation.gif)')
    parser.add_argument('--interval', type=int, default=50, help='Animation interval in milliseconds')
    parser.add_argument('--dpi', type=int, default=100, help='DPI for saved animation')
    
    args = parser.parse_args()
    animate_percolation(args.save, args.interval, args.dpi)

if __name__ == "__main__":
    main()
