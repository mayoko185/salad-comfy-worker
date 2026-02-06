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

# Sync custom nodes
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

# Sync user configs
if [ -d "/workspace/ComfyUI/user" ]; then
    cd /workspace/ComfyUI/user
    tar -czf /workspace/user_data.tar.gz .
    echo "[Sync] Uploading User data"
    rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/config/" 
fi

echo ""
echo "✓ All user configs/data Synced to R2"
echo ""

# Sync models (with exclude support)
if [ -d "/workspace/bundle/models" ]; then
    echo "Syncing models (respecting exclude list)..."
    rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models \
        --ignore-existing --transfers 8 ${EXCLUDE_ARG}
fi

echo ""
echo "✓ Local Models Synced to R2"
echo ""

# Sync outputs
if [ -d "/workspace/ComfyUI/output" ]; then
    rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output \
        --ignore-existing --transfers 4 &>/dev/null
fi

echo ""
echo "✓ Local Output Folder Synced to R2"
echo ""
echo "=== Manual Sync Complete ==="
#!/bin/bash
set -euo pipefail

LOG=/workspace/startup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== logging to $LOG ==="

echo "=== ComfyUI Worker Starting ==="

retry() {
  local tries="$1"; shift
  local delay="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$tries" ]; then
      echo "Command failed after $tries attempts: $*"
      return 1
    fi
    echo "Command failed (attempt $n/$tries). Retrying in ${delay}s: $*"
    sleep "$delay"
    n=$((n+1))
    delay=$((delay*2))
  done
}

# ---- Startup bandwidth check + Salad reallocate ----
MIN_DL_Mbps="${MIN_DL_Mbps:-35}"
SPEEDTEST_BYTES="${SPEEDTEST_BYTES:-100000000}"   # 100MB default
SPEEDTEST_URL="https://speed.cloudflare.com/__down?bytes=${SPEEDTEST_BYTES}"

echo "=== Speed test (download) ==="
DL_Bps="$(curl -L -o /dev/null -s -w '%{speed_download}' "$SPEEDTEST_URL" || echo 0)"
DL_Mbps="$(awk -v bps="$DL_Bps" 'BEGIN { printf "%.2f", (bps*8)/1000000 }')"
echo "Download speed: ${DL_Mbps} Mbps (min: ${MIN_DL_Mbps})"

if awk -v dl="$DL_Mbps" -v min="$MIN_DL_Mbps" 'BEGIN { exit !(dl < min) }'; then
  echo "Download < ${MIN_DL_Mbps} Mbps; requesting Salad reallocate..."
    curl -sS --fail --noproxy "*" --request POST \
      --url "http://169.254.169.254/v1/reallocate" \
      --header "Content-Type: application/json" \
      --header "Metadata: true" \
      --data "{\"reason\":\"Insufficient Download Bandwidth\"}" || true
      sleep 5
  exit 0
fi

# ---- Start Tailscale daemon in background ----
echo "Starting Tailscale daemon..."
tailscaled --state=mem: --tun=userspace-networking &
TAILSCALED_PID=$!
sleep 3

# Check if tailscaled is running
if ! kill -0 $TAILSCALED_PID 2>/dev/null; then
    echo "==========================================" 
    echo "❌ ERROR: Tailscale daemon failed to start"
    echo "=========================================="
    exit 1
fi

# Attempt to connect to Tailscale
echo "Connecting to Tailscale network..."
if ! tailscale up --auth-key=$TAILSCALE_AUTH_KEY --hostname comfyui-salad-worker --accept-dns=false; then
    echo ""
    echo "=========================================="
    echo "❌ TAILSCALE CONNECTION FAILED"
    echo "🔑 Check your TAILSCALE_AUTH_KEY"
    echo "Generate new key at: https://login.tailscale.com/admin/settings/keys"
    echo "=========================================="
    exit 1
fi

sleep 3

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4)

if [ -z "$TAILSCALE_IP" ]; then
    echo "==========================================" 
    echo "❌ ERROR: Failed to get Tailscale IP"
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "✅ TAILSCALE CONNECTED SUCCESSFULLY"
echo "🔗 Tailscale IP: $TAILSCALE_IP"
echo "🏷️  Hostname: comfyui-salad-worker"
echo "🌐 ComfyUI URL: http://comfyui-salad-worker:8188"
echo "🌐 Or use: http://$TAILSCALE_IP:8188"
echo "=========================================="

# Enable SSH
tailscale set --ssh

# ---- Required env vars (from Salad) ----
: "${R2_ACCESS_KEY:?Missing R2_ACCESS_KEY}"
: "${R2_SECRET_KEY:?Missing R2_SECRET_KEY}"
: "${R2_ENDPOINT:?Missing R2_ENDPOINT}"

# ---- rclone config for Cloudflare R2 ----
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
region = auto
EOF

echo "=== rclone sanity check ==="
rclone version
retry 3 2 rclone lsd r2: >/dev/null

# ---- Validate R2 Connection ----
echo "=== Validating R2 Connection ==="
validate_r2() {
    echo "Testing R2 connectivity..."
    
    # Try to list the bucket root with timeout
    if timeout 10 rclone lsf "r2:comfyui-bundle/" --max-depth 1 >/dev/null 2>&1; then
        echo "✓ R2 connection successful"
        return 0
    else
        echo "✗ R2 connection failed"
        return 1
    fi
}

# Retry R2 connection with backoff
if ! retry 5 3 validate_r2; then
    echo "FATAL: Cannot connect to R2 after multiple attempts"
    echo "Please check:"
    echo "  - R2_ACCESS_KEY is correct"
    echo "  - R2_SECRET_KEY is correct"
    echo "  - R2_ENDPOINT is correct (${R2_ENDPOINT})"
    echo "  - Bucket 'comfyui-bundle' exists"
    echo "  - Network connectivity"
    
    # Optional: Request Salad reallocate on R2 failure
    curl -sS --fail --noproxy "*" --request POST \
      --url "http://169.254.169.254/v1/reallocate" \
      --header "Content-Type: application/json" \
      --header "Metadata: true" \
      --data "{\"reason\":\"Cannot connect to R2 storage\"}" || true
    
    exit 1
fi

MODELS_CFG="/workspace/models.json"
rclone copy "r2:comfyui-bundle/config/models.json" "/workspace/" >/dev/null 2>&1 || true
mkdir -p /workspace/bundle/models

if [ -f "$MODELS_CFG" ]; then
    python - <<'PY'
import json, os, subprocess, sys, time

cfg = "/workspace/models.json"
base = "/workspace/bundle/models"
civitai_token = os.environ.get("CIVITAI_TOKEN", "").strip()
items = json.load(open(cfg, "r", encoding="utf-8"))
failed = []

for it in items:
    url = it["url"]
    dest_rel = it["dest"]
    dest = os.path.join(base, dest_rel.lstrip("/"))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    
    # Skip if already exists
    if os.path.exists(dest):
        print(f"[models] ✓ {dest_rel} (already exists)", flush=True)
        continue
    
    cmd = ["curl", "--fail", "--location", "--progress-bar", "--output", dest, url]
    if it.get("auth") == "civitai" and civitai_token:
        cmd = ["curl", "--fail", "--location", "--progress-bar",
               "-H", f"Authorization: Bearer {civitai_token}",
               "--output", dest, url]
    
    print(f"[models] Downloading {url} -> {dest_rel}", flush=True)
    
    # Retry logic: 3 attempts with exponential backoff
    for attempt in range(1, 4):
        try:
            subprocess.check_call(cmd)
            print(f"[models] ✓ {dest_rel} downloaded successfully", flush=True)
            break
        except subprocess.CalledProcessError as e:
            if attempt < 3:
                wait_time = 2 ** attempt  # 2, 4, 8 seconds
                print(f"[models] ✗ Download failed (attempt {attempt}/3), retrying in {wait_time}s...", flush=True)
                time.sleep(wait_time)
            else:
                print(f"[models] ✗ FAILED after 3 attempts: {dest_rel}", flush=True)
                failed.append(dest_rel)
                # Remove partial download
                if os.path.exists(dest):
                    os.remove(dest)

if failed:
    print(f"\n⚠ WARNING: {len(failed)} model(s) failed to download:", flush=True)
    for f in failed:
        print(f"  - {f}", flush=True)
    print("Container will continue, but these models will be missing.\n", flush=True)
else:
    print(f"\n✓ All models downloaded successfully\n", flush=True)
PY
else
    echo "No models.json found; skipping model downloads"
fi

# ---- Optional exclude list (editable without rebuild) ----
# Put it in R2 at: comfyui-bundle/config/exclude.txt
EXCLUDE_FILE="/workspace/exclude.txt"
EXCLUDE_ARG=""

echo "=== Fetching optional exclude file ==="
if rclone lsf "r2:comfyui-bundle/config" >/dev/null 2>&1; then
  rclone copy "r2:comfyui-bundle/config/exclude.txt" "/workspace" >/dev/null 2>&1 || true
fi

if [ -f "${EXCLUDE_FILE}" ]; then
  echo "Using exclude file: ${EXCLUDE_FILE}"
  EXCLUDE_ARG="--exclude-from ${EXCLUDE_FILE}"
else
  echo "No exclude file found; syncing everything."
fi

echo "=== Syncing models from R2 ==="
mkdir -p /workspace/bundle/models
retry 6 2 rclone copy "r2:comfyui-bundle/bundle/models" "/workspace/bundle/models" -v --stats 20s --stats-one-line ${EXCLUDE_ARG}

echo "=== Syncing workflows from R2 ==="
mkdir -p /workspace/bundle/workflows
retry 6 2 rclone copy "r2:comfyui-bundle/bundle/workflows" "/workspace/bundle/workflows" -P ${EXCLUDE_ARG}

echo "=== Downloading/extracting custom nodes ==="
mkdir -p /workspace/bundle/custom_nodes

# If you want to exclude certain custom-node tarballs too, keep ${EXCLUDE_ARG} on lsf/copy.
# Otherwise remove it.
ARCHIVES="$(rclone lsf "r2:comfyui-bundle/custom_nodes_packed" | grep '.tar.gz' || true)"
if [ -n "${ARCHIVES}" ]; then
  for archive in ${ARCHIVES}; do
    echo "Processing archive: ${archive}"
    retry 6 2 rclone copy "r2:comfyui-bundle/custom_nodes_packed/${archive}" /tmp
    tar -xzf "/tmp/${archive}" -C /workspace/bundle/custom_nodes
    rm -f "/tmp/${archive}"
  done
else
  echo "No custom node archives found"
fi

echo "=== Restoring User Configs ==="

# Download the tarball (silent if missing, verbose enough to debug)
rclone copy "r2:comfyui-bundle/config/user_data.tar.gz" "/workspace/" -v --stats 25s --stats-one-line || true

mkdir -p /workspace/bundle/user_data
if [ -f "/workspace/user_data.tar.gz" ]; then
    echo "Extracting user configs/data"
    tar -xzf /workspace/user_data.tar.gz -C /workspace/bundle/user_data
    rm /workspace/user_data.tar.gz
    echo "User configs/data restored."
else
    echo "No user backup found. Starting fresh."
fi

echo "=== Setting up ComfyUI paths ==="
rm -rf /workspace/ComfyUI/custom_nodes /workspace/ComfyUI/models /workspace/ComfyUI/user 2>/dev/null || true
ln -sf /workspace/bundle/models /workspace/ComfyUI/models
ln -sf /workspace/bundle/custom_nodes /workspace/ComfyUI/custom_nodes
ln -sf /workspace/bundle/user_data /workspace/ComfyUI/user

echo "=== Installing custom node dependencies ==="
cd /workspace/ComfyUI/custom_nodes
for dir in */ ; do
  [ -d "$dir" ] || continue
  if [ -f "${dir}requirements.txt" ]; then
    echo "Installing requirements for ${dir}..."
    pip install --no-cache-dir -r "${dir}requirements.txt" 2>/dev/null || echo "Warning: requirements failed for ${dir}"
  fi
  if [ -f "${dir}install.py" ]; then
    echo "Running install.py for ${dir}..."
    python "${dir}install.py" 2>/dev/null || echo "Warning: install.py failed for ${dir}"
  fi
done

echo "=== Starting ComfyUI ==="
cd /workspace/ComfyUI
# Start ComfyUI in background
python main.py --listen :: --port 8188 &

# Bridge IPv4 for Tailscale access (if socat available)
if command -v socat >/dev/null 2>&1; then
    echo "Setting up Tailscale IPv4 bridge on port 8189..."
    socat TCP4-LISTEN:8189,fork,reuseaddr,bind=0.0.0.0 TCP6:[::1]:8188 &
fi

echo "=========================================="
echo "✅ ComfyUI is ready for jobs"
echo "🔗 Tailscale IP: $TAILSCALE_IP"
#echo "🌐 ComfyUI URL: http://comfyui-salad-worker:8189"
echo "🌐 ComfyUI URL: http://$TAILSCALE_IP:8189"
echo "=========================================="

COMFY_PID=$!

SYNC_FILE="/workspace/sync.txt"

# Run background sync service
echo "=== Fetching optional sync control file ==="
if rclone lsf "r2:comfyui-bundle/config" >/dev/null 2>&1; then
    rclone copy "r2:comfyui-bundle/config/sync.txt" "/workspace" >/dev/null 2>&1 || true
fi

if [ -f "${SYNC_FILE}" ] && grep -q -i "false" "${SYNC_FILE}"; then
    echo "=== Background Sync Disabled! Will not Sync to R2 for this session ==="
else
    echo "=== Starting Background Sync Service ==="
    /workspace/background_sync.sh &
    SYNC_PID=$!
    echo "Background sync running (PID: $SYNC_PID)"
fi

# Keep container alive by waiting for ComfyUI
wait $COMFY_PID
