"""Reads the frames written by `--flicker` (out/flk_<view>_<config>_<still|moving>_NN.png) and prints how much the image
changes from one frame to the next, per configuration.

Still camera: the mean change per pixel (0-255 luma), the 99.5th percentile, and the share of pixels that change by more than
3 levels (a visible shimmer). Moving camera: the same, measured on the bounce light alone (each frame minus the Godot-only frame
of the same camera position), so that the motion itself does not count.

    py tools/flicker_report.py [out folder]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def luma(path: Path) -> np.ndarray:
	return np.asarray(Image.open(path).convert('L'), dtype=np.float32)


def frames(folder: Path, view: str, cfg: str, motion: str) -> list:
	return [luma(p) for p in sorted(folder.glob(f'flk_{view}_{cfg}_{motion}_*.png'))]


def stats(seq: list) -> tuple:
	d = np.stack([np.abs(b - a) for a, b in zip(seq, seq[1:])])
	return float(d.mean()), float(np.percentile(d, 99.5)), float((d > 3.0).mean() * 100.0)


def main() -> None:
	folder = Path(sys.argv[1] if len(sys.argv) > 1 else 'out')
	names = sorted({p.name.split('_')[1] for p in folder.glob('flk_*.png')})
	configs = []
	for p in sorted(folder.glob('flk_*_still_00.png')):
		parts = p.stem.split('_')
		cfg = '_'.join(parts[2:-2])
		if cfg not in configs:
			configs.append(cfg)
	for view in names:
		print(f'\n{view}')
		print(f'{"config":28s} {"still: mean":>12s} {"p99.5":>7s} {">3 lv %":>8s} | {"moving: mean":>12s} {"p99.5":>7s} {">3 lv %":>8s}')
		godot_moving = frames(folder, view, 'godot', 'moving')
		for cfg in configs:
			s = stats(frames(folder, view, cfg, 'still'))
			mv = frames(folder, view, cfg, 'moving')
			if cfg == 'godot':
				m = stats(mv)
			else:
				m = stats([a - g for a, g in zip(mv, godot_moving)])
			print(f'{cfg:28s} {s[0]:12.3f} {s[1]:7.1f} {s[2]:8.2f} | {m[0]:12.3f} {m[1]:7.1f} {m[2]:8.2f}')


if __name__ == '__main__':
	main()
