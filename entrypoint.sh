#!/bin/bash
set -e

# 1. 配置并启动 Xvnc (自带虚拟屏幕的工业级 VNC Server)
export DISPLAY=:99
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
mkdir -p ~/.vnc
echo "123456" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# 启动 Xvnc，绑定 5900 端口，设置分辨率和强密码验证
Xvnc :99 -geometry 1280x1024 -depth 24 -rfbauth ~/.vnc/passwd -listen 0.0.0.0 -SecurityTypes VncAuth &
sleep 1

# 启动窗口管理器 Fluxbox
fluxbox >/dev/null 2>&1 &

# 2. 启动 Dart 代理服务端 (后台挂起)
echo "Starting AI Proxy Server..."
./server &

# 3. 启动 Chromium 并自动挂载插件、打开目标 AI 站点
echo "Starting Chromium in virtual display..."
chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-dev-shm-usage \
  --user-data-dir=/app/userdata \
  --window-position=0,0 \
  --window-size=1280,1024 \
  --load-extension=/app/extension \
  "https://chatgpt.com" \
  "https://gemini.google.com" \
  "https://www.doubao.com" \
  "https://chat.z.ai"
