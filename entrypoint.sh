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
  --disable-web-security \
  --disable-features=BlockInsecurePrivateNetworkRequests \
  --disable-background-timer-throttling \
  --disable-renderer-backgrounding \
  --disable-translate \
  --lang=zh-CN \
  --accept-lang=zh-CN,zh \
  --user-data-dir=/app/userdata \
  --window-position=0,0 \
  --window-size=1280,1024 \
  --load-extension=/app/extension &

CHROMIUM_PID=$!
sleep 10

chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://chatgpt.com" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://gemini.google.com" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://www.doubao.com" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://chat.z.ai" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://dola.com" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://chat.qwen.ai" &
sleep 4
chromium --no-sandbox --disable-translate --lang=zh-CN --accept-lang=zh-CN,zh --user-data-dir=/app/userdata "https://www.kimi.com" &

# 阻塞脚本，防止 Docker 容器退出
wait $CHROMIUM_PID
