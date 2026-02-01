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
import json, os, subprocess, sys

cfg="/workspace/models.json"
base="/workspace/bundle/models"
civitai_token=os.environ.get("CIVITAI_TOKEN","").strip()

items=json.load(open(cfg,"r",encoding="utf-8"))
for it in items:
    url=it["url"]
    dest_rel=it["dest"]
    dest=os.path.join(base, dest_rel.lstrip("/"))
    os.makedirs(os.path.dirname(dest), exist_ok=True)

    cmd=["curl","--fail","--location","--silent","--show-error","--output",dest,url]
    if it.get("auth")=="civitai" and civitai_token:
        cmd=["curl","--fail","--location","--silent","--show-error",
             "-H",f"Authorization: Bearer {civitai_token}",
             "--output",dest,url]

    print(f"[models] {url} -> {dest}", flush=True)
    subprocess.check_call(cmd)
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
COMFY_PID=$!

SYNC_FILE="/workspace/sync.txt"

echo "=== Fetching optional sync control file ==="
if rclone lsf "r2:comfyui-bundle/config" >/dev/null 2>&1; then
	rclone copy "r2:comfyui-bundle/config/sync.txt" "/workspace" >/dev/null 2>&1 || true
fi

if [ -f "${SYNC_FILE}" ] && grep -q -i "false" "${SYNC_FILE}"; then
	echo "=== Background Sync Disabled! Will not Sync to R2 for this session ==="
	# Skip sync loops
else

	echo "=== Starting Background Sync to R2 Services ==="

	# Upload NEW Model
	
	  while true; do
		sleep 300
		rclone copy /workspace/bundle/models r2:comfyui-bundle/bundle/models --ignore-existing --transfers 8 >/dev/null 2>&1
		echo "=== Local Models Synced to R2 ==="
	  done &

	# Upload NEW Outputs
	
	  while true; do
		sleep 30
		rclone copy /workspace/ComfyUI/output r2:comfyui-bundle/output --ignore-existing --transfers 4 >/dev/null 2>&1
		echo "=== Local Output Folder Synced to R2 ==="
	  done &

	# Upload User Configs
	
		while true; do
			sleep 300
			if [ -d "/workspace/ComfyUI/user" ]; then
				cd /workspace/ComfyUI/user
                if tar -czf /tmp/user_data.tar.gz .; then
                    mv /tmp/user_data.tar.gz /workspace/user_data.tar.gz
                    rclone copy "/workspace/user_data.tar.gz" "r2:comfyui-bundle/config/" --quiet
					echo "=== User Configs Synced to R2 ==="
                fi
			fi
		done &

	# Upload Custom Nodes

		while true; do
			sleep 300
			cd /workspace/bundle/custom_nodes

				for dir in */; do
					[ -d "$dir" ] || continue
					node_name="${dir%/}"
				# Create tarball quietly
				tar -czf "/tmp/${node_name}.tar.gz" "$node_name" 2>/dev/null
				rclone copy "/tmp/${node_name}.tar.gz" r2:comfyui-bundle/custom_nodes_packed/ --transfers 8 --quiet
				echo "=== Local Custom Nodes Synced to R2 ==="
				
				rm "/tmp/${node_name}.tar.gz"
			done
		done &

fi

# Keep container alive by waiting for ComfyUI
wait $COMFY_PID
