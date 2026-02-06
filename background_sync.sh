#!/bin/bash
set -euo pipefail

LOG=/workspace/sync.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Background Sync Service Starting ==="

# Load exclude file if exists
EXCLUDE_FILE="/workspace/exclude.txt"
EXCLUDE_ARG=""
if [ -f "${EXCLUDE_FILE}" ]; then
    EXCLUDE_ARG="--exclude-from ${EXCLUDE_FILE}"
    echo "Using exclude file: ${EXCLUDE_FILE}"
fi

# Check if sync is disabled
check_sync_enabled() {
    local SYNC_FILE="/workspace/sync.txt"
    if [ -f "${SYNC_FILE}" ] && grep -q -i "false" "${SYNC_FILE}"; then
        return 1  # disabled
    fi
    return 0  # enabled
}

# Sync models
sync_models() {
    if check_sync_enabled; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing models..."
        rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models \
            --ignore-existing --transfers 8 ${EXCLUDE_ARG} &>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Models synced"
    fi
}

# Sync outputs
sync_outputs() {
    if check_sync_enabled; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing outputs..."
        rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output \
            --ignore-existing --transfers 4 &>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Outputs synced"
    fi
}

# Sync user configs
sync_user_configs() {
    if check_sync_enabled && [ -d "/workspace/ComfyUI/user" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing user configs..."
        cd /workspace/ComfyUI/user
        if tar -czf /tmp/user_data.tar.gz . 2>/dev/null; then
            mv /tmp/user_data.tar.gz /workspace/user_data.tar.gz
            rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/config/" --quiet
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ User configs synced"
        fi
    fi
}

# Sync custom nodes with change detection
sync_custom_nodes() {
    if check_sync_enabled; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking custom nodes for changes..."
        local CHECKSUM_FILE="/workspace/.custom_nodes_checksums"
        local changes=0
        
        cd /workspace/bundle/custom_nodes
        for dir in */; do
            [ -d "$dir" ] || continue
            node_name="${dir%/}"
            
            # Calculate directory checksum (file list + mtimes, not content)
            current_sum=$(find "$node_name" -type f -printf '%P %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1)
            
            # Check if changed
            if ! grep -q "^${node_name}:${current_sum}$" "${CHECKSUM_FILE}" 2>/dev/null; then
                echo "  → Packaging ${node_name} (changed)..."
                tar -czf "/tmp/${node_name}.tar.gz" "$node_name" 2>/dev/null
                rclone copy "/tmp/${node_name}.tar.gz" r2:comfyui-bundle/custom_nodes_packed/ \
                    --transfers 8 --quiet
                rm "/tmp/${node_name}.tar.gz"
                
                # Update checksum
                sed -i "/^${node_name}:/d" "${CHECKSUM_FILE}" 2>/dev/null || true
                echo "${node_name}:${current_sum}" >> "${CHECKSUM_FILE}"
                changes=$((changes + 1))
            fi
        done
        
        if [ $changes -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] No custom node changes detected"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ ${changes} custom node(s) synced"
        fi
    fi
}

# Main loop
echo "Starting sync loops (models: 5min, outputs: 30s, user: 5min, nodes: 5min)"

while true; do
    sleep 30
    sync_outputs &
    
    if [ $((SECONDS % 300)) -lt 30 ]; then
        sync_models &
        sync_user_configs &
        sync_custom_nodes &
    fi
    
    wait
done
