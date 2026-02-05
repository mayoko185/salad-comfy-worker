FROM pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime
#FROM pytorch/pytorch:2.9.0-cuda13.0-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

LABEL org.opencontainers.image.title="ComfyUI Worker"
LABEL org.opencontainers.image.description="ComfyUI worker for Salad"

# Install System Dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl unzip ca-certificates libgl1 libglib2.0-0 nload nano \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install Rclone
RUN curl https://rclone.org/install.sh | bash

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Install ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
WORKDIR /workspace/ComfyUI
RUN pip install --no-cache-dir -r requirements.txt

WORKDIR /workspace
COPY startup.sh /workspace/startup.sh
COPY manual_sync_all.sh /workspace/manual_sync_all.sh
RUN chmod +x /workspace/startup.sh /workspace/manual_sync_all.sh

EXPOSE 8188
CMD ["/workspace/startup.sh"]