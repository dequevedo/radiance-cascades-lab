// Screen-space outline, pixel exact: the selected (and the hovered) prop is drawn alone into a mask the size of the screen;
// a pixel outside the mask that has a mask pixel within `*_px` pixels becomes outline. Drawn over the scene, through walls too.
shader_type canvas_item;

uniform sampler2D sel_mask : filter_nearest;
uniform sampler2D hov_mask : filter_nearest;
uniform bool sel_on = false;
uniform bool hov_on = false;
uniform vec4 sel_color : source_color = vec4(1.0, 0.55, 0.1, 1.0);
uniform vec4 hov_color : source_color = vec4(1.0, 0.9, 0.35, 1.0);
uniform int sel_px = 3;
uniform int hov_px = 2;

bool near_mask(sampler2D m, ivec2 p, int r) {
	ivec2 size = textureSize(m, 0);
	if (texelFetch(m, clamp(p, ivec2(0), size - 1), 0).a > 0.5) {
		return false; // inside the prop: no outline over it
	}
	for (int y = -r; y <= r; y++) {
		for (int x = -r; x <= r; x++) {
			if (x * x + y * y > r * r) {
				continue; // a round brush: the corners of the outline are rounded, not square
			}
			if (texelFetch(m, clamp(p + ivec2(x, y), ivec2(0), size - 1), 0).a > 0.5) {
				return true;
			}
		}
	}
	return false;
}

void fragment() {
	ivec2 p = ivec2(FRAGCOORD.xy);
	COLOR = vec4(0.0);
	if (sel_on && near_mask(sel_mask, p, sel_px)) {
		COLOR = sel_color;
	} else if (hov_on && near_mask(hov_mask, p, hov_px)) {
		COLOR = hov_color;
	}
}
