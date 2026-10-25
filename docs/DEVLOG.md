# Development log

Each step of the lab in the order it was built: what was tried, what went wrong, how it was measured and fixed.
Numbers are from one machine (RX 9070 XT) unless said otherwise. Two prototypes of **Radiance Cascades** global illumination
in Godot 4.7.2 (Forward+), both `CompositorEffect`s with compute shaders.

| Step | File | What it is |
|---|---|---|
| 1 | `src/rc/rc_effect.gd` | screen space: rays march the depth buffer, off-screen light does not exist |
| 2 | `src/rc/rc_world_effect.gd` | world space: voxelized scene + 3D probe cascades, off-screen light counts (section below) |

## What it does

```
depth + lit colour  ->  cascade 4 (long rays) -> ... -> cascade 0 (short rays)   [5 dispatches]
                        each ray marches the depth buffer inside its interval,
                        a miss reads the 4 nearest probes of the cascade above (depth-weighted)
cascade 0           ->  gather: per pixel, cosine-weighted irradiance of the 4 nearest probes,
                        times a guessed albedo, added to the scene colour               [1 dispatch]
```

- Probe spacing and directions double per level (`a_n = 4 << n`, octahedral grid), intervals are 4x longer
  (8, 32, 128, 512, 2048 px), so every level traces the same number of rays.
- GI runs at half resolution (`gi_scale = 2`); the gather is full resolution.
- Single bounce, no temporal reuse, no denoiser.

## Run

From the repository root:

```sh
godot --path . --rendering-driver vulkan --resolution 1920x1080 -- --shots --bench
```

`--shots` writes off / on / indirect-only images for four camera poses, `--bench` measures GPU time with
the effect off and on. Everything lands in `out/` (git-ignored).

## Measured (RX 9070 XT, trivial test room, 5 cascades, scale 2)

| Resolution | Rays/frame | Cascades | Gather | GI total |
|---|---|---|---|---|
| 1280x720 | 1.23 M | 0.21 ms | 0.12 ms | **0.33 ms** |
| 1920x1080 | 2.76 M | 0.46 ms | 0.26 ms | **0.72 ms** |
| 2560x1421 | 4.92 M | 0.91 ms | 0.45 ms | **1.36 ms** |

Rough extrapolation, **not measured**: a Radeon Pro 5500M / GTX 1660 class GPU is about 10x slower than this
card, which puts 1080p near 7 ms. That is close to the 14.8 ms for 4.89 M rays the Blackline video shows
on a 5500M (about 3 ms per million rays in both). The test room is almost empty, so real scenes will cost more.

## Limits (by construction)

- **Screen space:** rays only see what is in the depth buffer and the colour buffer of the current frame.
  Geometry and lights outside the screen, or hidden behind something, contribute nothing; turning the camera
  changes the lighting. `offscreen_fill` is the only fallback.
- Thin occluders: a ray hits when it passes behind a surface by less than `thickness`.
- Albedo is guessed from the lit pixel (chroma kept, luma fixed). A real integration needs the G-buffer.
- Hit radiance is the lit colour of the previous pass, so there is only one bounce.
- No dynamic-range handling beyond a clamp (`max_radiance`).

## Next steps if this goes on

1. World-space probes (clipmap around the camera) so off-screen surfaces count.
2. A traceable scene representation for them (voxels or SDF), which is the real research cost.
3. Temporal reuse and an upsample that is aware of edges.


---

# Step 2: world-space cascades (street at night, lamp posts)

Test scene: a 32 m street (`main.gd`, `--scene=street`) with three sodium lamp posts, coloured buildings and
sidewalks. Godot lights the pixels directly; the effect adds the **bounce**.

```
scene boxes --voxelize (compute, once)--> albedo volume 128x48x128 @ 0.25 m
lights      --inject  (compute, once)--> radiance volume: albedo * direct light, shadowed by DDA through the voxels
per frame:  cascade 3 -> 2 -> 1 -> 0   world probes (spacing 1, 2, 4, 8 m; 16, 64, 256, 1024 directions each),
            rays walk the voxels (DDA); a miss merges with the 8 nearest upper probes (visibility-checked)
            gather: per pixel, world position + normal from depth, 8 nearest cascade-0 probes, albedo from the voxel
```

- Intervals 0.5, 2, 8, 32 m (x4 per level), so the top cascade covers the 32 m volume. About 377 k rays per frame.
- The camera transform is checked by `world_alb` (voxel albedo painted on each pixel): the buildings and poles line up.
- Albedo comes from the voxel, so the lit-colour guess of step 1 is gone.
- Bulb emission is **not** in the volume: the lamps' direct light is injected from the light list, so it is not counted twice.

## Cost (RX 9070 XT, 32 m street, 4 cascades, scale-independent cascades)

| Resolution | World cascades | World gather | World total | Screen-space total (step 1) |
|---|---|---|---|---|
| 1280x720 | 0.26 ms | 0.21 ms | **0.47 ms** | 0.41 ms |
| 1920x1080 | 0.26 ms | 0.42 ms | **0.68 ms** | 1.0 ms |
| 2560x1421 | 0.30 ms | 0.74 ms | **1.03 ms** | 2.2 ms |

The world cascades do not depend on the screen size; only the gather does. Voxelizing and injecting happen once and
were not timed separately. Same extrapolation caveat as step 1: a 1660 / RX 6600 is slower than this card, and this
scene is small and static.

## Lamp off screen: the pitch sweep

`--sweep`: the camera pitches up from 0 to 45 deg. G is a point high on the lit brick facade, the lit sidewalk at its foot is
the main bounce source and leaves the screen at 30 deg while G stays in view. Indirect light only (sky off), luminance at G:

| Pitch | Sidewalk on screen | Screen-space | World-space |
|---|---|---|---|
| 0 deg | yes | 0.0 | 36.8 |
| 15 deg | yes | 85.6 | 36.7 |
| 25 deg | yes | 0.8 | 36.8 |
| 30 deg | **no** | 0.8 | 36.8 |
| 40 deg | **no** | 102.5 | 36.8 |
| 45 deg | **no** | 180.4 | 33.4 |

- **World space does not move** (36.7 to 36.8, 33.4 at the last step where G is at the screen edge): the bounce does not depend on
  where the camera looks.
- **Screen space is erratic, not just "dark when the source leaves"**: near 0 with the sidewalk in view (the sidewalk is a thin
  strip at a grazing angle, the ray steps jump over it), with spikes at 15, 40 and 45 deg (edge and stripe artifacts, see
  `images/street_sweep_ss_gi_40.jpg`). So this test shows that screen space is unreliable here, **not** cleanly that off-screen is the cause.
- Screen space also counts the bulb pixels as light sources (double counting with the direct light); world space does not.
- Images: `images/street_*.jpg` (`world_gi` = indirect only, x10 gain).

## Limits of step 2 (not done)

- **Static scene.** The voxels and the lit volume are built once. Moving objects, doors, opening shutters or a changing
  light need re-voxelizing / re-injecting (dirty regions) and are not implemented.
- **Fixed volume.** 32 m x 12 m x 32 m around the origin. A city needs a camera-following clipmap of volumes.
- **Resolution.** 0.25 m voxels lose thin things (the pole is one voxel wide); probes are 1 m apart, so contact shadows and
  small penumbras are soft. Albedo is flat colour per voxel, no textures.
- **Leaks** are controlled (probes inside solids are skipped, probe-to-probe and probe-to-pixel visibility rays) but I did not
  stress-test thin walls or corners.
- One bounce, no temporal reuse, sky is a constant colour, direct light is Godot's and the injected copy only approximates its falloff.
- Measured on one fast GPU only.


---

# Step 3: dynamic objects, a moving light and a curved tunnel

`--scene=tunnel` (now the default): a tunnel 4 m wide and 3.5 m tall, straight 8 m, a 90 degree left bend (radius 8 m, 12 short
segments), straight 14 m. Red outer wall, teal inner wall, two static crates. Dynamic parts:

- a **cart with a lamp** that rides along the tunnel (a `OmniLight3D` + a box, casts a shadow),
- a **blade spinning under the ceiling** (a box that changes the voxels every frame, so its shadow moves).

```
per frame (dynamic = true):
  copy the static voxels into the working volume          (texture copy)
  voxelize the moving triangles on top                     (compute, tens of triangles)
  inject every light again, shadowed through the voxels    (compute)
  cascades + gather as before
```

Nothing is cached between frames, so there is no lag: the light and the objects are exactly where they are this frame.

## Does the paper cover this?

I only read the abstract of *Split Radiance Cascades* (arXiv 2607.20384): it says it was evaluated "in single-frame and temporally
accumulated contexts" and says nothing about moving objects. The method itself recomputes the cascades from the current scene each
frame, so a moving light costs nothing special (the cost does not depend on how many lights there are). What does cost something is
keeping the **scene representation** (here the voxels) up to date, which is done by the three passes above and is not in the paper.

## Light travelling round the bend (RX 9070 XT, 1280x720)

`--travel`: the cart lamp is parked at s = 6 m (before the bend). Luminance (after tonemap, x1000) at a point 1.5 m high on the outer wall.
"Direct + ambient" is Godot alone; "indirect" is the world-space RC alone (x10 gain). The lamp's range is 14 m.

| Point s | Metres from lamp | Region | Direct + ambient | Indirect (world RC) |
|---|---|---|---|---|
| 10 | 4 | bend | 579 | 560 |
| 14 | 8 | bend | 314 | 407 |
| 18 | 12 | bend | 99 | 269 |
| 22 | 16 | straight B | 25 | 85 |
| 26 | 20 | straight B | 25 | 7 |
| 30 | 24 | straight B | 25 | 0 |

Past the bend (s >= 18) the bounce is brighter than the direct light, and at s = 22 it still adds light after the lamp's range ends
(direct there is only the ambient floor). By s = 26 it is almost gone. Images: `images/tunnel_*.jpg` (colour bleeding from the red
wall onto the teal one is visible in `tunnel_exit_back_lamp24_world.jpg`).

## A light that moves

`--travel` also moves the lamp from s = 20 to s = 26 and reads a wall point 0, 1 and 5 frames later: **272 -> 723 on the first rendered
frame, and unchanged after that** (723 at +1 and +5). No frame of lag, as expected from a method with no temporal accumulation.

## Cost of being dynamic (tunnel, RX 9070 XT)

| | 1280x720 | 1920x1080 |
|---|---|---|
| GI off (Godot only) | 1868 FPS (0.54 ms) | 2041 FPS (0.49 ms) |
| World RC, frozen volume | 1319 FPS (0.76 ms) | 835 FPS (1.20 ms) |
| **World RC, dynamic every frame** | **1238 FPS (0.81 ms)** | **785 FPS (1.27 ms)** |
| Screen-space RC (step 1) | 1158 FPS (0.86 ms) | 516 FPS (1.94 ms) |

GPU time of the passes at 1080p: copy 0.003 ms, dynamic voxels + light injection 0.062 ms, cascades 0.27 ms, gather 0.41 ms. Being dynamic
costs about **0.06 ms** here (the frame goes from 1.20 to 1.27 ms). The tunnel has about two dozen moving triangles and one light.

## Limits of step 3

- **Few moving things.** 24 moving triangles and 1 moving light. The injection pass walks every voxel of the 128x48x128 volume each
  frame; more lights (each with shadow rays) or a big moving mesh (up to 2048 triangles fit the buffer) will cost more. Not measured.
- **Curved surfaces show the 25 cm staircase.** The bend is voxelized into steps, and the albedo read from the voxel under a pixel is
  sometimes the neighbour's: dark jagged pixels along the floor/wall edges and some speckle (`images/tunnel_bend_lamp08_world.jpg`).
- **Moving geometry is only voxelized as solid boxes of its triangles** and its albedo is a flat colour; no skinning or deformation was tried.
- **Static voxels never change.** A door that opens would need to live in the dynamic set.
- **Light colour leaks and range:** the injected light copies Godot's falloff formula but not its shadow filtering, so a lit pixel and the
  bounce it produces can disagree slightly.
- Measured on one fast GPU, one scene, one moving light.


---

# Step 3b: a visual quality pass on the tunnel

Problem with the first tunnel: the light looked pixelated, and it was hard to tell Godot's own lighting from the effect's. What was wrong and what changed:

| Problem | Cause | Fix |
|---|---|---|
| Jagged teeth along the bend and wall/floor edges | The bend was 12 overlapping boxes (their faces cut through each other), and the 25 cm voxels stair-stepped the curve | The tunnel is now one smooth mesh per surface, built slice by slice (20 cm slices) with per-slice normals; voxels are 12.5 cm; probes every 0.5 m instead of 1 m |
| Black pixels and thin black lines at corners and seams | The pixel-to-probe visibility ray started inside a wall voxel, so every probe was rejected | Start the ray further out; if every probe is still rejected, a second pass skips the visibility test instead of leaving the pixel black |
| Wrong wall colour on some edge pixels | The albedo was read from the first voxel found, sometimes the neighbouring surface's | Search the 3x3x3 voxels around, ignore voxels in front of the surface, prefer the one right behind the pixel |
| Noisy normals on the voxelized curve (blotchy injected light) | 3x3x3 neighbourhood | 5x5x5, closer voxels count more |
| Jagged Godot shadows, banding | Default shadow atlas, no AA | Shadow atlas 8192, soft shadow filter quality 4, cube shadow mode with blur on the cart lamp, FXAA, debanding |
| Over-bright, blown-out tunnel | Too much exposure for the lamp | Exposure 4 -> 2.5, cart lamp energy 20 -> 14 |
| "What is Godot, what is the effect?" | Nothing said so | The HUD names the mode and says what is what; key 1 shows Godot alone, 5 shows only the effect's bounce light |

**What is Godot's in these images:** the lamp's light on the walls, its shadows, the colours, the tone mapping. **What is the effect's:** only the indirect
(bounce) light, e.g. the orange spill on the far walls past the bend and the colour from the red wall on the teal one.

Before and after (`images/before_tunnel_*.jpg` were the first tunnel, `images/tunnel_*.jpg` are the new one):
the bend is smooth, the shadow edges are clean, the black teeth and lines are gone.

## Cost of the better look (RX 9070 XT, tunnel, world RC dynamic every frame)

| | Before (25 cm voxels, 1 m probes) | After (12.5 cm voxels, 0.5 m probes, wider kernels) |
|---|---|---|
| 1280x720 | 1238 FPS (0.81 ms) | 572 FPS (1.75 ms) |
| 1920x1080 | 785 FPS (1.27 ms) | 417 FPS (2.40 ms) |

At 1080p the passes are now: dynamic voxels + injection 0.22 ms (was 0.06), cascades 0.55 ms (was 0.27), gather 0.94 ms (was 0.41). The looks are
paid for with about **1.1 ms** more at 1080p. The gather got the most expensive (27 voxel reads for the albedo, a second pass at corners); that is the first
place to optimize. The volume also shrank to the tunnel (24 x 6 x 27 m), so a bigger map would cost more.

## Still not right

- **Silhouette teeth.** Along the screen edge of the near inner wall (grazing angle) there are still voxel-sized teeth in the effect's light
  (`images/tunnel_bend_lamp08_world.jpg`, left); the Godot-only image has clean silhouettes. The pixel normal comes from the depth buffer and is
  unreliable at a grazing angle. A normal taken from the voxels would fix it; not done.
- Fine grain on some walls (the cascades have no temporal smoothing).
- Albedo is still the voxel's flat colour.


---

# Step 3c: the corner artifacts (walls and the moving cart)

Problem: pixelated artifacts remained in the corners, mostly along wall corners and around the moving box.

## Research (web)

- **DDGI** (probe-based GI) papers: leaks and artifacts at corners come from a query point too close to the surface and from probes on the wrong
  side of a wall; the fixes are a bias on the query point, visibility-aware probe weights and treating backface hits as dark. Our gather already
  weights probes by visibility and facing; what it lacked is robustness when the *voxelized* surface is a little thicker than the real one.
- **Radiance Cascades** write-ups: 3D needs occlusion when interpolating between cascades (we already ray-test probe to probe) and the
  "minimal overlap" fix adds a small extra range to each interval (not needed here).
- **Voxel GI** threads: every implementation fights light leaks; mip/filter sums of empty (black) voxels darken results; rays must start outside the voxel.
- I found no published fix for exactly this "stair-stepped corner" problem in world-space RC; the fixes below come from isolating each cause with debug views.

## What was wrong (found with close-ups and debug views)

Close-up poses (`--closeups`) show, for each corner: Godot alone, with the effect, indirect only, the albedo the effect used (`world_alb`) and a
validity map of the gather (`world_dbg`). Godot's own image has perfectly clean corners, so every artifact was the effect's.

| Artifact | Cause (evidence) | Fix |
|---|---|---|
| Sawtooth of wrong colour along every floor/wall edge, polygon-shaped cart | The albedo was read from the 12.5 cm **voxels**: in `world_alb` the floor/wall boundary was a staircase and the cart a hexagon | Per-pixel albedo from a **second, unshaded render** of the same world (`SubViewport` with `debug_draw = unshaded`, linear tonemap, sRGB decoded in the gather). An engine with a G-buffer would have this for free; Godot's Forward+ does not expose it |
| Light-coloured band, sawtooth, along the wall base | `world_dbg`: the start of the pixel-to-probe visibility ray fell inside a wall step, every probe was rejected, and the fallback pass used the probes with **no** occlusion test (leaking) | The visibility ray skips its first 3 voxels (where the steps stick out), so the normal pass succeeds; the fallback is now rarely used |
| Stripes on curved walls | Shadow acne when injecting the lamp's light: shadow rays grazed the neighbouring steps | Shadow rays start 2.4 voxels off the surface |

The `images/closeup_voxel_albedo_*.jpg` images are the same scene with `--voxel-albedo` (the old albedo source, all other fixes on):
the teeth along the wall edges are still there, which shows the albedo was the main cause. `images/closeup_*.jpg` are the new result.

## Cost

| (RX 9070 XT, tunnel, dynamic every frame) | Before this step | Now |
|---|---|---|
| 1280x720 | 1.75 ms | 1.60 ms |
| 1920x1080 | 2.40 ms | 2.19 ms |

Slightly cheaper (the 27-voxel albedo search is gone) even though the albedo render is an extra pass (about 0.06 ms; it is in the GI-off number too).
In a real game that second scene render is not free; a G-buffer would avoid it.

## Moving cart: is the light stable?

`--motion`: the cart moves 3 cm per frame; mean absolute luma change of the indirect-only view between consecutive frames (x1000):
2.8, 5.1, 5.3, 5.0, 5.3, 5.4, 4.6, 7.1, 5.1, 2.9, 3.5, 5.6, 3.8, 6.8, 4.1, 2.7. No clear period of 4 frames (a voxel is 12.5 cm), but there is
frame-to-frame variation; I did not build a stricter flicker test.

## Still not right

- **Round lobes of yellow around the cart base** in the indirect-only view (x10 gain): each probe 0.5 m apart shows as a lobe. Subtle at normal
  gain (a soft orange glow), but it is the probe spacing showing. Denser probes near moving objects, or a screen-space blur of the indirect light, would help.
- **Small dark wedges** at the wall base in the indirect-only view (a few pixels at normal gain): pixels whose usable probes all see zero light.
- **Fine grain** on the floor in the shadow of the cart.
- The albedo render is a stand-in for a G-buffer; the 2D tunnel is the only scene checked.


---

# Step 3d: the circles and the little squares

Problem after step 3c: a pattern of circles, and sometimes little squares, was still visible.

## What they were

| What you saw | Cause |
|---|---|
| **Circles** (lobes around the cart, rings on the floor) | The light near a surface was read from the world probes, which are 0.5 m apart. Each probe near a bright thing became a round lobe once interpolated |
| **Little squares** | A ray that hit a voxel read that single voxel's light, and a voxel is 12.5 cm: a 12.5 cm square on everything it lit |
| **Zigzag along the base of walls and the cart** (a first attempt at the fix made it worse) | Short per-pixel rays tested "hit / no hit" against the staircase of voxels, and the staircase became the zigzag |

## What changed

1. **Filtered voxel light.** A hit reads the light of the 8 surrounding surface voxels, weighted, not one voxel (`radiance.inc`). The squares are gone.
2. **Per-pixel near field.** Each pixel traces its own short ray (up to 0.5 m) and the world probes only start past that (`nearfield.comp`, `final.comp`). It is an extra "cascade 0" at one probe per pixel; the usual cascades start at 0.5 m.
   - Each pixel's ray goes in a different direction of a 6x6 tile (36 directions); the final gather adds up the 36 pixels around it, weighted by depth, normal and cosine. A ray that ends without hitting anything continues into the probes in the same direction.
3. **The near-field ray is a soft march, not a hit test.** It walks the voxels as a density field (trilinear occupancy, front-to-back, 14 steps), so the edge of a voxel step is a one-voxel ramp and the staircase averages out instead of becoming a zigzag.

## Result

Close-ups `images/closeup_*.jpg` (new) against `images/step3c_closeup_*.jpg` (before): the lobes on open floor and the squares are gone, the wall bases and the
cart base are smooth. Key `G` in the viewer switches the near field on and off to compare.

## Cost (RX 9070 XT, 1920x1080, dynamic every frame)

| Pass | ms |
|---|---|
| Dynamic voxels + light injection | 0.24 |
| Probe cascades (start at 0.5 m) | 0.57 |
| Per-pixel near-field rays | 0.18 |
| Final gather (36 taps) | 0.50 |
| **GI total (GPU)** | **about 1.5** |

Viewport GPU time was 1.78 ms (dynamic) against 1.85 ms in step 3c; the near field replaced the old per-pixel probe gather (0.83 ms) and is slightly cheaper.
Wall-clock frame times on this machine moved a lot between runs (the GI-off frame measured 0.55 to 0.98 ms), so I trust the GPU numbers more.

## Still not right

- **Dirt-like smudges in the cart's shadow and slight bands on its sides.** A pixel only has 36 directions (18 above the surface); next to a bright thing and a dark thing the average is
  noisy. Temporal accumulation (reproject the last frame's result) is the usual cure and is not done.
- **Faint horizontal scan lines** in the indirect-only view (x10 gain) on the floor near the left wall: the 6x6 tile pattern showing; barely visible at normal gain.
- **Less stable while the cart moves:** mean frame-to-frame change of the indirect-only view is 4.0 to 11.7 (x1000) against 2.7 to 7.1 before (`--motion`), with one spike. The new
  per-pixel directions change the pattern as things move.
- A one-pixel dotted line along some creases (floor/wall, crate top edge).
- Only the tunnel was checked (close-ups of four spots).


---

# Step 3e: flicker while the cart moves, contact shadow, leaks

Problem after step 3d: small squares flickered while the cube moved, the contact shadow had gaps and light leaked.

## Where the flicker was (measured, not guessed)

`--motionmaps` renders two frames with the cart 3 cm apart and writes where they differ (x8). Godot alone (`images/step3e_diff_godot_only.jpg`) changes only
along the edges of the moving cart and its shadow, as it should. With the effect (`images/step3e_diff_world.jpg`) the static background is quiet but the
**cart's faces and the floor around its base** also changed, in soft blotches: the per-pixel near-field light (36 directions per pixel) was
different from one frame to the next. The horizontal stripes in the contact shadow had the period of the 6x6 tile of directions.

## What changed

**Temporal accumulation** (`final.comp`):

- the 6x6 tile of directions is **shifted every frame** (an R2 low-discrepancy offset), so a pixel looks in other directions each frame;
- the result is blended with last frame's, **reprojected** to where that world point was (previous view-projection) and validated by depth and normal, weight of the new frame 0.2 (`temporal_alpha`);
- keys: `T` turns it on and off in the viewer.

| Cart moving 3 cm per frame, indirect-only view, mean change between frames x1000 | before | now |
|---|---|---|
| range over 16 frames | 4.0 to 11.7 | **2.5 to 4.4** |

The horizontal stripes in the contact shadow are gone (`images/step3e_c_contact_world.jpg`).

## Light leaks: what I tested

- **Through a wall:** the camera looks at the outer face of the tunnel wall with the cart lamp just inside (`--leak`). The indirect light on the outer
  face measured **0.0** (x1000); Godot alone and with the effect read the same (15.8, just the ambient). No leak through the wall.
- **Corners:** the wall/floor corners and crate edges show no light seeping through in the close-ups.
- **I could not reproduce what you saw as "leaking"** at the cart's contact. What I do see there: the floor inside the cart's shadow is lifted by bounce light (it is
  not pure black as in Godot alone: that is the bounce, which is correct), and a thin dark line at the base of the cart is broken in places.

## Cost (RX 9070 XT, 1920x1080, dynamic every frame)

Viewport GPU time 1.71 ms (1.78 ms before); the temporal pass reads and writes two more screen-sized images and costs about nothing measurable on top of the final gather.

## Still not right

- **A dark smudge on the cart's front face near the floor** that moves from frame to frame (bright spot in the difference map): rays from there hit the shadowed floor.
- **Temporal lag:** the new frame has weight 0.2, so a light that moves fast is followed over about 5 frames. `temporal_alpha` trades smoothness for lag.
- **Ghosting on fast motion** is limited only by the depth/normal check; I did not test a fast camera.
- The thin dark contact line under the cart is still not continuous.


---

# Step 3f: lights popping on and off around the moving cube

Problem after step 3e: around the moving cube, lights seemed to switch off and on and the shadow did not follow it.

That description is accurate: every probe of the world grid is a fixed "light" at a map position, and several things switched them on and off, or in steps, as the cube passed.

## Measuring it (`--pop`)

The cart drives 2 cm per frame beside 15 fixed floor points (never over them) and the indirect-only brightness of each is read every frame. A smooth world gives a smooth
curve; popping gives steps. Reported: mean and max of the second difference (the roughness of the curve), x1000, signal about 760.

| | before (step 3e) | now |
|---|---|---|
| temporal ON, mean / max \|d2\| | 0.47 / 31.1 | **0.38 / 2.2** |
| temporal OFF, mean / max \|d2\| | 2.97 / 112.8 | **1.62 / 8.2** |

Before, one floor point jumped by +10% in a single frame (783 -> 862) and stayed there: that is a probe ray starting to hit the cart. Now the same point rises smoothly (802, 803, 804 ... 819).

## Causes and fixes

| Cause | Fix |
|---|---|
| **A probe ray is a big slice of the probe** (16 directions per probe, 0.8 sr each) and "hit / no hit" turned a whole ray on in one frame | Probe rays march the voxels as a **soft density field** (trilinear occupancy, front to back) like the near-field rays: a ray that the cart starts to block is blocked over about a voxel of movement. What it does not absorb continues into the upper cascade or the sky |
| **A probe covered by the cart switched off** (binary "is this probe inside a solid" and a yes/no visibility test to the next cascade) | `probe_weights.comp`: the weights of the 8 neighbours of each probe are computed once per probe from continuous numbers (how open the neighbour is, how much of the path to it is free) and stored. A covered probe fades out |
| **The cart's occupancy snapped voxel by voxel** (12.5 cm) as it moved | Moving boxes are voxelized with the **fraction of each voxel they cover** (analytic, 4x4x4 samples per voxel) instead of "touched or not", so the occupancy changes continuously (`voxelize_boxes.comp`) |
| **Shadows in the injected light flipped voxel by voxel** | Inside the bounds of the moving objects the shadow is marched softly; elsewhere the exact voxel walk (`inject.comp`) |
| **A history that follows too slowly** | Adaptive temporal blend: the more the new frame differs from the reprojected history, the more of it is taken (`temporal_adaptive`); base weight 0.25 |

The three fixes in the first column were needed together; the biggest single drop came from the fractional box occupancy.

## Regression I introduced and fixed

The first version of the soft march let a little light through the thin tunnel wall: the outside face of the wall read **10.5** (it was 0.0). A thin wall, sampled every 9 cm,
can fall between samples when occupancy is only a ramp; `OCC_GAIN = 2.5` makes the absorption firmer. Outer face is **0.0** again (`--leak`).

## Does the shadow follow the cube? (`--lag`)

The cart moves 5 cm per frame (3 m/s at 60 FPS) past floor points 25 cm from its side; the indirect-only brightness is compared with the same frames without temporal smoothing
(noisy but not delayed):

| Temporal setting | mean difference / level |
|---|---|
| fixed weight 0.2 | 0.87 % |
| adaptive, base 0.2 | 0.77 % |
| adaptive, base 0.4 | 0.44 % |

All below 1%: the smoothing is not what made the shadow look late. The Godot cast shadow itself follows the cube exactly (it is Godot's, and the difference map shows it
only at the cube's edge). Because popping is gone, the effect's own dark area around the base now moves with the cube.

## Cost (RX 9070 XT, 1920x1080, dynamic every frame)

| Pass | ms |
|---|---|
| Dynamic voxels + light injection | 0.09 (was 0.22) |
| Cascades (soft march, soft weights) | 1.09 |
| Near-field rays | 0.21 |
| Final gather + temporal | 0.59 |

**Read this with care:** these runs were done while something else was using the GPU (the same scene with GI off ran at about 200 FPS instead of more than 1000, and the cascades read
1.09 ms where the previous clean run read 0.55 ms), so the cascade and gather numbers are inflated by roughly 2x. The dynamic-voxel number is the one that changed for real:
a first version of the box voxelization ran on one thread per box and cost about 2 ms; one thread per voxel brought it to 0.09 ms. A clean re-measurement is still owed.

## Still not right

- A dark smudge on the cart's front face near the floor (rays from there hit the shadowed floor) is still present, though much calmer.
- Only boxes are voxelized with fractional coverage; a moving mesh of triangles would still snap.
- The `--motion` metric (whole image, indirect only) did not improve (3.2 to 5.3 against 2.5 to 4.4): it counts real changes too, and the adaptive blend now follows them faster.
  The per-point `--pop` test is the reliable one.


---

# Step 4: a real scene with real props (a 1999 grocery store)

Goal: a more complex scene with many props, closer to a real game level.

`--scene=shop` (`src/shop_scene.gd`, `.\scripts\run_shop.bat`): a 14 x 9.5 m store. The measurements below were made with ~250,000
triangles of detailed third-party props; the public version builds the same props from boxes of the same real-world sizes
(`KIT` in `src/shop_scene.gd`), so it runs with no external assets.

| Part | Props (box versions in the public scene) |
|---|---|
| Shell | floor slab + checker tiles (generated), walls with a darker lower band, ceiling, front wall with two windows and a door |
| Shelving | 18 `shelf_metal` gondolas (back wall + two islands, back to back), each level stocked with `biscuit_pack`, `rice_pack`, `guarana_2l`, `grocery_tins`, `cooking_oil`, `washing_powder` (about 230 items, LOD 1) |
| Counter | 2 `formica_counter`, `cash_register`, `scale_analog`, `tv_crt`, `wall_clock`, `storage_cabinet` |
| Cold | 2 `upright_fridge`, 2 `chest_freezer`, `water_cooler` |
| Floor clutter | `wire_display_rack` x2, `shopping_cart`, `shopping_basket` x2, `plastic_chair` x2, `step_ladder`, `bottle_crate` x3, `market_crate` x2, `carton` x4, `foam_cooler` |
| Light | 6 ceiling `fluorescent_fixture` with an `OmniLight3D` each (the middle one flickers), a sodium street lamp outside the windows |
| **Dynamic** | a **dolly** (board + 2 cartons + foam cooler + a work lamp on a pole) that rolls along the central aisle |

250,963 static triangles are voxelized (12.5 cm voxels, volume 15 x 4.5 x 10.5 m, 4 cascades, probes 0.5 m apart). The dolly's
props were detailed meshes; what the GI saw of them were invisible `BoxMesh` proxies (`rc_proxy`) of the same sizes, voxelized every frame with
fractional coverage. (In the public version the dolly is built from boxes, so the boxes themselves are voxelized.)

Images: `images/step4_*.jpg` (`shop_entrance_d2_off` is Godot alone, `..._world` adds the world-space bounce).

## What the props taught the effect

1. **Real meshes need per-surface albedo and textures.** `collect_triangles` used one colour per mesh; it now reads each surface's material, multiplies the albedo colour by the mean of the
   albedo texture (a 64x64 then 1x1 downsample, decompressing VRAM textures) and voxelizes surface by surface. The per-pixel albedo that is added to the light still comes
   from the unshaded render, so it is exact.
2. **The moving objects got their own volume.** Until now the box coverage was written into the same volume as the static geometry. A shadow ray is now the exact
   voxel walk through the static geometry multiplied by the soft transmittance through the moving objects' own coverage volume, so there is no switch between two ways of computing a shadow, and
   probes, near-field rays and cascades read the larger of the two occupancies.
3. **A moving prop is a proxy box.** A wire cart or a stack of cartons is not a box, but its light and shadow in the GI are those of its proxy. For the dolly the proxies are exact (cartons and a cooler are boxes).
4. **Per-frame collection stays cheap.** Walking the whole tree (hundreds of product nodes) every frame cost about 1.5 ms of CPU; the light and box nodes are now found once.

## Popping around the moving dolly (`--pop`, 20 floor points beside its path, 2 cm per frame)

| | mean / max second difference (x1000, signal about 780) |
|---|---|
| temporal ON | **0.70 / 7.5** |
| temporal OFF | 3.4 / 30 |
| temporal ON, dolly lamp OFF | 0.53 / 4.2 |

The steps are under 1% of the signal. (The first version of this test showed jumps of 25%: those were the **white bulb of the dolly's lamp** passing in front of the measured pixels,
not the lighting. The test now hides the bulb. The tunnel numbers did not change, 0.38 / 2.16, and the wall leak test still reads 0.0.)

## Cost (RX 9070 XT, 1920x1080, the store with 8 shadowed lights, dynamic every frame)

| | ms |
|---|---|
| Godot alone (viewport GPU) | 1.70 |
| Godot + world GI (viewport GPU) | 2.92 |
| of which: dynamic voxels + injection | 0.06 |
| cascades | 0.40 |
| near-field rays | 0.33 |
| final gather + temporal | 0.60 |

So the GI adds about 1.2 ms of GPU to this store. Caveat as before: another process was using the GPU part of the time, so absolute numbers are somewhat inflated; the split between passes is the reliable part.

## Not done / limits

- **Only box proxies move.** A person, an animated character or a swinging door would need proxies (or a coverage voxelizer for triangles).
- **Static props are voxelized once** at 12.5 cm: thin parts (the wire cart, shelf boards 3 cm thick) become blobs for the GI, though they are drawn correctly by Godot.
- Product albedo for the GI voxels is the texture average; it only affects the colour of the bounce, not what you see.
- 250 k triangles are collected in GDScript at start-up: a few seconds of load.
- Only one scene of this kind; I looked at five poses, not at every corner of the store.


---

# Step 5: a real control panel, a curved corridor, and a heat map of how light travels

Goal: a real control panel (buttons, settings, a reset), and a curved corridor off the store to see how light travels.

`.\scripts\run_shop.bat` now opens the store with a panel on the left (`src/ui_panel.gd`):

| Control | What it does |
|---|---|
| **Quote key (above Tab)** | frees the mouse to click the panel; press again to look around. A hidden/headless run never captures the real mouse. |
| Reset all to defaults / Low / Default / High | one click back to the starting values, or three quality presets |
| View buttons | Godot only, + world bounce, bounce only (x brighter), **bounce heat map**, screen-space (for comparison) |
| Go to | Entrance, Aisle, Counter, Island, Dolly, Corridor Mouth, Corridor Bend, Corridor End |
| Bounce light (live) | strength, bounce-only brightness, per-pixel near field on/off, range, directions per pixel, temporal smoothing and its weight, brightness clamp |
| Quality (re-voxelizes, then "Apply and rebuild") | voxel size (0.1 / 0.125 / 0.25 m), probe spacing, number of cascades |
| Lights and scene | exposure, ceiling lamps strength, flicker on/off, street lamp, **lamp inside the corridor (off by default)**, **sun through the windows**, dolly lamp, dolly rolls on/off |

Test: `--uitest` drives the panel like a user and checks it does not crash (`godot --path . -- --scene=shop --uitest`).
Result: defaults `voxel 0.125, probes 0.50, cascades 4, near dirs 6, alpha 0.25, strength 1.00`; the High preset changes them to `0.10 / 0.35 / 8`;
**Reset all** returns exactly to the defaults (also after moving a slider to 2.0).

## The corridor

A 3 m wide, 3.4 m high corridor leaves through an opening in the store's left wall: 6 m straight west, a left turn on a 5 m radius, then 8 m straight and closed at the end.
Right wall red, left wall teal, grey floor, no lamp: **the only light inside is what came from the store** (the optional corridor lamp is off). The GI volume grew to 28 x 4.5 x 19.25 m
(224 x 36 x 154 voxels). No cart inside.

## How the light travels (read from the images)

- `images/step5_ui_heat_corridor_mouth.jpg`: heat map (log scale, dark blue 0.0003 to white 3). The store is yellow/orange, the corridor is blue: bounce light **falls off quickly after the opening**.
- `images/step5_ui_corridor_mouth_world_gi.jpg`: bounce only, x4. The first metres are lit with the store's colours picked up from the floor and the walls (the red wall pushes a red tint on the floor beside it); behind the bend it is black.
- `images/step5_ui_corridor_bend_world_gi.jpg`: after the turn there is almost no light at x4. Raise "Bounce-only brightness" or switch on the corridor lamp to see weak light.

That is physically right for a 1-bounce-ish solution with a clamp: the light that enters through the opening hits the floor and the walls once and loses most of it; only the next cascades carry a little further.

## Limits

- The heat map is a debug view of the indirect light only (not the final picture).
- The corridor walls are thin meshes with a second face 0.25 m behind, so they are solid for the voxels. Light does not leak through them (the outer side stays dark in the heat map).
- Changing voxel size / probes / cascades re-voxelizes 250 k triangles and takes some seconds; the panel shows a "Rebuilding..." status while it does.


---

# Step 6: cheaper frames, an object picker, split view, a compact panel

Goals: make the per-frame work cheaper, move props with the mouse, compare with and without the effect side by side, and fit the
panel in less space.

## Static voxelization on the GPU

`collect_triangles` unpacked every triangle in GDScript into a float array before the GPU saw it. `collect_meshes` now hands the
GPU the meshes' own arrays: world-space vertices (one native multiply per surface), indices, and one record per surface;
`voxelize_mesh.comp` runs one thread per triangle of each surface. A surface's local arrays are cached the first time they are
read, because reading a primitive mesh (`BoxMesh`) builds its arrays on every call.

| | CPU triangles (before) | GPU meshes |
|---|---|---|
| Shop + `--dense` (431,452 triangles): gathering at start-up | 234 ms | 103 ms |
| Voxelize + light the volume | 14.4 ms | 7.1 ms |
| Gathering again after a prop moved (cache warm) | | 1.7 ms median, 2.4 ms max over 10 drags |

The second row is what makes dragging a prop with live bounce light possible.

## Re-lighting only what changed

The injection pass lit every voxel every frame. It now compares the light list and the moving boxes with the previous frame and
lights again only the union of: the reach of every light that changed (old and new position), the old and new bounds of the
moving objects, and the reach of every light that touches them (their shadows move inside it). Three voxels of margin cover the
normal estimate, which looks two voxels around. A directional light that changed, or that reaches a moving object, means the
whole volume.

| `--bench`, shop | before | after |
|---|---|---|
| Nothing moving (`--still`) | 0.282 ms | 0.005 ms |
| Dolly rolling, one light flickering | 0.294 ms | 0.332 ms |

When things move the region is almost the whole store (the flickering light reaches 9 m, the dolly lamp too), so there is no gain
there; the Stats tab shows the share re-lit each frame.

## Far cascades every other frame

Cascades from `far_from` (2) up are traced every `far_every` (2) frames; their merged result is copied into `_probe_keep` and the
nearer cascades merge with that copy on the frames in between. Cascades pass: 0.659 -> 0.527 ms still, 0.738 -> 0.673 ms with the
dolly rolling. The cost: light that reaches far changes up to one frame late.

## Panel, picker, split view

- The panel is now tabs (View, GI, Quality, Scene, Object, Stats), one line per slider.
- `src/object_picker.gd`: hover highlight (yellow overlay), click to select (blue overlay + a three-arrow gizmo drawn on top),
  drag an arrow to move along that axis (the mouse motion projected on the arrow as it appears on screen), rotation and colour in
  the Object tab, "Reset object". While dragging, the static scene is voxelized again every 0.1 s and once more on release.
- Split view: the final pass leaves the pixels left of a line as Godot drew them (`split`, sent in `screen.z`).
- Stats: GPU time per pass (averaged), the share of the volume re-lit, whether the far cascades were traced this frame.

Not tested with a real mouse: the picker and the split line were driven by the test harness (`--uitest`) in a hidden window.


---

# Step 7: one scene, clearer controls

- **One scene.** The tunnel, the street and the room are gone; the store already had everything they tested (a curved corridor,
  a moving object with a lamp, a lamp outside the windows, a flickering light). The tests that only existed for them (`--travel`,
  `--lag`, `--leak`, `--motion`, `--motionmaps`, `--closeups`, `--sweep`) went with them; their results above stay as they were
  measured, and the code is in the history.
- **Controls like an editor.** The lab starts with a free cursor; holding the right mouse button looks around, the mouse wheel
  sets the fly speed, the quote key switches to a game-like look mode. A coloured badge at the top always says the mode, and the
  controls are listed at the bottom right (H hides them).
- **Props.** Selection draws a screen-space outline, pixel exact (the prop alone in a mask, a full-screen pass draws the pixels around it); the gizmo has
  real arrows (a shaft and a cone each, drawn on top). Dragging the prop itself moves it over the floor, dragging an arrow moves it
  along one axis, F frames it.
- **Stuck input fixed.** A mouse button released over the panel never reached the scene (the panel takes the event), so "looking
  around" or a drag could stay on. The real button state is now read every frame; a prop only starts to move after the mouse
  travelled 5 px with the button down, so a click never nudges it.


---

# Step 8: jagged edges and a blocky bounce

Two complaints from a close view of a turned box next to the counter: a dashed line along its silhouette, and bounce light that
looked square, in vertical and horizontal lines. `--artifacts` renders the same close views with each fix on and off, camera
still and moving.

| What was seen | Cause | Fix |
|---|---|---|
| Dashed line along silhouettes | A pixel gathers the rays of the 6 x 6 pixels around it, one direction each. At an edge, the neighbours across it are rejected (other depth), so the pixel keeps part of the directions: a biased value that repeats every 6 px. The temporal blend cannot help there: the history is rejected at edges too. | **Clean edges**: when less than 3/4 of the window survived, gather again over a window two tiles wide. |
| A fine grid over every surface | The same 6 x 6 pattern of directions; the adaptive temporal blend took it for real change and kept accepting new frames. | **Edge-aware filter**: a 7 x 7 average of the bounce light over pixels of the same surface (depth and normal test, Gaussian). |
| A band of dark steps along the bottom of the turned box | The voxel copy of a surface that is not aligned with the grid is a staircase sticking out of it by up to a voxel; rays started inside it and shadowed their own surface. Fixed sampling also drew the voxel and probe grids into the light. | **Jitter**: random start of the samples along the ray and a random sideways offset of the probe lookup, new every frame; occupancy fades in over the first 1.5 voxels of the ray. |

Cost (RX 9070 XT, 1920x1080, nothing moving): final pass 0.72 -> 1.63 ms (edges ~0.5 ms, filter ~0.4 ms); whole frame 2.69 ms
(372 FPS) -> 3.62 ms (277 FPS). A cheaper edge test (re-gather below 1/2 instead of 3/4) saved 0.25 ms but let a few dashes back.

Not fixed: with the camera moving, a light dashed line remains where the box meets the floor (the history is rejected along that
edge every frame).
- **Looking around with split view.** With the mouse captured, Godot reports it at the centre of the screen, where the split-view
  line sits; the line took the motion and the camera did not turn. Camera look (right button, look mode, the quote key) is now
  handled in `_input`, before any control; `--uitest` checks both ways of looking with the line in the middle.
- **No flickering light.** The ceiling light that dipped now and then is gone (and its switch); all six fluorescents are steady.


---

# Step 9: High by default, and shimmer with a still camera

- **High is the default** (10 cm voxels, probes 0.35 m apart, 8 x 8 directions per pixel tile, weight of the new frame 0.2);
  `--quality=default` starts at the older settings. At 1920x1080 (RX 9070 XT, nothing moving): Godot alone 1.85 ms (541 FPS),
  with the effect at High 7.02 ms (142 FPS); at the older settings 6.33 ms (158 FPS). The extra cost of High is mostly the
  cascades (0.55 -> 1.62 ms) and the final pass (1.95 -> 2.96 ms: wider tiles).
- **Shimmer.** `--flicker` saves 16 consecutive frames with nothing moving, camera still and panning 1 cm per frame, and
  `tools/flicker_report.py` measures how much each pixel changes from frame to frame (the bounce light alone when the camera moves).
  Switching parts off one by one showed that neither the jitter nor the far cascades mattered; two things did:
  1. *The adaptive temporal blend* ("follow changes faster") took the normal noise of the per-pixel directions for real change.
     Now only the part of the difference above a noise floor (0.45, relative) counts, and only if it is not tiny in absolute terms.
  2. *The edge fallback* switched between the small and the wide window as the tile shifted, so edges flickered. The two results
     are now blended by how much of the small window survived, and edge pixels lean on the history.

| Pixels changing by more than 3 levels (of 255) | camera still | camera moving |
|---|---|---|
| Entrance view, before | 2.8 % | 4.1 % |
| Entrance view, after | 0.4 % | 2.0 % |
| Close view of the box, before | 0.5 % | 1.7 % |
| Close view of the box, after | 0.1 % | 1.4 % |

  The blend costs a little: final pass 1.63 -> 1.95 ms at the older settings (more edge pixels gather the wide window).


---

# Step 10: more bounces, glowing surfaces, a cheaper final pass, anti-aliasing

| Change | What it does | Measured (1920x1080, High, RX 9070 XT) |
|---|---|---|
| **Cheaper final pass** | The tile's direction table is computed once per group (it was recomputed for every neighbour) and the weights use plain multiplications. | Final pass 2.96 -> 1.93 ms; frame 7.02 -> 5.07 ms (142 -> 197 FPS). A first try that copied every group's pixels into shared memory was **three times slower** (8.93 ms: low occupancy, many duplicate loads) and was dropped. |
| **More bounces** | `ambient.comp` sums cascade 0 into an ambient cube per probe; the injection adds that irradiance, times the albedo and `bounce` (0.8), to every lit voxel, so the light bounces once more every frame. With it on, the whole volume is re-lit every 4th frame. | Bounce-only brightness +7-10 % in the store; at the corridor bend 1.0 -> 5.0 (0-255), dark pixels in the aisle 31 -> 46. Re-lighting 0.006 -> 0.10 ms with nothing moving. |
| **Glowing surfaces** | Emissive materials are voxelized with their emission into their own volume, added to the light of their voxels. A TV screen and a neon sign at the dark end of the corridor light their surroundings with no lamp. | Part of the re-lighting cost above. |
| **History-aware filter** | Each pixel keeps how many frames its history has; a short history is averaged over its frames so far and filtered twice as wide. | **No measurable gain**: pixels shimmering with the camera moving 2.27 % -> 2.22 % (noise). Left on: it costs nothing. |
| **Anti-aliasing** | Off, FXAA, SMAA, TAA (Godot's) or MSAA 4x in the Quality tab; **TAA is the default**. | Same cost within noise (5.21-5.36 ms). With a still camera TAA halves the shimmer (0.45 % -> 0.20 % of pixels); moving, the bounce light shimmers the same with SMAA and TAA (2.2 %). |


---

# Step 11: two new rooms, materials, a television that lights a dark room

- **Rooms.** A door in the corridor's right wall leads to a **materials room** (one lamp; chrome, gold, glossy plastic and plaster
  spheres, a copper box, a tinted glass pane) and through it to a **dark room** with no lamp: a television, a sofa, a rug.
- **Glass**: see-through materials (`TRANSPARENCY_*` with alpha below 0.95) are not voxelized, so light passes. No tint, no
  refraction.
- **Metal**: voxels store the diffuse colour (`albedo x (1 - metallic)`), so metals bounce no diffuse light; the composite drops
  their diffuse term too. Two more volumes hold metallic / roughness and the base colour per voxel.
- **Glossy reflections**: the near-field pass reads the probes of cascade 0 in the mirror direction, blending the 4 nearest of
  their 16 directions (a single nearest direction gave large square facets), and weights it with Schlick's Fresnel using the
  voxel's base colour. Two bugs found on the way, with debug views (`world_spec`, `world_metal`, `--mattest`): the material
  lookup missed many pixels of a curved surface (it now searches up to four voxels inwards), and the Fresnel colour came from the
  unshaded render, where Godot draws a metal nearly black, so metals reflected nothing. A few dark specks remain.
- **A television**: its screen is a moving box (like the dolly) whose emission is voxelized every frame into a volume of its own,
  so its slowly changing colour lights the dark room at once. The cross-fade never flashes.
- Cost not measured: the lab window was open on the same GPU during these runs (Godot alone measured 6.7 ms instead of 1.7 ms).
  The near-field pass, where the reflections were added, measured the same as before (0.36 ms).


---

# Step 12: one rule for every wall

The walls had been placed piece by piece, each with its own sizes: 30 cm walls in the store and 25 cm in the corridor, a store
ceiling slab that hung 15 cm below the ceiling height (the fluorescent fixtures were buried in it), tile bands stuck 4 cm out of
the walls, corners owned by two walls at once, and a door in the corridor cut by skipping 20 cm slices of the wall mesh, so its
edges did not line up with the lintel above it and the hollow wall showed through the gap.

The building is now declared as rooms and openings and painted on a 5 cm grid (`room()`, `opening()`, `passage()`,
`build_plan()` in `src/shop_scene.gd`):

1. every wall of every room, 30 cm thick, from the underside of the floor slab to the top of the ceiling slab;
2. each room repaints the inner half of its walls, so a wall between two rooms has each room's colour on its own side;
3. the tile band is a 5 cm strip of the wall itself, flush with it;
4. floor and ceiling slabs fill the inside of every room, at the same heights everywhere;
5. openings are cut through what is there, so jambs, sill and lintel come out of the wall.

Each maximal rectangle of equal grid cells becomes one box per solid layer, so boxes never overlap. The bend of the corridor
sweeps the same cross-section round the quarter circle with smooth curved faces and meets the straight runs face to face. The
dark room now stops one wall short of the corridor, so the bend never grazes its wall.

`--buildtest` checks it: every pair of box faces that point the same way, lie in the same plane and overlap (what z-fights),
and every pair of overlapping building boxes, then photographs the joints. Before: **242** coplanar overlapping face pairs (most
in the props: shelves as wide as their uprights, the sofa's back and seat). After: **0**, and 0 overlapping building boxes
(68 boxes for the whole building).


---

# Step 13: no light behind the television

The wall behind the dark room's television had a bright halo hugging the set's outline, although no light can reach it from the
screen. Two causes, both from the voxels:

1. **Objects were hollow.** The voxelizer marked only the voxels the triangles touch, so a 45 cm television, a 30 cm wall or a
   slab was a shell with an empty inside. Probes inside it were live and saw the inner faces; the normal of a shell voxel was
   pulled towards the empty inside. Now every closed mesh (each edge shared by exactly two triangles) is filled: the
   voxelizer adds a +1 / -1 winding step where each column of voxel centres enters or leaves it, and `fill_solid.comp` sums
   them along x. The inside of overlapping or touching objects comes out right. The bend of the corridor got end caps so it is
   closed too. Solid voxels: 244,173 -> 416,683. The scene got about 10 % brighter (dark probes inside walls no longer
   averaged in).
2. **A voxel's light went every way.** A voxel holds one colour, so the edge of the glowing screen was as bright seen from behind
   or from above as from the front, and the wall behind the set saw it past the edges of the cabinet. `inject.comp` now writes
   the surface normal it already computes into a new volume, and the rays of the cascades and the near field weight a voxel's
   light by the side it is seen from (`facing_weight`); occlusion is unchanged. This one removed the halo.

`--hollow` and `--no-facing` switch each one off for A/B. Cost (1920x1080, High, still): 5.01 -> 5.00 ms of GPU for the effect
(200 FPS), voxelizing 1.0 -> 1.4 ms.


---

# Step 14: smooth metal spheres, no black specks

Seen close, the chrome and gold spheres were a mosaic of facets with black triangles on them. Three causes:

1. **Facets**: the reflection direction came from the normal rebuilt from the depth buffer, which is flat per triangle (the
   sphere has 48 x 24 segments). The effect now asks Godot for its `normal_roughness` buffer (`needs_normal_roughness`), whose
   normals are interpolated across the triangles, and turns the reflection with it; where it disagrees strongly with the
   depth normal (an edge) the depth normal is kept.
2. **Black triangles**: the material lookup started 2.5 cm inside the surface. Wherever a facet runs close to a voxel
   boundary, that point is already in the inside of the object, which is solid but carries no material, so the whole facet
   was taken for a non-metal, whose colour in Godot's unshaded render is black. The search now starts on the surface
   (0, +0.2, -0.15, +0.45, +0.8 voxels). Black holes inside the metal in the `world_metal` view: 138 px -> 0.
3. **A seam across the reflection**, once the facets were gone: the blend of the 4 nearest directions clamped at the border
   of the probes' octahedral map, where the map folds. Cells past the border now wrap to the mirrored cell.
