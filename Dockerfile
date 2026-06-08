# Stage 1: Build (编译 Dart 后端)
FROM dart:stable AS build
WORKDIR /app
# 缓存依赖
COPY pubspec.* ./
RUN dart pub get
# 拷贝源码并编译为原生二进制文件
COPY . .
RUN dart compile exe bin/ai_proxy.dart -o /app/server

# Stage 2: Runtime (极简运行环境)
FROM debian:bookworm-slim

# 安装必要组件
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    tigervnc-standalone-server \
    tigervnc-tools \
    fluxbox \
    fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 从构建阶段提取二进制产物
COPY --from=build /app/server /app/server
# 提取最新编译的 Chrome 插件
COPY extension /app/extension
# 拷贝启动脚本
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080 5900

ENTRYPOINT ["/app/entrypoint.sh"]
