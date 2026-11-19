# syntax=docker/dockerfile:1.7
#
# VAP-TAMP remote / workstation image
# ----------------------------------
# Runs vlm-tamp/eval_real_robot.py (Gemini grounding + Fast Downward + VAL + stretch_ai
# perception/navigation client + UR5e ROS 2 client). Robot-side code is NOT included.
#
# Stages
#   downward   prebuilt Fast Downward 23.06 (aibasel/downward) -> only the release binaries
#   val        VAL "Validate" built from the vendored vlm-tamp/VAL source (no upstream image)
#   detectron2 detectron2 wheel built with CUDA from the commit stretch_ai 0.3.0 pins
#   pyenv      Python 3.10 venv (uv) with torch cu118 + all remote Python deps
#   runtime    ros:humble-ros-core + venv + binaries + repo source   <-- final image

ARG ROS_DISTRO=humble
ARG FD_VERSION=23.06
ARG CUDA_IMAGE=nvidia/cuda:11.8.0-devel-ubuntu22.04
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13

# PyTorch build matching stretch_ai/install.sh (torch 2.3.1, CUDA 11.8, Python 3.10)
ARG TORCH_VERSION=2.3.1
ARG TORCHVISION_VERSION=0.18.1
ARG TORCH_CUDA=cu118
# GPU archs for detectron2's CUDA ops (Pascal .. Hopper; +PTX for forward-compat)
ARG TORCH_CUDA_ARCH_LIST="6.0;7.0;7.5;8.0;8.6;8.9;9.0+PTX"

# NOTE: since `/data` in .gitignore we have to resolve
# detectron2/data, Detic/detic/data and CenterNet2/centernet/data
ARG DETECTRON2_REF=c69939aa85460e8135f40bce908a6cddaa73065f

FROM ${UV_IMAGE} AS uv

###############################################################################
# Fast Downward: reuse the official prebuilt image, keep only what we need
###############################################################################
FROM aibasel/downward:${FD_VERSION} AS downward
# The vendored vlm-tamp/downward is release 23.06, so the 23.06 binaries match its driver.
# Collect: driver + release build (search binary + translator) + any SoPlex shared libs.
RUN set -eux; \
    mkdir -p /out/downward/builds/release /out/lib; \
    cp -a /workspace/downward/fast-downward.py /workspace/downward/driver /out/downward/; \
    cp -a /workspace/downward/builds/release/bin /out/downward/builds/release/; \
    ldd /workspace/downward/builds/release/bin/downward \
      | awk '/soplex/ {print $3}' | xargs -r cp -L -t /out/lib/

###############################################################################
# VAL: small CMake build from the vendored source
###############################################################################
FROM ubuntu:22.04 AS val
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake g++ make flex bison \
    && rm -rf /var/lib/apt/lists/*
COPY vlm-tamp/VAL /src/VAL
WORKDIR /src/VAL/build/linux64/Release
RUN cmake -DCMAKE_BUILD_TYPE=Release ../../.. \
    && make -j"$(nproc)" Validate \
    && strip --strip-unneeded bin/Validate bin/libVAL.so
# bin/Validate has RUNPATH=$ORIGIN, so bin/ is self-contained (Validate + libVAL.so)

###############################################################################
# detectron2 wheel (needs nvcc; FB only ships wheels for torch<=1.10)
###############################################################################
FROM ${CUDA_IMAGE} AS detectron2
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCH_CUDA
ARG TORCH_CUDA_ARCH_LIST
ENV DEBIAN_FRONTEND=noninteractive
ENV UV_NO_CACHE=1
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-dev git build-essential \
    && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never VIRTUAL_ENV=/opt/build PATH=/opt/build/bin:$PATH
RUN uv venv --seed /opt/build --python /usr/bin/python3 \
    && uv pip install --index-url https://download.pytorch.org/whl/${TORCH_CUDA} \
        torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} \
    && uv pip install setuptools==69.5.1 wheel ninja
ARG DETECTRON2_REF
RUN git init -q /src/detectron2 && cd /src/detectron2 \
    && git fetch -q --depth 1 https://github.com/facebookresearch/detectron2.git "$DETECTRON2_REF" \
    && git checkout -q FETCH_HEAD
ENV FORCE_CUDA=1 TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}
RUN cd /src/detectron2 \
    && MAX_JOBS="$(nproc)" python -m pip wheel --no-deps --no-build-isolation -w /wheels .

###############################################################################
# Runtime
###############################################################################
FROM ros:${ROS_DISTRO}-ros-core-jammy AS runtime

ARG ROS_DISTRO
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCH_CUDA
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-control-msgs ros-${ROS_DISTRO}-sensor-msgs \
        ros-${ROS_DISTRO}-trajectory-msgs ros-${ROS_DISTRO}-std-msgs \
        libgl1 libegl1 libglib2.0-0 libgomp1 libsm6 libxext6 libxrender1 \
        libportaudio2  python3-tk ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

# FIRST setup the python environment
ENV UV_NO_CACHE=1 UV_LINK_MODE=copy UV_COMPILE_BYTECODE=1 UV_PYTHON_DOWNLOADS=never \
    VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH

# NOTE: mount=type=bind creates a lasting copy in the final image
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    --mount=type=bind,source=docker/requirements.txt,target=/tmp/requirements.txt \
    --mount=type=bind,from=detectron2,source=/wheels,target=/tmp/wheels \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential python3-dev portaudio19-dev; \
    uv venv /opt/venv --python /usr/bin/python3; \
    uv pip install --index-url https://download.pytorch.org/whl/${TORCH_CUDA} \
        torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION}; \
    uv pip install -r /tmp/requirements.txt; \
    uv pip check; \
    uv pip install --no-deps /tmp/wheels/detectron2-*.whl; \
    rm -rf /var/lib/apt/lists/*
# Run a quick check to see if CUDA-enabled torch is installed
RUN python -c "import torch; from detectron2 import _C; assert '+${TORCH_CUDA}' in torch.__version__, torch.__version"

# Planner / validator binaries
COPY --from=downward /out/downward /opt/downward
COPY --from=downward /out/lib/ /usr/local/lib/
COPY --from=val /src/VAL/build/linux64/Release/bin /opt/val/bin
RUN ldconfig

# Setup final env vars + entrypoint.sh
ENV PYTHONPATH=/workspace/VAP-TAMP/stretch_ai/src:/workspace/VAP-TAMP \
    PYTHONUNBUFFERED=1 \
    FAST_DOWNWARD=/opt/downward/fast-downward.py \
    VAL_VALIDATE=/opt/val/bin/Validate \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/vap-entrypoint
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc

# TODO: create a symlink from project repo mount to 1GB files such as CLIP & SigLP

# Make sure to mount the workspace!
WORKDIR /workspace/VAP-TAMP
ENTRYPOINT ["/usr/local/bin/vap-entrypoint"]
CMD ["bash"]