#! /usr/bin/bash

xhost +local:

docker run -it \
  --rm \
  --gpus all \
  --network host \
  --ipc host \
  -v /home/salaj/robotics/vap-tamp/data:/data:ro \
  -v /home/salaj/robotics/vap-tamp/outputs:/outputs:rw \
  -v /home/salaj/robotics/vap-tamp/VAP-TAMP:/workspace/VAP-TAMP \
  -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" \
  -e GEMINI_API_KEY \
  -e DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  vap-tamp:remote bash