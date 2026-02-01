#!/bin/bash
echo "=== Syncing custom nodes to R2 ==="

cd /workspace/bundle/custom_nodes

for dir in */; do
    node_name="${dir%/}"
    echo "Packaging $node_name..."
    
    tar -czf "/tmp/${node_name}.tar.gz" "$node_name"
    rclone copy "/tmp/${node_name}.tar.gz" r2:comfyui-bundle/custom_nodes_packed/ --transfers 8
    rm "/tmp/${node_name}.tar.gz"
    
    echo "✓ $node_name synced"
done

echo ""
echo "✓ All custom nodes synced to R2!"

if [ -d "/workspace/ComfyUI/user" ]; then
	cd /workspace/ComfyUI/user
	tar -czf /workspace/user_data.tar.gz .
	echo "[Sync] Uploading User data"
	rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/" 
fi

echo ""
echo "✓ All user configs/data synced to R2!"
