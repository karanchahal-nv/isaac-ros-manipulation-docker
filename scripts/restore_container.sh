#!/usr/bin/env bash
# restore_container.sh — Restore/create Isaac ROS manipulation container
#
# Creates a persistent container from either:
#   - A cached committed image (isaac_ros_dev_built or isaac_ros_manipulation)
#   - The original pulled Isaac ROS base image
#
# Usage:
#   ./restore_container.sh [--image IMAGE] [--name NAME] [--dry-run]
#
# Options:
#   --image IMAGE   Use a specific Docker image (default: auto-detect)
#   --name NAME     Container name (default: isaac_ros_dev)
#   --dry-run       Show what would be done without executing
#   --force         Remove existing container even if running
#   --help          Show this help

set -euo pipefail

# ─── Configuration ───
ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev}"
CONTAINER_NAME="isaac_ros_dev"
IMAGE=""
DRY_RUN=false
FORCE=false

# RAM limits (DGXC)
RAM_LIMIT_GB=16

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Argument parsing ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)    IMAGE="$2"; shift 2 ;;
        --name)     CONTAINER_NAME="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --force)    FORCE=true; shift ;;
        --help|-h)
            head -16 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helper functions ───
log()  { echo -e "${GREEN}[RESTORE]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

run_or_dry() {
    if $DRY_RUN; then
        info "[DRY-RUN] Would run: $*"
    else
        "$@"
    fi
}

# ─── Checks ───
if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    err "Docker not available. Start with: sudo dockerd &>/tmp/dockerd.log &"
    exit 1
fi

# ─── Auto-detect image ───
if [[ -z "$IMAGE" ]]; then
    log "Auto-detecting best available image..."

    # Priority order:
    # 1. Committed built image (has all deps pre-installed)
    # 2. Custom manipulation layer (has apt deps, needs colcon build)
    # 3. Original Isaac ROS base image (needs everything)
    for candidate in \
        "isaac_ros_dev_built:latest" \
        "isaac_ros_manipulation:latest" \
        "nvcr.io/nvidia/isaac/ros:isaac_ros_28556f8bc78a98822bd08b2d7c6fcf9b-amd64"; do
        if docker image inspect "$candidate" &>/dev/null; then
            IMAGE="$candidate"
            break
        fi
    done

    if [[ -z "$IMAGE" ]]; then
        err "No suitable Isaac ROS image found. Build or pull one first."
        err "  Option 1: ./build_custom_layer.sh"
        err "  Option 2: isaac-ros activate"
        err "  Option 3: docker pull nvcr.io/nvidia/isaac/ros:..."
        exit 1
    fi
    log "  Using image: $IMAGE"
fi

# ─── Handle existing container ───
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        if $FORCE; then
            warn "Stopping running container: $CONTAINER_NAME"
            run_or_dry docker stop "$CONTAINER_NAME"
        else
            log "Container '$CONTAINER_NAME' is already running."
            log "  Enter it with: docker exec -it $CONTAINER_NAME bash"
            exit 0
        fi
    fi
    log "Removing existing stopped container: $CONTAINER_NAME"
    run_or_dry docker rm -f "$CONTAINER_NAME"
fi

# ─── Ensure workspace exists ───
mkdir -p "${ISAAC_ROS_WS}/src"

# ─── RAM check ───
AVAIL_RAM=$(awk '/MemAvailable/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
if [[ "$AVAIL_RAM" -lt 4 ]]; then
    warn "Low RAM: ${AVAIL_RAM} GB available (limit: ${RAM_LIMIT_GB} GB)"
    warn "colcon builds inside the container may OOM. Consider:"
    warn "  - Building one package at a time"
    warn "  - Adding --parallel-workers 1 to colcon build"
fi

# ─── Create container ───
log "Creating container: $CONTAINER_NAME"
log "  Image: $IMAGE"
log "  Workspace: $ISAAC_ROS_WS → /workspaces/isaac_ros-dev"

run_or_dry docker run -d \
    --name "$CONTAINER_NAME" \
    --runtime=nvidia --gpus all --privileged \
    --network host --ipc=host \
    -v "${ISAAC_ROS_WS}:/workspaces/isaac_ros-dev" \
    -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    -e ISAAC_ROS_ACCEPT_EULA=1 \
    -e MANIPULATOR_INSTALL_ASSETS=1 \
    -e FOUNDATIONSTEREO_MODEL_RES=low_res \
    -e ISAAC_MANIPULATOR_WORKFLOW_CONFIG_DIR=/workspaces/isaac_ros-dev/src/isaac_ros_manipulation/isaac_ros_manipulation_bringup/params \
    -w /workspaces/isaac_ros-dev \
    "$IMAGE" \
    sleep infinity

echo ""
log "═══════════════════════════════════════════════"
log "  Container ready: $CONTAINER_NAME"
log ""
log "  Enter it:  docker exec -it $CONTAINER_NAME bash"
log ""
log "  Inside, run:"
log "    source /opt/ros/jazzy/setup.bash"
log "    source install/setup.bash  # if previously built"
log "    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
log "═══════════════════════════════════════════════"
