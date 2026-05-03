#!/usr/bin/env bash
# build_custom_layer.sh — Build custom Isaac ROS manipulation Docker layer
#
# This script:
#   1. Checks prerequisites (Docker, GPU, disk space, RAM)
#   2. Sets up workspace-level isaac-ros CLI config
#   3. Places the custom Dockerfile where the CLI can find it
#   4. Builds the custom layer (via CLI or manual fallback)
#   5. Monitors disk usage during build
#   6. Tags and caches the result
#
# Usage:
#   ./build_custom_layer.sh [--dry-run] [--manual] [--base-image IMAGE]
#
# Options:
#   --dry-run       Show what would be done without executing
#   --manual        Skip isaac-ros CLI, build directly with docker build
#   --base-image    Override the base image (default: auto-detect from CLI)
#   --help          Show this help

set -euo pipefail

# ─── Configuration ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev}"

# Resource limits (DGXC)
RAM_LIMIT_GB=16
DISK_MIN_FREE_GB=30
DISK_WARN_FREE_GB=50

# Defaults
DRY_RUN=false
MANUAL_BUILD=false
BASE_IMAGE=""

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Argument parsing ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --manual)   MANUAL_BUILD=true; shift ;;
        --base-image) BASE_IMAGE="$2"; shift 2 ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helper functions ───
log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
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

get_ram_gb() {
    awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo
}

get_available_ram_gb() {
    awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo
}

get_disk_free_gb() {
    local path="${1:-/var/lib/docker}"
    df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo "0"
}

get_disk_used_gb() {
    local path="${1:-/var/lib/docker}"
    df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$3); print $3}' || echo "0"
}

# ─── Step 1: Prerequisites check ───
log "═══════════════════════════════════════════════"
log "  Isaac ROS Manipulation — Custom Layer Build"
log "═══════════════════════════════════════════════"
echo ""

# Check Docker
log "Checking prerequisites..."
if ! command -v docker &>/dev/null; then
    err "Docker not found. Install Docker first (see SKILL.md Step 1-2)."
    exit 1
fi

if ! docker info &>/dev/null; then
    err "Docker daemon not running. Start with: sudo dockerd &>/tmp/dockerd.log &"
    exit 1
fi
log "  ✓ Docker is running"

# Check storage driver
STORAGE_DRIVER=$(docker info --format '{{.Driver}}' 2>/dev/null)
if [[ "$STORAGE_DRIVER" == "vfs" ]]; then
    warn "  ⚠ VFS storage driver detected — each image layer is a full copy!"
    warn "    Expect ~35-45 GB total disk usage for the manipulation stack."
else
    log "  ✓ Storage driver: $STORAGE_DRIVER"
fi

# Check GPU
if docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    log "  ✓ GPU accessible in Docker"
else
    warn "  ⚠ GPU not accessible in Docker (build will work, but container won't have GPU)"
fi

# Check RAM
TOTAL_RAM=$(get_ram_gb)
AVAIL_RAM=$(get_available_ram_gb)
log "  RAM: ${AVAIL_RAM} GB available / ${TOTAL_RAM} GB total (hard limit: ${RAM_LIMIT_GB} GB)"

AVAIL_RAM_INT=$(echo "$AVAIL_RAM" | cut -d. -f1)
if [[ "$AVAIL_RAM_INT" -lt 4 ]]; then
    err "  Less than 4 GB RAM available. Docker build may OOM. Aborting."
    err "  Free memory or stop other containers first."
    exit 1
elif [[ "$AVAIL_RAM_INT" -lt 8 ]]; then
    warn "  ⚠ Low RAM (${AVAIL_RAM} GB). Build may be slow. Consider stopping other processes."
fi

# Check disk space
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
DISK_FREE=$(get_disk_free_gb "$DOCKER_ROOT")
DISK_USED=$(get_disk_used_gb "$DOCKER_ROOT")
log "  Disk: ${DISK_FREE} GB free (${DISK_USED} GB used) at ${DOCKER_ROOT}"

if [[ "$DISK_FREE" -lt "$DISK_MIN_FREE_GB" ]]; then
    err "  Less than ${DISK_MIN_FREE_GB} GB free. Need space for build layers."
    err "  Clean up with: docker system prune -a"
    exit 1
elif [[ "$DISK_FREE" -lt "$DISK_WARN_FREE_GB" ]]; then
    warn "  ⚠ Less than ${DISK_WARN_FREE_GB} GB free. Build may run out of space."
    warn "    Consider cleaning: docker system prune"
fi

# Check workspace
if [[ ! -d "$ISAAC_ROS_WS" ]]; then
    warn "  Workspace not found at $ISAAC_ROS_WS — will create it"
    run_or_dry mkdir -p "${ISAAC_ROS_WS}/src"
fi
log "  ✓ Workspace: $ISAAC_ROS_WS"

echo ""

# ─── Step 2: Set up workspace config ───
log "Setting up workspace-level Isaac ROS CLI config..."

WORKSPACE_DOCKER_DIR="${ISAAC_ROS_WS}/docker"
WORKSPACE_CLI_DIR="${ISAAC_ROS_WS}/.isaac-ros-cli"

run_or_dry mkdir -p "$WORKSPACE_DOCKER_DIR"
run_or_dry mkdir -p "$WORKSPACE_CLI_DIR"

# Copy Dockerfile and deps to workspace docker/ directory
log "  Copying Dockerfile.manipulation → ${WORKSPACE_DOCKER_DIR}/"
run_or_dry cp "${SKILL_DIR}/docker/Dockerfile.manipulation" "${WORKSPACE_DOCKER_DIR}/Dockerfile.manipulation"
run_or_dry cp "${SKILL_DIR}/docker/known_deps.txt" "${WORKSPACE_DOCKER_DIR}/known_deps.txt"

# Copy workspace-level config
log "  Copying CLI config → ${WORKSPACE_CLI_DIR}/config.yaml"
run_or_dry cp "${SKILL_DIR}/docker/.isaac-ros-cli-config.yaml" "${WORKSPACE_CLI_DIR}/config.yaml"

echo ""

# ─── Step 3: Build the custom layer ───
if $MANUAL_BUILD || ! command -v isaac-ros &>/dev/null; then
    # ── Manual docker build fallback ──
    log "Building custom layer with docker build..."

    if [[ -z "$BASE_IMAGE" ]]; then
        # Try to detect the base image from existing Docker images
        BASE_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'isaac.*ros' | head -1)
        if [[ -z "$BASE_IMAGE" ]]; then
            err "No base image found. Specify with --base-image or pull first:"
            err "  isaac-ros activate  (or docker pull nvcr.io/nvidia/isaac/ros:...)"
            exit 1
        fi
        log "  Auto-detected base image: $BASE_IMAGE"
    fi

    log "  Base image: $BASE_IMAGE"
    log "  Context: $WORKSPACE_DOCKER_DIR"

    # Monitor disk in background during build
    if ! $DRY_RUN; then
        (
            while true; do
                sleep 30
                FREE=$(get_disk_free_gb "$DOCKER_ROOT")
                if [[ "$FREE" -lt 10 ]]; then
                    echo -e "${RED}[DISK ALERT] Only ${FREE} GB free! Build may fail.${NC}" >&2
                fi
            done
        ) &
        MONITOR_PID=$!
        trap "kill $MONITOR_PID 2>/dev/null || true" EXIT
    fi

    run_or_dry docker build \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        -t "isaac_ros_manipulation:latest" \
        -f "${WORKSPACE_DOCKER_DIR}/Dockerfile.manipulation" \
        "${WORKSPACE_DOCKER_DIR}"

    BUILD_EXIT=$?
    if ! $DRY_RUN; then
        kill $MONITOR_PID 2>/dev/null || true
    fi

    if [[ "${BUILD_EXIT:-0}" -ne 0 ]]; then
        err "Docker build failed with exit code $BUILD_EXIT"
        exit $BUILD_EXIT
    fi

    log "  ✓ Built: isaac_ros_manipulation:latest"
else
    # ── isaac-ros CLI build ──
    log "Building custom layer via isaac-ros CLI..."
    log "  The CLI will read ${WORKSPACE_CLI_DIR}/config.yaml"
    log "  and build Dockerfile.manipulation from ${WORKSPACE_DOCKER_DIR}/"

    cd "$ISAAC_ROS_WS"
    run_or_dry isaac-ros activate --build-local

    log "  ✓ CLI build complete"
fi

echo ""

# ─── Step 4: Tag and report ───
log "Build results:"

if ! $DRY_RUN; then
    echo ""
    docker images | grep -E 'isaac_ros|REPOSITORY' | head -10
    echo ""

    DISK_FREE_AFTER=$(get_disk_free_gb "$DOCKER_ROOT")
    DISK_USED_AFTER=$(get_disk_used_gb "$DOCKER_ROOT")
    log "  Disk after build: ${DISK_FREE_AFTER} GB free (${DISK_USED_AFTER} GB used)"
fi

log "═══════════════════════════════════════════════"
log "  Build complete!"
log ""
log "  Next steps:"
log "    1. Run restore_container.sh to start a container from this image"
log "    2. Enter the container: docker exec -it isaac_ros_manipulation bash"
log "    3. Run colcon build inside the container (see SKILL.md)"
log "═══════════════════════════════════════════════"
