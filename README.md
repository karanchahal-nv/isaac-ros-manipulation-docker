# Isaac ROS Manipulation — Custom Docker Layers

Custom Docker image layers for [Isaac ROS Manipulation](https://nvidia-isaac-ros.github.io/reference_workflows/isaac_for_manipulation/tutorials/setup/setup_guide_isaac_sim.html) development environments.

## Two Dockerfiles

### `Dockerfile.manipulation` — Full Custom Layer (for Isaac ROS CLI)
Designed to be used as an `additional_image_key` in the Isaac ROS CLI's layered build system. Starts `FROM ${BASE_IMAGE}` (the CLI's base isaac_ros image) and adds apt packages for the manipulation stack via `known_deps.txt`.

**Use when:** You have the full Isaac ROS CLI flow working (vanilla host, overlay2 driver).

### `Dockerfile.manipulation-light` — Standalone Lightweight Image
Self-contained image starting from `nvcr.io/nvidia/base/ubuntu:noble-20251013`. Installs ROS 2 Jazzy + all manipulation rosdep dependencies. No CUDA, no PyTorch, no TensorRT — just what's needed for rosdep + CPU-only colcon builds (gripper, serial, topic_based_ros2_control).

**Use when:** Running on resource-constrained environments (DGXC k8s pods, CI, or anywhere the full NGC image is too heavy).

**Image size:** ~3.3 GB (vs 20+ GB for the full isaac_ros image)

## Files

| File | Description |
|------|-------------|
| `Dockerfile.manipulation` | CLI layer — `FROM ${BASE_IMAGE}`, installs apt deps from `known_deps.txt` |
| `Dockerfile.manipulation-light` | Standalone — Ubuntu Noble + ROS 2 Jazzy + manipulation deps |
| `known_deps.txt` | Apt packages for the manipulation stack (MoveIt, ros2-control, gripper deps, etc.) |
| `.isaac-ros-cli-config.yaml` | Workspace-level Isaac ROS CLI config override |
| `scripts/build_custom_layer.sh` | Build script with resource checks and dry-run mode |
| `scripts/restore_container.sh` | Restore/create a container from the best available image |

## Quick Start

### Vanilla Host (overlay2, standard flow)

```bash
# Place files in your workspace
cp Dockerfile.manipulation ${ISAAC_ROS_WS}/docker/
cp known_deps.txt ${ISAAC_ROS_WS}/docker/
mkdir -p ${ISAAC_ROS_WS}/.isaac-ros-cli
cp .isaac-ros-cli-config.yaml ${ISAAC_ROS_WS}/.isaac-ros-cli/config.yaml

# Build via CLI
isaac-ros activate --build-local
```

### DGXC / K8s Pod (VFS driver)

Don't use the pre-built images — VFS duplicates them on startup and k8s kills the container. Instead, start from a tiny base and install incrementally:

```bash
docker run -d --name isaac_ros_dev \
  --network host --ipc=host \
  -v "${HOME}/workspaces/isaac_ros-dev:/workspaces/isaac_ros-dev" \
  -e DEBIAN_FRONTEND=noninteractive \
  -w /workspaces/isaac_ros-dev \
  ubuntu:24.04 sleep infinity

# Then install packages step by step (see full recipe in isaac-claw skill docs)
```

See the [isaac-claw repo](https://github.com/karanchahal-nv/isaac-claw) for the full DGXC-specific setup guide.

## Packages Installed (known_deps.txt)

- **MoveIt:** moveit, planners, servo, configs
- **ros2-control:** controller-manager, joint-trajectory-controller, forward-command-controller
- **Perception:** cv-bridge, image-transport, depth-image-proc, stereo-image-proc
- **Robot description:** xacro, URDF, robot-state-publisher, joint-state-publisher
- **Middleware:** rmw-cyclonedds-cpp
- **Gripper:** serial-driver, io-context
- **Build tools:** colcon, rosdep, vcstool, cmake

## Colcon Build Compatibility

| Package | CPU-only | Needs CUDA |
|---------|----------|------------|
| robotiq_controllers | ✅ 5.8s | |
| robotiq_driver | ✅ 5.8s | |
| robotiq_description | ✅ 1.1s | |
| serial | ✅ 0.3s | |
| topic_based_ros2_control | ✅ | |
| isaac_ros_manipulation_bringup (source) | | ✅ TensorRT |

For manipulation bringup without CUDA, use the apt binary: `sudo apt-get install -y ros-jazzy-isaac-ros-manipulation-bringup`

## License

See individual upstream licenses for Isaac ROS, ROS 2, and associated packages.
