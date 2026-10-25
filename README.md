# Radiance Cascades Lab

Real-time bounce light with **Radiance Cascades** in **Godot 4.7**, written as a `CompositorEffect` with compute shaders.
No engine changes, no plugins: open the folder in Godot and run it.

![A small store lit by Godot alone, with radiance cascades added, and the bounce light on its own](docs/readme/store.jpg)

## The scene

A store, a curved corridor with no lamp inside, a room of materials and a dark room lit only by a television.

![The curved corridor next to the store, and the same view as a heat map of the bounce light](docs/readme/corridor.jpg)

![A neon sign as the only light at the end of the corridor](docs/readme/neon_sign.jpg)

![The materials room: Godot alone and with radiance cascades](docs/readme/materials.jpg)

![Chrome and gold spheres reflecting the room](docs/readme/metals.jpg)

![Light through a tinted glass pane takes its colour](docs/readme/tinted_glass.jpg)

![The dark room: Godot alone and with radiance cascades](docs/readme/dark_room_tv.jpg)

![The television at three moments: the room's light follows the picture](docs/readme/tv_picture.jpg)

## How it works

The scene is voxelized, and every frame the effect:

1. lights the voxels (lamps with shadows, glowing surfaces, last frame's bounce);
2. traces the probe cascades, coarsest to finest, each merging into the one below;
3. traces short rays per pixel for sharp contact shadows, and reflections for shiny surfaces (sharp from the picture where it can, blurred from the probes elsewhere);
4. gathers per pixel, blends with the previous frame and filters.

It handles moving objects and lights, emissive surfaces, several bounces, metals, glossy plastic and tinted glass.

Radiance Cascades: Alexander Sannikov, *Radiance Cascades: A Novel Approach to Calculating Global Illumination* (2023).

## Running it

Godot 4.7 and a GPU with Vulkan compute support:

```sh
godot --path . --rendering-driver vulkan
```

| Input | Action |
|---|---|
| Right mouse button (hold) | look around |
| Quote key (above Tab) | look mode on / off |
| W A S D, Q / E | fly; down / up |
| Left click, drag | select and move a prop |
| 1 to 5 | Godot only, + bounce, bounce only, heat map, screen-space |

![The control panel and the object picker](docs/readme/panel.jpg)

## Performance

RX 9070 XT, 1920x1080, High preset:

| | ms (FPS) |
|---|---|
| Godot alone | 0.89 (1120) |
| Godot + radiance cascades | 4.05 (247) |
| the same, with the dolly and its lamp moving | 5.42 (185) |

## Limits

- One voxel volume, fixed in place: no large open worlds.
- Moving objects are voxelized as boxes.
- Sharp reflections only show what is on screen; the rest is blurred.

Every step, with its measurements, is in [docs/DEVLOG.md](docs/DEVLOG.md).

## License

MIT, see [LICENSE](LICENSE).
