# Isaac ROS Manipulation — Custom Docker Layer

A custom Docker image layer for [Isaac ROS Manipulation](https://nvidia-isaac-ros.github.io/reference_workflows/isaac_for_manipulation/tutorials/setup/setup_guide_isaac_sim.html) that pre-installs all rosdep/apt dependencies so you can skip the slow dependency resolution step every time you recreate a container.

## Requirements

- **NVIDIA GPU** with ≥8 GB VRAM (25 GB recommended for full perception stack)
- **Ubuntu 24.04** host (or Ubuntu 22.04 with Docker)
- **Docker** with `overlay2` storage driver (default)
- **nvidia-container-toolkit** installed
- **Isaac ROS CLI** installed (`sudo apt-get install isaac-ros-cli`)
- [`isaac-ros init docker`](https://nvidia-isaac-ros.github.io/getting_started/index.html) completed

## Quick Start

### 1. Set up your workspace

```bash
mkdir -p ~/workspaces/isaac_ros-dev/src
export ISAAC_ROS_WS="${HOME}/workspaces/isaac_ros-dev/"
echo 'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev/}"' >> ~/.bashrc
```

### 2. Clone source repos

```bash
cd ${ISAAC_ROS_WS}/src

# Robotiq gripper (NVIDIA fork — fixes upstream bugs + adds 2F-140 support)
git clone --recursive https://github.com/NVIDIA-ISAAC-ROS/ros2_robotiq_gripper.git

# Serial library (required by robotiq gripper)
git clone -b ros2 https://github.com/tylerjw/serial.git

# Isaac ROS Manipulation (from source, release-4.4)
git clone --recursive -b release-4.4 \
  https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_manipulation.git isaac_ros_manipulation

# Topic Based ROS2 Control (impedance controller support for sim-to-real)
git clone https://github.com/karanchahal-nv/topic_based_ros2_control
```

### 3. Install the custom Docker layer

```bash
# Copy files into your workspace
cp Dockerfile.manipulation ${ISAAC_ROS_WS}/docker/
cp known_deps.txt ${ISAAC_ROS_WS}/docker/

# Add workspace-level CLI config
mkdir -p ${ISAAC_ROS_WS}/.isaac-ros-cli
cp .isaac-ros-cli-config.yaml ${ISAAC_ROS_WS}/.isaac-ros-cli/config.yaml
```

### 4. Build and activate

```bash
cd ${ISAAC_ROS_WS}
isaac-ros activate --build-local
```

This builds the `manipulation` layer on top of the base `isaac_ros` image. First build takes a few minutes (apt downloads); subsequent runs use the cached image.

### 5. Build packages inside the container

Once inside the container (after `isaac-ros activate`):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ISAAC_ROS_ACCEPT_EULA=1
export MANIPULATOR_INSTALL_ASSETS=1
export FOUNDATIONSTEREO_MODEL_RES=low_res

# Build gripper + serial
colcon build --symlink-install \
  --packages-select-regex "robotiq*|serial" \
  --cmake-args "-DBUILD_TESTING=OFF"
source install/setup.bash

# Build manipulation bringup (downloads perception models — needs GPU)
rosdep install --from-paths src/isaac_ros_manipulation/isaac_ros_manipulation_bringup --ignore-src -y
pip install --no-deps --break-system-packages git+https://github.com/facebookresearch/segment-anything.git
colcon build --symlink-install --packages-up-to isaac_ros_manipulation_bringup
source install/setup.bash

# Build topic_based_ros2_control
rosdep install --from-paths src/topic_based_ros2_control --ignore-src -y
colcon build --symlink-install --packages-up-to topic_based_ros2_control
source install/setup.bash
```

### 6. Run pose-to-pose (with Isaac Sim)

**Terminal 1 (host):** Open Isaac Sim, load the manipulation scene:
```
https://omniverse-content-production.s3-us-west-2.amazonaws.com/Assets/Isaac/5.1/Isaac/Samples/ROS2/Scenario/isaac_manipulator_scene.usd
```
Hit Play.

**Terminal 2 (inside container):**
```bash
source /opt/ros/jazzy/setup.bash
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ISAAC_MANIPULATOR_WORKFLOW_CONFIG_DIR="${ISAAC_ROS_WS}/src/isaac_ros_manipulation/isaac_ros_manipulation_bringup/params"

ros2 launch isaac_ros_manipulation_bringup workflows.launch.py \
  manipulator_workflow_config:=${ISAAC_MANIPULATOR_WORKFLOW_CONFIG_DIR}/sim_launch_params.yaml
```

## Files

| File | Description |
|------|-------------|
| `Dockerfile.manipulation` | Custom layer for Isaac ROS CLI (`FROM ${BASE_IMAGE}`) — installs all rosdep deps |
| `known_deps.txt` | Apt packages for the manipulation stack (MoveIt, ros2-control, perception, gripper) |
| `.isaac-ros-cli-config.yaml` | Workspace config — adds `manipulation` to `additional_image_keys` |
| `scripts/build_custom_layer.sh` | Build script with resource checks and `--dry-run` mode |
| `scripts/restore_container.sh` | Restore/create a container from the best available image |

## What `Dockerfile.manipulation` installs

All rosdep-resolved apt dependencies for the manipulation stack:

- **MoveIt:** moveit, planners (OMPL), servo, configs, setup assistant
- **ros2-control:** controller-manager, joint-trajectory-controller, forward-command-controller
- **Perception:** cv-bridge, image-transport, depth-image-proc, stereo-image-proc, image-pipeline
- **Robot description:** xacro, URDF, robot-state-publisher, joint-state-publisher
- **Middleware:** rmw-cyclonedds-cpp
- **Gripper:** serial-driver, io-context
- **Build tools:** colcon, rosdep, vcstool, cmake
- **Python:** pyvers

This means `rosdep install` inside the container is essentially a no-op — all deps are already there.

## Colcon Build Reference

| Package | Build time | GPU required? |
|---------|-----------|---------------|
| robotiq_controllers | ~6s | No |
| robotiq_driver | ~6s | No |
| robotiq_description | ~1s | No |
| robotiq_hardware_tests | ~2s | No |
| serial | <1s | No |
| topic_based_ros2_control | ~12s | No |
| isaac_ros_manipulation_bringup | ~10-15 min | **Yes** (TensorRT model conversion) |

Set `FOUNDATIONSTEREO_MODEL_RES=low_res` to reduce GPU VRAM needed during TensorRT conversion from 16 GB to 8 GB.

## Advanced: Manual Docker Build (without Isaac ROS CLI)

If you prefer to build without the CLI:

```bash
# Get the base image name from NGC
BASE_IMAGE="nvcr.io/nvidia/isaac/ros:isaac_ros-amd64"
docker pull ${BASE_IMAGE}

# Build the custom layer
cd ${ISAAC_ROS_WS}/docker
docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  -t isaac_ros_manipulation:latest \
  -f Dockerfile.manipulation .

# Run
docker run -d --name isaac_ros_dev \
  --runtime=nvidia --gpus all --privileged --network host --ipc=host \
  -v "${ISAAC_ROS_WS}:/workspaces/isaac_ros-dev" \
  -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
  -e ISAAC_ROS_ACCEPT_EULA=1 \
  -w /workspaces/isaac_ros-dev \
  isaac_ros_manipulation:latest sleep infinity

docker exec -it isaac_ros_dev bash
```

## DGXC / K8s Users

If you are running inside a **Kubernetes pod** (e.g., NVIDIA DGXC), the standard Docker flow above will not work due to VFS storage driver constraints. See the [isaac-claw repo](https://github.com/karanchahal-nv/isaac-claw) for DGXC-specific workarounds, including the incremental installation recipe.

## Notes

- Set `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` in **every** terminal.
- The `topic_based_ros2_control` fork from `karanchahal-nv` includes impedance controller support required for sim-to-real workflows.
- If `ros2 control` packages have ABI issues, see [this issue](https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_manipulation/issues/18#issuecomment-3774203281) for version pinning.

## License

See upstream licenses for [Isaac ROS](https://github.com/NVIDIA-ISAAC-ROS), [ROS 2](https://docs.ros.org/en/jazzy/), and associated packages.
