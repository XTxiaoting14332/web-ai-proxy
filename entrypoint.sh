#!/bin/bash
set -e

export DISPLAY=:99
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
mkdir -p ~/.vnc

VNC_PASSWORD=${VNC_PASSWORD:-123456}
echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd
Xvnc :99 -geometry 1280x1024 -depth 24 -rfbauth ~/.vnc/passwd -listen 0.0.0.0 -SecurityTypes VncAuth &
sleep 1

fluxbox >/dev/null 2>&1 &

echo "Starting AI Proxy Server..."
./server &

echo "Starting Chromium in virtual display..."
# 清理异常退出或旧容器遗留的 Chromium 锁定文件
rm -f /app/userdata/SingletonLock /app/userdata/SingletonCookie /app/userdata/SingletonSocket

chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-dev-shm-usage \
  --allow-running-insecure-content \
  --user-data-dir=/app/userdata \
  --window-position=0,0 \
  --window-size=1280,1024 \
  --load-extension=/app/extension \
  "https://chatgpt.com" \
  "https://gemini.google.com" \
  "https://www.doubao.com" \
  "https://chat.z.ai"
