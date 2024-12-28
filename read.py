# /// script
# dependencies = ["numpy", "matplotlib"]
# ///

import json
import argparse
from itertools import product
from pathlib import Path
from typing import Any

import matplotlib.animation as animation
import matplotlib.pyplot as plt
import matplotlib.collections as mcoll
import numpy as np


def load_percolation() -> tuple[dict[str, Any], np.ndarray, np.ndarray]:
    # Load metadata
    meta = json.load(Path("percolation.json").open("r"))
    size = meta["size"]
    sites = size * size
    total_states = meta["total_states"]

    # Load states as [timestep, site] array of cluster sizes
    states = np.fromfile("states.bin", dtype=np.uint32)
    states = states.reshape(total_states, sites)

    # Load bonds as structured array
    bonds_dtype = np.dtype([
        ('direction', 'u1'),
        ('row', '<u4'),
        ('col', '<u4')
    ])
    bonds = np.fromfile("bonds.bin", dtype=bonds_dtype)

    return meta, states, bonds


def animate_percolation(save_path=None, interval=50, dpi=100):
    meta, states, bonds = load_percolation()
    L = meta["size"]
    p = meta["p"]

    fig, ax = plt.subplots(figsize=(8, 8), facecolor='white')
    ax.set_facecolor('#f8f9fa')  # Light gray background

    # Set up static elements once
    ax.grid(False)
    ax.set_xlim(-0.5, L - 0.5)
    ax.set_ylim(L - 0.5, -0.5)
    ax.set_xticks([])  # Remove number labels
    ax.set_yticks([])

    # Create lattice grid in background
    for i in range(L+1):
        ax.axhline(y=i-0.5, color='#e9ecef', linewidth=0.5, alpha=0.4, zorder=0)
        ax.axvline(x=i-0.5, color='#e9ecef', linewidth=0.5, alpha=0.4, zorder=0)

    # Pre-compute coordinates for all nodes
    coords = np.array([(c, r) for r, c in product(range(L), range(L))])

    # Scale base node size with grid size
    base_node_size = max(20, min(200, 2000 / L))
    marker_size = max(1, min(3, 30 / L))

    # Create static node markers (smaller background dots)
    static_nodes = []
    for r, c in product(range(L), range(L)):
        node = ax.plot(c, r, "o", markersize=marker_size, color="#dee2e6", alpha=0.5)[0]
        static_nodes.append(node)

    # Pre-compute all bond segments
    bond_segments = []
    for bond in bonds:
        is_horizontal = bond['direction'] == 1
        if is_horizontal:
            bond_segments.append([(bond['col'], bond['row']), (bond['col'] + 1, bond['row'])])
        else:
            bond_segments.append([(bond['col'], bond['row']), (bond['col'], bond['row'] + 1)])
    
    # Create line collection for bonds
    bond_collection = mcoll.LineCollection(
        [], 
        color='#2b6a4d',  # Forest green
        alpha=0.3, 
        linewidth=max(0.5, marker_size/2), 
        zorder=1
    )
    ax.add_collection(bond_collection)

    # Create scatter plot for clusters
    cluster_scatter = ax.scatter(
        coords[:, 0], 
        coords[:, 1], 
        s=0, 
        zorder=2,
        alpha=0.9
    )

    # Create a text box for step counter
    step_text = ax.text(
        0.02,
        1.02,
        "Initial Grid",
        transform=ax.transAxes,
        bbox=dict(facecolor='white', alpha=0.8, edgecolor='none'),
        verticalalignment="top",
    )

    # Track previous sizes for transition effects
    prev_sizes = np.zeros(L * L)

    # Create custom colormap
    from matplotlib.colors import LinearSegmentedColormap
    colors = [
        '#f8f9fa',  # Almost white for unconnected
        '#cfe1b9',  # Light sage
        '#97d4bb',  # Mint
        '#437c90',  # Steel blue
        '#2d5362',  # Deep blue-green
    ]
    n_bins = 256
    custom_cmap = LinearSegmentedColormap.from_list('earth', colors, N=n_bins)

    def init() -> list[Any]:
        bond_collection.set_segments([])
        cluster_scatter.set_sizes(np.zeros(L * L))
        return [cluster_scatter, step_text, bond_collection]

    def update(frame: int) -> list[Any]:
        nonlocal prev_sizes
        sizes = states[frame]
        
        # Update visible bonds all at once
        if frame > 0:
            bond_collection.set_segments(bond_segments[:frame])

        # Identify newly grown clusters
        size_changes = sizes - prev_sizes
        growth_mask = size_changes > 0
        
        # Color nodes by their cluster size using custom colormap
        max_size = sizes.max() if sizes.max() > 0 else 1
        size_ratios = sizes / max_size

        # Create color scale with emphasis on small clusters
        # Use log scale to better differentiate small clusters
        color_scale = np.log1p(size_ratios) / np.log1p(1.0)
        colors = custom_cmap(color_scale)
        
        # Make unconnected nodes (size=1) very light
        unconnected = sizes == 1
        colors[unconnected] = np.array([248/255, 249/255, 250/255, 0.3])  # Very light gray, more transparent
        
        # Size scaling with more dramatic growth for larger clusters
        size_scale = np.power(size_ratios, 0.6)  # Slightly more aggressive scaling
        node_sizes = base_node_size * (0.3 + 0.7 * size_scale)  # 30% minimum size
        
        # Subtle pulse effect only for significantly growing clusters
        if frame > 0:
            significant_growth = size_changes > (max_size * 0.1)  # Only pulse for >10% max size changes
            if any(significant_growth):
                pulse = 1.2 if frame % 2 == 0 else 1.1
                node_sizes[significant_growth] *= pulse

        cluster_scatter.set_offsets(coords)
        cluster_scatter.set_sizes(node_sizes)
        cluster_scatter.set_facecolors(colors)
        
        step_text.set_text(f"Step {frame}, p={p:.2f}")
        
        # Update previous sizes for next frame
        prev_sizes = sizes.copy()

        return [cluster_scatter, step_text, bond_collection]

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
        writer = animation.PillowWriter(fps=1000/interval)
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
