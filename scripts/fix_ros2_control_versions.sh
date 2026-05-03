#!/bin/bash
# fix_ros2_control_versions.sh — Pin and install all ros2_control packages to consistent versions
#
# The ros2_control framework has ABI breakages between minor versions. If
# controller-manager is at 4.44.0 but hardware-interface is at 4.43.0, you get
# segfaults in ros2_control_node.
# See: https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_manipulation/issues/18
#
# This script:
#   1. Queries apt for the latest available version of ros2_control core
#   2. Pins ALL ros2_control core packages to that exact version
#   3. Queries apt for the latest available version of ros2_controllers
#   4. Pins ALL ros2_controllers packages to that exact version
#   5. Installs everything in ONE apt transaction
#   6. Verifies consistency after install
#
# Usage:
#   ./fix_ros2_control_versions.sh              # Fix + verify
#   ./fix_ros2_control_versions.sh --check      # Verify only (no changes)
#   ./fix_ros2_control_versions.sh --dry-run    # Show what would be installed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Package lists ───
# ros2_control core (https://github.com/ros-controls/ros2_control)
# All share the same upstream version (e.g., 4.44.0)
ROS2_CONTROL_CORE=(
    ros-jazzy-controller-interface
    ros-jazzy-controller-manager
    ros-jazzy-controller-manager-msgs
    ros-jazzy-hardware-interface
    ros-jazzy-joint-limits
    ros-jazzy-ros2-control
    ros-jazzy-ros2-control-test-assets
    ros-jazzy-ros2controlcli
    ros-jazzy-transmission-interface
)

# ros2_controllers (https://github.com/ros-controls/ros2_controllers)
# All share the same upstream version (e.g., 4.39.0)
ROS2_CONTROLLERS=(
    ros-jazzy-admittance-controller
    ros-jazzy-bicycle-steering-controller
    ros-jazzy-diff-drive-controller
    ros-jazzy-effort-controllers
    ros-jazzy-force-torque-sensor-broadcaster
    ros-jazzy-forward-command-controller
    ros-jazzy-gpio-controllers
    ros-jazzy-gripper-controllers
    ros-jazzy-imu-sensor-broadcaster
    ros-jazzy-joint-state-broadcaster
    ros-jazzy-joint-trajectory-controller
    ros-jazzy-mecanum-drive-controller
    ros-jazzy-parallel-gripper-controller
    ros-jazzy-pid-controller
    ros-jazzy-position-controllers
    ros-jazzy-range-sensor-broadcaster
    ros-jazzy-ros2-controllers
    ros-jazzy-steering-controllers-library
    ros-jazzy-tricycle-controller
    ros-jazzy-tricycle-steering-controller
    ros-jazzy-velocity-controllers
)

# ─── Helper functions ───

# Extract upstream version from a full debian version string
# e.g., "4.44.0-1noble.20260412.063301" → "4.44.0"
upstream_ver() {
    echo "$1" | sed 's/-.*//'
}

# Get the latest available candidate version for a package from apt
apt_candidate() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'
}

# Get the installed version for a package
installed_ver() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo ""
}

# Find the target version for a group — the latest available version that
# exists for ALL packages in the group. Uses the reference package (first in list)
# to determine the target upstream version, then finds the exact debian version
# for each package.
resolve_target_version() {
    local ref_pkg="$1"
    local candidate
    candidate=$(apt_candidate "$ref_pkg")
    if [[ -z "$candidate" ]]; then
        echo ""
        return
    fi
    upstream_ver "$candidate"
}

# Check if all packages in a group are at the same upstream version
check_group() {
    local group_name="$1"
    shift
    local packages=("$@")
    local versions=()
    local missing=()
    local fail=0

    for pkg in "${packages[@]}"; do
        local ver
        ver=$(installed_ver "$pkg")
        if [[ -z "$ver" ]]; then
            missing+=("$pkg")
        else
            versions+=("$(upstream_ver "$ver")")
        fi
    done

    local unique_versions
    unique_versions=$(printf '%s\n' "${versions[@]}" | sort -u)
    local num_unique
    num_unique=$(echo "$unique_versions" | wc -l)

    echo ""
    echo -e "${CYAN}=== ${group_name} ===${NC}"

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}  Not installed: ${missing[*]}${NC}"
    fi

    if [[ $num_unique -eq 1 && ${#versions[@]} -gt 0 ]]; then
        echo -e "${GREEN}  ✅ All ${#versions[@]} packages at version: ${unique_versions}${NC}"
    elif [[ $num_unique -gt 1 ]]; then
        echo -e "${RED}  ❌ VERSION MISMATCH: $(echo "$unique_versions" | tr '\n' ' ')${NC}"
        for pkg in "${packages[@]}"; do
            local v
            v=$(installed_ver "$pkg")
            [[ -n "$v" ]] && echo "    $pkg = $(upstream_ver "$v")"
        done
        fail=1
    fi

    return $fail
}

# ─── Modes ───

do_check() {
    echo "ros2_control ABI consistency check"
    echo "==================================="
    local fail=0
    check_group "ros2_control core" "${ROS2_CONTROL_CORE[@]}" || fail=1
    check_group "ros2_controllers" "${ROS2_CONTROLLERS[@]}" || fail=1

    echo ""
    if [[ $fail -eq 0 ]]; then
        echo -e "${GREEN}✅ All ros2_control packages have consistent versions.${NC}"
    else
        echo -e "${RED}❌ Version mismatch detected! Run without --check to fix.${NC}"
        exit 1
    fi
}

do_fix() {
    local dry_run="${1:-false}"

    echo "ros2_control ABI version fixer"
    echo "==============================="
    echo ""

    # Update apt cache
    if [[ "$dry_run" == "false" ]]; then
        echo "Updating apt cache..."
        apt-get update -qq
    fi

    # Resolve target versions
    echo ""
    echo "Resolving target versions..."

    local core_target
    core_target=$(resolve_target_version "${ROS2_CONTROL_CORE[0]}")
    echo -e "  ros2_control core target: ${CYAN}${core_target}${NC}"

    local ctrl_target
    ctrl_target=$(resolve_target_version "${ROS2_CONTROLLERS[0]}")
    echo -e "  ros2_controllers target:  ${CYAN}${ctrl_target}${NC}"

    if [[ -z "$core_target" || -z "$ctrl_target" ]]; then
        echo -e "${RED}ERROR: Could not resolve target versions from apt. Is the ROS repo configured?${NC}"
        exit 1
    fi

    # Build the pinned install list
    # For each package, find the exact debian version that matches the target upstream
    local install_list=()

    echo ""
    echo "Pinning ros2_control core to ${core_target}..."
    for pkg in "${ROS2_CONTROL_CORE[@]}"; do
        # Get all available versions and find the one matching our target upstream
        local pinned_ver
        pinned_ver=$(apt-cache madison "$pkg" 2>/dev/null \
            | awk '{print $3}' \
            | grep "^${core_target}-" \
            | head -1)
        if [[ -n "$pinned_ver" ]]; then
            install_list+=("${pkg}=${pinned_ver}")
            echo "  ${pkg}=${pinned_ver}"
        else
            # Fallback: just install the package (apt will pick latest)
            install_list+=("${pkg}")
            echo -e "  ${pkg} ${YELLOW}(no exact pin found, using latest)${NC}"
        fi
    done

    echo ""
    echo "Pinning ros2_controllers to ${ctrl_target}..."
    for pkg in "${ROS2_CONTROLLERS[@]}"; do
        local pinned_ver
        pinned_ver=$(apt-cache madison "$pkg" 2>/dev/null \
            | awk '{print $3}' \
            | grep "^${ctrl_target}-" \
            | head -1)
        if [[ -n "$pinned_ver" ]]; then
            install_list+=("${pkg}=${pinned_ver}")
            echo "  ${pkg}=${pinned_ver}"
        else
            install_list+=("${pkg}")
            echo -e "  ${pkg} ${YELLOW}(no exact pin found, using latest)${NC}"
        fi
    done

    echo ""
    echo "Total: ${#install_list[@]} packages"

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}DRY RUN — no changes made. Command would be:${NC}"
        echo "apt-get install -y --allow-downgrades ${install_list[*]}"
        return
    fi

    # Install everything in ONE transaction with --allow-downgrades
    # (in case the base image has newer versions of some packages)
    echo ""
    echo "Installing all ${#install_list[@]} packages in single transaction..."
    apt-get install -y --allow-downgrades "${install_list[@]}"

    # Clean up
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # Verify
    echo ""
    echo "Verifying..."
    do_check
}

# ─── Main ───

case "${1:-}" in
    --check)
        do_check
        ;;
    --dry-run)
        do_fix "true"
        ;;
    *)
        do_fix "false"
        ;;
esac
