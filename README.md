# AI Web Proxy

> ⚠️ **声明：本项目及相关代码仅供学习、研究与技术探讨使用。严禁用于任何商业用途或违反各平台服务条款（ToS）的行为。因滥用本项目引发的一切纠纷及后果由使用者自行承担。**

AI Web Proxy 是一个基于“浏览器真实 UI 驱动”的轻量级 AI 接口代理系统。它通过 Chrome 插件的底层调试 API (`chrome.debugger`) 物理模拟人类的键盘输入与点击，从而完美绕过严格的反爬虫检测与风控限制，将网页端的 AI 聊天界面（如 ChatGPT、Gemini、豆包等）封装为标准的 HTTP API 供第三方服务调用。

## ✨ 核心特性

- **🤖 原生防风控穿透**：不依赖任何非官方 API 接口，完全基于前端 DOM 的纯物理模拟，从根本上免疫 Cloudflare 等反爬虫屏障。
- **🔌 多模型路由支持**：内置了针对 ChatGPT、Gemini、豆包 (Doubao) 和 Chat Z.AI 的专属 DOM 适配器，通过单连接动态路由分发请求。
- **🚦 智能排队与冷却**：后端内置了单模型级别的并发请求队列系统，确保浏览器前端在一次只处理一个任务，并附带 6 秒的安全冷却期，避免账号被限流。
- **🔒 API 安全鉴权**：首次启动自动生成 8 位高强度 API Key，针对所有的 HTTP API 请求强制实施 `Bearer Token` 拦截鉴权。
- **⚙️ 可视化插件配置**：抛弃繁琐的硬编码，插件端自带独立的弹窗设置界面，可一键实时修改后端的 WebSocket 连接地址。
- **🌈 优雅的架构与日志**：后端基于 Dart `shelf` 生态重构，拥有严谨的异常兜底 (`runZonedGuarded`)、优雅的 `Ctrl+C` 停机处理，以及带彩虹特效的彩色终端状态回显。

## 📂 架构概览

系统由两个松耦合的模块组成：
1. **服务端 (Backend)**: 位于 `bin/ai_proxy.dart`。负责接收外部 HTTP POST 请求，将文本指令放入队列，并通过 WebSocket 推送给对应的浏览器插件；当插件抓取到回答后，再将结果原路返回。
2. **浏览器插件 (Extension)**: 位于 `extension/` 目录。这是基于 Manifest V3 的 Chrome 扩展，负责注入宿主网页，执行光标聚焦、按键触发与 DOM 文本逆向提取。

## 🚀 快速开始

### 1. 启动后端服务

你需要安装 Dart SDK，然后在项目根目录下执行：

```bash
# 获取依赖
dart pub get

# 启动代理服务端
dart run bin/ai_proxy.dart
```

首次运行后，当前目录会自动生成 `config.json` 文件并终端会打印出类似下方的日志：
```text
2026-06-08 02:00:00 [SUCCESS] | Web Proxy | Generated default config.json. API Key: abc12345
2026-06-08 02:00:00 [INFO] | Web Proxy | Serving at http://127.0.0.1:8080 (Ctrl+C to quit)
```

### 2. 加载浏览器插件

1. 打开 Chrome 浏览器，访问 `chrome://extensions/`。
2. 打开右上角的 **开发者模式**。
3. 点击 **加载已解压的扩展程序 (Load unpacked)**，选择本项目中的 `extension` 文件夹。
4. 点击工具栏上的扩展图标，打开设置面板，确保 **Backend Server Address** 填入的是你启动的后端地址（如 `ws://127.0.0.1:8080/ws`），并点击保存。

### 3. 打开目标 AI 网页

在浏览器中分别打开你需要使用的 AI 模型页面（请确保账号已登录）：
- ChatGPT: `https://chatgpt.com`
- Gemini: `https://gemini.google.com`
- 豆包: `https://www.doubao.com`
- Z.AI: `https://chat.z.ai`

保持这些网页处于打开（或后台挂起）状态，插件会自动尝试与后端建立 WebSocket 连接并在控制台打印绿色的连接成功日志。

### 4. 发起调用

你可以像调用标准 API 一样向本地服务器发送请求。请在 Header 中带上你在 `config.json` 中配置的 `api_key`：

```bash
curl -X POST http://127.0.0.1:8080/api/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <你的API_KEY>" \
  -d '{
    "model": "gemini",
    "prompt": "请给我写一个关于大海的简短诗歌。"
  }'
```
*(支持的 `model` 字段包括：`gemini`, `gpt`, `doubao`, `glm`)*

## 🛠️ 无头服务器部署 (进阶)

如果你需要在无显示器的 Linux 服务器上 24 小时运行此项目，可以参考 [containerization_plan.md](./containerization_plan.md) 文档。
基本思路是利用 `Xvfb` (X Virtual Framebuffer) 在内存中虚拟一块显示器屏幕，配合 `--no-sandbox` 启动 Chromium，从而在纯命令行环境中完美挂载带 UI 的插件进行渲染。

---
*Created with ❤️ by NightWind & AI Agents*
