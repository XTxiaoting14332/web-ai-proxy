FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/ai_proxy.dart -o /app/server
RUN dart compile js proxy/background.dart -O3 -o extension/background.js && \
    dart compile js proxy/doubao.dart -O3 -o extension/doubao.js && \
    dart compile js proxy/gemini.dart -O3 -o extension/gemini.js && \
    dart compile js proxy/glm.dart -O3 -o extension/glm.js && \
    dart compile js proxy/gpt.dart -O3 -o extension/gpt.js && \
    dart compile js proxy/dola.dart -O3 -o extension/dola.js && \
    dart compile js proxy/qwen.dart -O3 -o extension/qwen.js && \
    dart compile js proxy/kimi.dart -O3 -o extension/kimi.js && \
    dart compile js proxy/copilot.dart -O3 -o extension/copilot.js && \
    dart compile js proxy/popup.dart -O3 -o extension/popup.js


FROM debian:bookworm-slim
RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    tigervnc-standalone-server \
    tigervnc-tools \
    fluxbox \
    fonts-noto-cjk \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/zh_CN.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8

WORKDIR /app
COPY --from=build /app/server /app/server
COPY --from=build /app/extension /app/extension
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080 5900

ENTRYPOINT ["/app/entrypoint.sh"]
