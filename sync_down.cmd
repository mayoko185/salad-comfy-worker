# Run this on your home PC to get images instantly
while ($true) {
    rclone sync r2:comfyui-bundle/output C:\Users\Andy\Documents\ComfyUI\salad_output
    Start-Sleep -Seconds 10
}
