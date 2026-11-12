#!/usr/bin/env bash
# Entrypoint for the VAP-TAMP remote image.
#  1. sources ROS 2 (rclpy + msgs for the UR5e client)
#  2. points the repo's relative tool paths at the binaries baked into the image:
#       vlm-tamp/downward/builds                -> /opt/downward/builds
#       vlm-tamp/VAL/build/linux64/Release/bin  -> /opt/val/bin
#     (pddl_sim.py calls ./downward/fast-downward.py and VAL/build/linux64/Release/bin/Validate)
#  3. makes sure the Detic checkpoint exists (downloaded once into the /cache volume)
# Links are only created when the path is missing, so a bind-mounted repo that already has
# its own builds / checkpoint is left alone.
set -e

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO}/setup.bash"

REPO="${VAP_TAMP_ROOT:-/workspace/VAP-TAMP}"

link_if_missing() {  # <target> <link>
    local target="$1" link="$2"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        mkdir -p "$(dirname "$link")" 2>/dev/null || true
        ln -s "$target" "$link" 2>/dev/null \
            || echo "[vap-entrypoint] warning: could not create $link (read-only mount?)" >&2
    fi
}

link_if_missing /opt/downward/builds "$REPO/vlm-tamp/downward/builds"
link_if_missing /opt/val/bin          "$REPO/vlm-tamp/VAL/build/linux64/Release/bin"

# Detic checkpoint (stretch_ai has no auto-download for it)
DETIC_NAME="Detic_LCOCOI21k_CLIP_SwinB_896b32_4x_ft4x_max-size.pth"
DETIC_URL="${DETIC_URL:-https://dl.fbaipublicfiles.com/detic/${DETIC_NAME}}"
DETIC_DIR="$REPO/stretch_ai/src/stretch/perception/detection/detic/Detic"
DETIC_MODELS="$DETIC_DIR/models"
DETIC_CACHE_DIR="${DETIC_CACHE_DIR:-/cache/detic}"

# A bind-mounted checkout may carry the fork's incomplete Detic copy (its .gitignore drops
# every data/ dir). The image's complete copy lives in /opt/detic.
if [ ! -d "$DETIC_DIR/detic/data" ]; then
    echo "[vap-entrypoint] warning: $DETIC_DIR/detic/data is missing;" \
         "Detic will fail to import. Copy it from /opt/detic/detic/data" \
         "(and /opt/detic/third_party/CenterNet2/centernet/data)." >&2
fi

if [ ! -f "$DETIC_MODELS/$DETIC_NAME" ] && [ "${SKIP_DETIC_DOWNLOAD:-0}" != "1" ]; then
    mkdir -p "$DETIC_CACHE_DIR"
    link_if_missing "$DETIC_CACHE_DIR" "$DETIC_MODELS"
    if [ ! -f "$DETIC_CACHE_DIR/$DETIC_NAME" ]; then
        echo "[vap-entrypoint] downloading Detic checkpoint into $DETIC_CACHE_DIR (one-time)..."
        tmp="$DETIC_CACHE_DIR/$DETIC_NAME.part"
        wget -q --show-progress -O "$tmp" "$DETIC_URL" || { rm -f "$tmp"; exit 1; }
        # the real checkpoint is several hundred MB; anything tiny is an error page
        if [ "$(stat -c %s "$tmp")" -lt $((100 * 1024 * 1024)) ]; then
            echo "[vap-entrypoint] Detic download looks wrong ($(stat -c %s "$tmp") bytes); not saving it" >&2
            rm -f "$tmp"; exit 1
        fi
        mv "$tmp" "$DETIC_CACHE_DIR/$DETIC_NAME"
    fi
fi

exec "$@"