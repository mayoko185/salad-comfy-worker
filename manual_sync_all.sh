#!/bin/bash

echo "=== Starting Manual Sync to R2 ==="

# Load exclude file if exists
EXCLUDE_FILE="/workspace/exclude.txt"
EXCLUDE_ARG=""
if [ -f "${EXCLUDE_FILE}" ]; then
    echo "Using exclude file: ${EXCLUDE_FILE}"
    EXCLUDE_ARG="--exclude-from ${EXCLUDE_FILE}"
else
    echo "No exclude file found"
fi

echo ""
echo "=== Syncing Custom Nodes (with change detection) ==="
CHECKSUM_FILE="/workspace/.custom_nodes_checksums"
changes=0

cd /workspace/bundle/custom_nodes
for dir in */; do
    [ -d "$dir" ] || continue
    node_name="${dir%/}"
    
    # Calculate checksum
    current_sum=$(find "$node_name" -type f -printf '%P %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1)
    
    # Check if changed or force sync (manual always uploads)
    if ! grep -q "^${node_name}:${current_sum}$" "${CHECKSUM_FILE}" 2>/dev/null; then
        echo "Packaging $node_name..."
        tar -czf "/tmp/${node_name}.tar.gz" "$node_name"
        rclone copy "/tmp/${node_name}.tar.gz" r2:comfyui-bundle/custom_nodes_packed/ --transfers 8
        rm "/tmp/${node_name}.tar.gz"
        
        # Update checksum
        sed -i "/^${node_name}:/d" "${CHECKSUM_FILE}" 2>/dev/null || true
        echo "${node_name}:${current_sum}" >> "${CHECKSUM_FILE}"
        
        echo "✓ $node_name Synced to R2"
        changes=$((changes + 1))
    else
        echo "○ $node_name (no changes)"
    fi
done

echo ""
if [ $changes -eq 0 ]; then
    echo "No custom node changes to sync"
else
    echo "✓ Synced $changes custom node(s) to R2"
fi
echo ""

# Sync user configs
echo "=== Syncing User Configs ==="
if [ -d "/workspace/ComfyUI/user" ]; then
    cd /workspace/ComfyUI/user
    tar -czf /workspace/user_data.tar.gz .
    echo "Uploading User data..."
    rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/config/" 
    echo "✓ User configs synced to R2"
else
    echo "No user directory found"
fi
echo ""

# Sync models (with exclude support)
echo "=== Syncing Models (respecting exclude list) ==="
if [ -d "/workspace/bundle/models" ]; then
    rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models \
        --ignore-existing --transfers 8 ${EXCLUDE_ARG}
    echo "✓ Models synced to R2"
else
    echo "No models directory found"
fi
echo ""

# Sync outputs
echo "=== Syncing Output Folder ==="
if [ -d "/workspace/ComfyUI/output" ]; then
    rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output \
        --ignore-existing --transfers 4 &>/dev/null
    echo "✓ Output folder synced to R2"
else
    echo "No output directory found"
fi
echo ""

echo "=== Manual Sync Complete ==="