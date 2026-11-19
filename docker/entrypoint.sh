#!/usr/bin/env bash
# VAP-TAMP remote entrypoint
#  1. loads ROS 2 (rclpy + msgs for the UR5e client)
#  2. checked that mounted repo exists and has Detic
#  3. runs the given command $@
set -e

# source "/opt/ros/${ROS_DISTRO}/setup.bash"

REPO=/workspace/VAP-TAMP
DETIC="$REPO/stretch_ai/src/stretch/perception/detection/detic/Detic"
CKPT="$DETIC/models/Detic_LCOCOI21k_CLIP_SwinB_896b32_4x_ft4x_max-size.pth"
META="$DETIC/datasets/metadata/lvis_v1_clip_a+cname.npy"

warn() { echo "[vap-entrypoint] warning: $*" >&2; }

if [ ! -d "$REPO/vlm-tamp" ]; then
    warn "repo not found at $REPO - mount it with: -v /path/to/VAP-TAMP:$REPO"
else
    [ -d "$DETIC/detic/data" ] \
        || warn "missing $DETIC/detic/data (Detic will fail to import)"
    [ -d "$DETIC/third_party/CenterNet2/centernet" ] \
        || warn "missing $DETIC/third_party/CenterNet2/centernet ('No module named centernet')"
    [ -d "$DETIC/third_party/CenterNet2/centernet/data" ] \
        || warn "missing $DETIC/third_party/CenterNet2/centernet/data"
    [ -f "$CKPT" ] \
        || warn "missing Detic checkpoint: $CKPT"
    if [ -f "$META" ] && head -c 64 "$META" | grep -q "git-lfs"; then
        warn "Detic metadata .npy files are Git LFS pointers - run 'git lfs pull' on the host"
    fi
fi

exec "$@"