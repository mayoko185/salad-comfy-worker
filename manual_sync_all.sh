#!/bin/bash

echo "=== Starting Manual Synced to R2 ==="

cd /workspace/bundle/custom_nodes

for dir in */; do
    node_name="${dir%/}"
    echo "Packaging $node_name..."
    
    tar -czf "/tmp/${node_name}.tar.gz" "$node_name"
    rclone copy "/tmp/${node_name}.tar.gz" r2:comfyui-bundle/custom_nodes_packed/ --transfers 8
    rm "/tmp/${node_name}.tar.gz"
    
    echo "✓ $node_name Synced to R2"
done

echo ""
echo "✓ All custom nodes Synced to R2!"
echo ""

if [ -d "/workspace/ComfyUI/user" ]; then
	cd /workspace/ComfyUI/user
	tar -czf /workspace/user_data.tar.gz .
	echo "[Sync] Uploading User data"
	rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/" 
fi

echo ""
echo "✓ All user configs/data Synced to R2"
echo ""

if [ -d "/workspace/bundle/models" ]; then
	rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models --ignore-existing --transfers 8 >/dev/null 2>&1
fi

echo ""
echo "✓ Local Models Synced to R2"
echo ""

if [ -d "/workspace/ComfyUI/output" ]; then
	rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output --ignore-existing --transfers 4 >/dev/null 2>&1
fi

echo ""
echo "✓ Local Output Folder Synced to R2"
echo ""

