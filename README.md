# Web AI Proxy

> ⚠️ 声明：本项目仅供学习与技术探讨，严禁用于商业用途。因滥用本项目引发的后果由使用者自行承担。

这是一个基于 Chrome 插件的 AI 接口代理工具。通过浏览器插件直接操作网页 DOM 并模拟用户输入，将AI的网页端聊天界面封装成 HTTP API 供外部调用。

## 特性

- 基于真实的浏览器环境，直接控制网页元素，不需要逆向内部接口。
- 简单的 Bearer Token 接口鉴权。
- 支持通过 Docker + Xvnc 在无界面服务器上运行。

## 架构

1. **后端 (Dart)**: 接收外部 HTTP 请求，将任务通过 WebSocket 发送给浏览器插件，并等待结果返回。
2. **插件 (Chrome Extension)**: 注入到目标网页，负责实际的输入、点击和内容提取。

## 🚀快速开始

### 1. 运行后端服务

前往[Release](https://github.com/XTxiaoting14332/web-ai-proxy/releases)页面下载对应架构的二进制文件以及`web-ai-proxy-extension.zip`

首次运行二进制会在目录下生成 `config.json`，里面包含随机生成的 API Key。终端会打印监听地址（默认 `http://127.0.0.1:8080`）。

### 2. 安装并配置插件

1. Chrome/Chromium 浏览器打开 `chrome://extensions/`，开启“开发者模式”。
2. 点击“加载已解压的扩展程序”，选择项目中的 `extension` 目录。
3. 点击插件图标打开设置，确认 Backend Server Address 为 `ws://127.0.0.1:8080/ws`，点击保存。

### 3. 打开模型网页

在浏览器打开你需要的 AI 网站。下表是目标网站和 API 中 `model` 字段的对应关系：

| 模型平台 | 目标网页 URL | API `model` 字段 |
| :--- | :--- | :--- |
| ChatGPT | `https://chatgpt.com` | `gpt` |
| Gemini | `https://gemini.google.com` | `gemini` |
| 豆包 (Doubao) | `https://www.doubao.com` | `doubao` |
| GLM (z.ai) | `https://chat.z.ai` | `glm` |

(后续将支持更多)

保持网页打开。插件会自动连接本地后端。

### 4. API 调用

在 Header 中带上 `config.json` 里的 `api_key` 发起请求：

```bash
curl -X POST http://127.0.0.1:8080/api/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <API_KEY>" \
  -d '{
    "model": "gemini",
    "prompt": "请给我写一个关于大海的简短诗歌。"
  }'
```
*(支持的 model: `gemini`, `gpt`, `doubao`, `glm`)*

**成功返回示例：**
```json
{
  "status": "success",
  "thinking": "这是大模型的思考过程（仅针对 z.ai 等深度思考模型）...",
  "response": "这是模型返回的具体文本内容..."
}
```

**错误返回示例：**
```json
{
  "status": "error",
  "error": "具体的错误描述（如超时、模型未连接等）"
}
```

## 🐳Docker 部署

> **硬件推荐**：由于内部集成了 Chromium 浏览器和完整桌面环境，容器运行的常态内存占用约为 500MB。推荐宿主机服务器配置为 **RAM ≥ 1GB**，以防止系统触发 OOM。

### 1. 拉取并启动

```bash
sudo docker run -d \
  --name web-ai-proxy \
  --restart unless-stopped \
  -p 8080:8080 \
  -p 5900:5999 \
  -e VNC_PASSWORD="mypassword" \
  -v ai-proxy-userdata:/app/userdata \
  ghcr.io/xtxiaoting14332/ai-proxy:latest
```

### 2. 账号登录
网页端AI需登录才能使用更多功能，操作步骤如下：
1. 使用 VNC 客户端（如 TigerVNC、Remmina）连接 `127.0.0.1:5900`，密码是你设置的 `VNC_PASSWORD`（如果不设置环境变量，默认为 `123456`）。
2. 看到浏览器界面后，手动完成各个网站的登录和验证。
3. 登录完成后即可断开 VNC 连接。由于使用了 `ai-proxy-userdata` 数据卷挂载，登录状态会安全且永久地保存在 Docker 中。之后即使在不同目录重启或更新容器，也绝对不需要重新登录。
