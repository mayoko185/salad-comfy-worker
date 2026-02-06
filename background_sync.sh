#!/bin/bash
set -euo pipefail
LOG=/workspace/sync.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Background Sync Service Starting ==="

EXCLUDE_FILE="/workspace/exclude.txt"
EXCLUDE_ARG=""
if [ -f "${EXCLUDE_FILE}" ]; then
    EXCLUDE_ARG="--exclude-from ${EXCLUDE_FILE}"
    echo "Using exclude file: ${EXCLUDE_FILE}"
fi

SYNC_FILE="/workspace/sync.txt"
if [ -f "${SYNC_FILE}" ] && grep -q -i "false" "${SYNC_FILE}"; then
    echo "Sync disabled by sync.txt"
    exit 0
fi

echo "Starting background sync loops..."

# Upload outputs every 30 seconds
while true; do
    sleep 30
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing outputs..."
    rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output \
        --ignore-existing --transfers 4 &>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Outputs synced"
done &

# Upload models every 5 minutes
while true; do
    sleep 300
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing models..."
    rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models \
        --ignore-existing --transfers 8 ${EXCLUDE_ARG} &>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Models synced"
done &

# Upload user configs every 5 minutes  
while true; do
    sleep 300
    if [ -d "/workspace/ComfyUI/user" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing user configs..."
        cd /workspace/ComfyUI/user
        tar -czf /workspace/user_data.tar.gz . 2>/dev/null
        rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/config/" --quiet
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ User configs synced"
    fi
done &

# Upload custom nodes every 5 minutes WITH CHANGE DETECTION
while true; do
    sleep 300
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking custom nodes for changes..."
    
    CHECKSUM_FILE="/workspace/.custom_nodes_checksums"
    changes=0
    
    cd /workspace/bundle/custom_nodes
    for dir in */; do
        [ -d "$dir" ] || continue
        node_name="${dir%/}"
        
        # Calculate checksum based on file list + modification times
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
done &

# Keep script running
wait