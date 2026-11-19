# VAP-TAMP remote image

The image holds everything the workstation needs to run `vlm-tamp/eval_real_robot.py`. The robot side (Segway bridge, ZMQ server) is not included.

## Build

```bash
git lfs pull                        # the Detic metadata .npy files and URDF meshes are LFS
DOCKER_BUILDKIT=1 docker build -t vap-tamp:remote .
# or: docker compose -f docker/compose.yaml build
```

Build args you may want to change:

| Arg | Default | Notes |
| --- | --- | --- |
| `TORCH_CUDA` / `CUDA_IMAGE` | `cu118` / `nvidia/cuda:11.8.0-devel-ubuntu22.04` | Change both together (e.g. `cu121` + `12.1.1-devel`). cu118 needs host driver ≥ 520. |
| `TORCH_CUDA_ARCH_LIST` | `6.0;…;9.0+PTX` | Set it to your GPU only (e.g. `8.6`) to speed up the detectron2 compile. |
| `FD_VERSION` | `23.06` | Matches the vendored `vlm-tamp/downward`. |

## Run

```bash
export GEMINI_API_KEY=...
docker compose -f docker/compose.yaml run --rm remote \
  python eval_real_robot.py --robot-ip <ROBOT_IP> --map-file /maps/<map>.pkl \
    --domain domains/bottle_collection/domain.pddl \
    --problem domains/bottle_collection/problem.pddl \
    --api-key "$GEMINI_API_KEY" --location-map location_mapping.yaml \
    --config rosbridge_robot_config.yaml --calibration simple_offset_calibration.yaml
```

The container needs three things:

- `--network host`: ZMQ ports 4401–4404 and ROS 2 DDS discovery.
- `--ipc host`: Fast DDS shared memory.
- `--gpus all`.

Pass `ROS_DOMAIN_ID` through if your bridge uses a different one. The first run downloads the Detic checkpoint, CLIP, SigLIP and DINOv2 into the `vap-cache` volume.

**Dev mode:** uncomment the repo bind mount in `compose.yaml`. The entrypoint links `downward/builds`, `VAL/build/linux64/Release/bin` and `Detic/models` into your checkout only where they are missing.

## Updating Python deps

Edit `requirements-remote.in`, then regenerate the lock:

```bash
uv pip compile docker/requirements-remote.in --python-version 3.10 \
  --python-platform x86_64-manylinux_2_35 --no-header --no-annotate \
  | grep -vE '^(torch|torchvision|triton|nvidia-[a-z0-9-]+)==' > /tmp/body
# keep the header comment of requirements-remote.lock.txt, replace the rest with /tmp/body
```
