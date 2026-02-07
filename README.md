# salad-comfy-worker

Production-ready ComfyUI worker for Salad.com with Tailscale networking, Cloudflare R2 storage sync, and automatic model management.

## Features

- 🚀 **Fast Startup**: Parallel model downloads with retry logic
- 🔄 **Intelligent Sync**: Background R2 sync with change detection
- 🌐 **Tailscale Integration**: Secure remote access without port forwarding
- 📦 **Automatic Model Management**: JSON-based model downloads from HuggingFace/Civitai
- 🎛️ **Flexible Configuration**: Runtime sync control via R2 config files
- 🔍 **Bandwidth Validation**: Auto-reallocate on slow connections
- 📊 **Comprehensive Logging**: All operations logged to `/workspace/startup.log`

## Architecture

┌─────────────────┐
│ Salad Worker │
│ │
│ ┌───────────┐ │ ┌──────────────┐
│ │ ComfyUI │◄─┼─────┤ Tailscale │
│ │ :8188 │ │ │ :8189 │
│ └───────────┘ │ └──────────────┘
│ │ │
│ ▼ │
│ ┌───────────┐ │ ┌──────────────┐
│ │ Bundle │◄─┼─────┤ R2 Storage │
│ │ /models │ │ │ comfyui- │
│ │ /nodes │ │ │ bundle/ │
│ │ /user │ │ └──────────────┘
│ └───────────┘ │
└─────────────────┘

## Quick Start

### 1. Build the Docker Image

docker build -t salad-comfy-worker:latest . 

### 2. Environment Variables

# Required
R2_ACCESS_KEY=your_access_key
R2_SECRET_KEY=your_secret_key
R2_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
TAILSCALE_AUTH_KEY=tskey-auth-xxxxxx
# Optional
CIVITAI_TOKEN=your_civitai_api_token  # For Civitai downloads
MIN_DL_Mbps=35                         # Minimum download speed (default: 35)
SPEEDTEST_BYTES=100000000              # Speed test size (default: 100MB)

### 3. R2 Bucket Structure

comfyui-bundle/
├── bundle/
│   ├── models/              # Synced models
│   │   ├── checkpoints/
│   │   ├── loras/
│   │   ├── controlnet/
│   │   └── ...
│   └── workflows/           # Workflow JSON files
├── config/                  # Configuration files (optional)
│   ├── models.json          # Model download list
│   ├── exclude.txt



