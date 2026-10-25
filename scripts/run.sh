#!/usr/bin/env sh
# Opens the lab in a window. Set GODOT to your Godot 4.7 executable, or have "godot" on the PATH.
#   ./scripts/run.sh [--scene=tunnel|street|room|shop]
cd "$(dirname "$0")/.." && exec "${GODOT:-godot}" --path . --rendering-driver vulkan -- "$@"
