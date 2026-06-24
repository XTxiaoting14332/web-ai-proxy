import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:ai_proxy/logger.dart';

Map<String, Completer<Response>> pendingRequests = {};
Map<String, WebSocketChannel> extensionWebSockets = {};
Future<void> globalQueue = Future.value();
Map<String, bool> isNavigating = {};

// SSE streaming: key=model, value=StreamController for SSE chunks
Map<String, StreamController<String>> sseControllers = {};

Map<String, String> sessionUrls = {};
Map<String, String> currentExtensionUrls = {};
Map<String, String> pendingSessionKeys = {};
Map<String, DateTime> lastActivityTimes = {};

void loadSessions() {
  final sessionFile = File('userdata/sessions.json');
  if (sessionFile.existsSync()) {
    try {
      sessionUrls = Map<String, String>.from(
        jsonDecode(sessionFile.readAsStringSync()),
      );
    } catch (_) {}
  }
}

void saveSessions() {
  final dir = Directory('userdata');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final sessionFile = File('userdata/sessions.json');
  sessionFile.writeAsStringSync(
    JsonEncoder.withIndent('  ').convert(sessionUrls),
  );
}

String mapModelName(String clientModel) {
  final m = clientModel.toLowerCase();
  if (m.contains('gemini'))                         return 'gemini';
  if (m.contains('gpt') || m.contains('openai'))    return 'gpt';
  if (m.contains('doubao') || m.contains('skylark')) return 'doubao';
  if (m.contains('glm') || m.contains('z.ai'))      return 'glm';
  if (m.contains('qwen') || m.contains('tongyi'))   return 'qwen';
  if (m.contains('kimi') || m.contains('moonshot')) return 'kimi';
  if (m.contains('dola'))                           return 'dola';
  return 'gemini';
}

String extractLastUserMessage(List<dynamic> messages) {
  for (int i = messages.length - 1; i >= 0; i--) {
    final msg = messages[i];
    if (msg is Map && msg['role'] == 'user') {
      final content = msg['content'];
      if (content is String) return content;
      if (content is List) {
        for (final block in content) {
          if (block is Map && block['type'] == 'text') {
            return (block['text'] ?? '').toString();
          }
        }
      }
    }
  }
  return '';
}

const Map<String, Map<String, String>> kSupportedModels = {
  'gemini': {
    'display_name': 'Gemini',
    'url': 'https://gemini.google.com/app',
  },
  'gpt': {
    'display_name': 'ChatGPT',
    'url': 'https://chatgpt.com/',
  },
  'doubao': {
    'display_name': 'Doubao (豆包)',
    'url': 'https://www.doubao.com/chat/',
  },
  'glm': {
    'display_name': 'GLM (z.ai)',
    'url': 'https://chat.z.ai/',
  },
  'qwen': {
    'display_name': 'Qwen (通义千问)',
    'url': 'https://chat.qwen.ai/',
  },
  'kimi': {
    'display_name': 'Kimi',
    'url': 'https://www.kimi.com/',
  },
  'dola': {
    'display_name': 'Dola',
    'url': 'https://www.dola.com/',
  },
};

const int kModelCreatedTs = 1700000000;
const String kModelCreatedAt = '2024-01-01T00:00:00Z';

Middleware customLogRequests() {
  return (Handler innerHandler) {
    return (Request request) async {
      final startTime = DateTime.now();
      try {
        final response = await innerHandler(request);
        final duration = DateTime.now().difference(startTime);
        Logger.api(
          request.method,
          response.statusCode,
          '/${request.url.path} [${duration.inMilliseconds}ms]',
        );
        return response;
      } on HijackException {
        rethrow;
      } catch (error) {
        final duration = DateTime.now().difference(startTime);
        Logger.api(
          request.method,
          500,
          '/${request.url.path} [${duration.inMilliseconds}ms] - Error: $error',
        );
        rethrow;
      }
    };
  };
}

Middleware apiAuthMiddleware(String apiKey) {
  return (Handler innerHandler) {
    return (Request request) {
      if (request.url.path.startsWith('api/') ||
          request.url.path.startsWith('v1/') ||
          request.url.path.startsWith('anthropic/')) {
        // 支持 Authorization: Bearer <key> 和 x-api-key: <key> 两种方式
        final authHeader = request.headers['authorization'];
        final xApiKey = request.headers['x-api-key'];
        final token = authHeader?.replaceFirst('Bearer ', '') ?? xApiKey ?? '';

        if (token != apiKey) {
          Logger.warn('Unauthorized access attempt to /${request.url.path}');
          return Response.forbidden(
            jsonEncode({"error": "Unauthorized: Invalid or missing API Key"}),
            headers: {'content-type': 'application/json'},
          );
        }
      }
      return innerHandler(request);
    };
  };
}

void main() {
  loadSessions();
  runZonedGuarded(
    () async {
      final configFile = File('config.json');
      late Map<String, dynamic> config;

      if (!configFile.existsSync()) {
        final newApiKey = Uuid().v4().substring(0, 8);
        config = {'host': '0.0.0.0', 'port': 8080, 'api_key': newApiKey};
        configFile.writeAsStringSync(
          JsonEncoder.withIndent('  ').convert(config),
        );
        Logger.success('Generated default config.json. API Key: $newApiKey');
      } else {
        final content = configFile.readAsStringSync();
        config = jsonDecode(content);
        Logger.info('Loaded existing config.json.');
      }

      final host = Platform.environment['HOST'] ?? config['host'] ?? '0.0.0.0';
      final port =
          int.tryParse(Platform.environment['PORT'] ?? '') ??
          config['port'] ??
          8080;
      final apiKey = Platform.environment['API_KEY'] ?? config['api_key'] ?? '';

      if (Platform.environment['API_KEY'] != null) {
        Logger.success('Using API Key from environment variable API_KEY');
      } else {
        Logger.info('Current API Key is: $apiKey');
      }

      // 设置SIGINT信号处理器
      ProcessSignal.sigint.watch().listen((signal) {
        Logger.info('Waiting for applications shutdown');
        for (var ws in extensionWebSockets.values.toList()) {
          ws.sink.close();
        }
        Logger.info('Application shutdown completed');
        Logger.info('Finished server process [$pid]');
        exit(0);
      });

      final app = Router();

      app.get('/ws', (Request request) {
        final model = request.url.queryParameters['model'] ?? 'gemini';

        var handler = webSocketHandler((
          WebSocketChannel webSocket,
          String? protocol,
        ) {
          Logger.success('WebSocket connection established for model: $model');
          extensionWebSockets[model] = webSocket;

          webSocket.stream.listen(
            (message) {
              try {
                final decoded = jsonDecode(message.toString());
                if (decoded is Map<String, dynamic>) {
                  if (decoded['action'] == 'register') {
                    currentExtensionUrls[model] =
                        decoded['url']?.toString() ?? '';
                    Logger.debug(
                      'Model $model registered URL: ${currentExtensionUrls[model]}',
                    );
                    return;
                  }

                  // 新增：处理 SSE 增量 chunk
                  if (decoded['action'] == 'chunk') {
                    final delta = decoded['delta']?.toString() ?? '';
                    if (sseControllers.containsKey(model) &&
                        !sseControllers[model]!.isClosed) {
                      final sseData = jsonEncode({"delta": delta});
                      sseControllers[model]!.add('data: $sseData\n\n');
                    }
                    return;
                  }

                  // 新增：处理 SSE 结束信号
                  if (decoded['action'] == 'done') {
                    final finalResponse = decoded['response']?.toString() ?? '';
                    final newUrl = decoded['url']?.toString();

                    if (newUrl != null && pendingSessionKeys[model] != null) {
                      sessionUrls[pendingSessionKeys[model]!] = newUrl;
                      currentExtensionUrls[model] = newUrl;
                      saveSessions();
                    }

                    if (sseControllers.containsKey(model) &&
                        !sseControllers[model]!.isClosed) {
                      sseControllers[model]!.add(
                        'data: ${jsonEncode({"done": true, "response": finalResponse})}\n\n',
                      );
                      sseControllers[model]!.close();
                      sseControllers.remove(model);
                    }

                    pendingRequests.remove(model);
                    return;
                  }

                  if (decoded['action'] == 'success' ||
                      decoded.containsKey("answer")) {
                    if (pendingRequests[model] != null &&
                        !pendingRequests[model]!.isCompleted) {
                      String finalResponse =
                          decoded["answer"]?.toString() ??
                          decoded["response"]?.toString() ??
                          message.toString();
                      String? thinking;
                      if (decoded.containsKey("thinking") &&
                          decoded["thinking"].toString().isNotEmpty) {
                        thinking = decoded["thinking"].toString();
                      }

                      String? newUrl = decoded["url"]?.toString();
                      if (newUrl != null && pendingSessionKeys[model] != null) {
                        sessionUrls[pendingSessionKeys[model]!] = newUrl;
                        currentExtensionUrls[model] = newUrl;
                        saveSessions();
                      }

                      final responseBody = {
                        "status": "success",
                        "response": finalResponse,
                      };
                      if (thinking != null) {
                        responseBody["thinking"] = thinking;
                      }

                      final response = Response.ok(
                        jsonEncode(responseBody),
                        headers: {'content-type': 'application/json'},
                      );
                      pendingRequests[model]!.complete(response);
                      pendingRequests.remove(model);
                    }
                  }
                }
              } catch (_) {
                // Legacy fallback for raw strings
                if (pendingRequests[model] != null &&
                    !pendingRequests[model]!.isCompleted) {
                  Logger.debug('Received legacy reply from model: $model');
                  final responseBody = {
                    "status": "success",
                    "response": message.toString(),
                  };
                  final response = Response.ok(
                    jsonEncode(responseBody),
                    headers: {'content-type': 'application/json'},
                  );
                  pendingRequests[model]!.complete(response);
                  pendingRequests.remove(model);
                }
              }
            },
            onDone: () {
              Logger.warn('WebSocket connection closed for model: $model');
              extensionWebSockets.remove(model);
              currentExtensionUrls.remove(model);
              if (pendingRequests[model] != null &&
                  !pendingRequests[model]!.isCompleted &&
                  !(isNavigating[model] ?? false)) {
                pendingRequests[model]!.complete(
                  Response.internalServerError(
                    body: jsonEncode({
                      "error":
                          "WebSocket connection closed unexpectedly during generation (Page reloaded?)",
                    }),
                    headers: {'content-type': 'application/json'},
                  ),
                );
                pendingRequests.remove(model);
              }
            },
            onError: (error) {
              Logger.error('WebSocket error for model $model: $error');
              extensionWebSockets.remove(model);
            },
          );
        });

        return handler(request);
      });

      app.delete('/api/chat/session', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        final model = data['model'] ?? 'gemini';
        final sessionId = data['session_id'];

        if (sessionId == null) {
          return Response(
            400,
            body: jsonEncode({"error": "Missing session_id"}),
            headers: {'content-type': 'application/json'},
          );
        }

        final sessionKey = "${model}_$sessionId";
        if (sessionUrls.containsKey(sessionKey)) {
          sessionUrls.remove(sessionKey);
          saveSessions();
          Logger.info('Deleted session: $sessionKey');
          return Response.ok(
            jsonEncode({"status": "success", "message": "Session deleted"}),
            headers: {'content-type': 'application/json'},
          );
        }
        return Response.notFound(
          jsonEncode({"error": "Session not found"}),
          headers: {'content-type': 'application/json'},
        );
      });

      app.get('/api/models', (Request request) {
        final modelList = kSupportedModels.entries.map((entry) {
          final modelId = entry.key;
          final info = entry.value;
          return {
            'id': modelId,
            'display_name': info['display_name'],
            'url': info['url'],
            'connected': extensionWebSockets.containsKey(modelId),
          };
        }).toList();

        return Response.ok(
          jsonEncode({'models': modelList}),
          headers: {'content-type': 'application/json'},
        );
      });

      app.post('/api/chat', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        final model = data['model'] ?? 'gemini';
        final sessionId = data['session_id'] ?? 'default';
        final sessionKey = "${model}_$sessionId";
        final bool isSse = data['sse'] == true;

        if (extensionWebSockets[model] == null &&
            extensionWebSockets['_manager'] == null) {
          Logger.error('Chrome plugin not connected for model: $model');
          return Response(
            503,
            body: jsonEncode({"error": "Chrome 插件未连接 ($model)"}),
            headers: {'content-type': 'application/json'},
          );
        }

        final prompt = data['prompt'] ?? '';
        Logger.info('Queuing prompt for $model (session: $sessionId)...');

        final completer = Completer<Response>();

        Future<void> process() async {
          try {
            // Compute target URL first (needed for potential tab wake-up)
            String? targetUrl = sessionUrls[sessionKey];
            if (targetUrl == null) {
              if (model == 'doubao')
                targetUrl = 'https://www.doubao.com/chat/';
              else if (model == 'gemini')
                targetUrl = 'https://gemini.google.com/app';
              else if (model == 'gpt')
                targetUrl = 'https://chatgpt.com/';
              else if (model == 'glm')
                targetUrl = 'https://chat.z.ai/';
              else if (model == 'dola')
                targetUrl = 'https://www.dola.com/';
              else if (model == 'qwen')
                targetUrl = 'https://chat.qwen.ai/';
              else if (model == 'kimi')
                targetUrl = 'https://www.kimi.com/';
              else
                targetUrl = currentExtensionUrls[model] ?? '';
            }

            lastActivityTimes[model] = DateTime.now();

            // If the tab was closed, try to wake it up via the manager
            if (extensionWebSockets[model] == null) {
              if (extensionWebSockets['_manager'] == null) {
                completer.complete(
                  Response(
                    503,
                    body: jsonEncode({"error": "Chrome 插件未连接 ($model)"}),
                    headers: {'content-type': 'application/json'},
                  ),
                );
                return;
              }
              Logger.info('Tab for $model is closed, waking up at $targetUrl...');
              extensionWebSockets['_manager']!.sink.add(
                jsonEncode({"action": "open_tab", "url": targetUrl}),
              );
              int attempts = 0;
              while (attempts < 60) {
                await Future.delayed(Duration(milliseconds: 500));
                if (extensionWebSockets[model] != null &&
                    currentExtensionUrls[model] != null) {
                  Logger.info('Tab for $model woke up after ${attempts * 500}ms');
                  break;
                }
                attempts++;
              }
              if (extensionWebSockets[model] == null) {
                Logger.error('Tab wake-up timed out for $model after 30s');
                completer.complete(
                  Response(
                    503,
                    body: jsonEncode(
                      {"error": "标签页唤起超时 ($model)"},
                    ),
                    headers: {'content-type': 'application/json'},
                  ),
                );
                return;
              }
              // Give the freshly opened tab extra time to fully load
              await Future.delayed(Duration(seconds: 2));
            }
            Logger.info('Forwarding prompt to $model (session: $sessionId)...');
            final reqCompleter = Completer<Response>();
            pendingRequests[model] = reqCompleter;
            pendingSessionKeys[model] = sessionKey;

            String currentUrl = currentExtensionUrls[model] ?? "";

            if (currentUrl != targetUrl) {
              Logger.info('Navigating to target session URL: $targetUrl');
              isNavigating[model] = true;
              extensionWebSockets[model]!.sink.add(
                jsonEncode({"action": "navigate", "url": targetUrl}),
              );

              // Wait for WS to drop
              int attempts = 0;
              while (attempts < 10) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] == null) break;
                attempts++;
              }

              // Wait for WS to reconnect
              attempts = 0;
              while (attempts < 50) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] != null &&
                    currentExtensionUrls[model] != null) {
                  break;
                }
                attempts++;
              }

              isNavigating[model] = false;

              if (attempts >= 50) {
                throw Exception(
                  "Timeout waiting for browser to navigate to session URL",
                );
              }
              await Future.delayed(Duration(milliseconds: 1500));
            }

            if (extensionWebSockets[model] == null) {
              throw Exception(
                "Extension disconnected after navigation ($model page reload?)",
              );
            }

            extensionWebSockets[model]!.sink.add(
              jsonEncode({"action": "prompt", "text": prompt, "sse": isSse}),
            );

            final response = await reqCompleter.future;
            completer.complete(response);
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(
                Response.internalServerError(
                  body: jsonEncode({"error": e.toString()}),
                  headers: {'content-type': 'application/json'},
                ),
              );
            }
            // SSE 模式下关闭 controller 并发送错误事件
            if (sseControllers.containsKey(model) &&
                !sseControllers[model]!.isClosed) {
              sseControllers[model]!.add(
                'data: ${jsonEncode({"error": e.toString()})}\n\n',
              );
              sseControllers[model]!.close();
              sseControllers.remove(model);
            }
            pendingRequests.remove(model);
          } finally {
            Logger.info('Model $model cooling down for 6 seconds...');
            await Future.delayed(Duration(seconds: 6));
            Logger.info('Model $model ready for next request.');
          }
        }

        if (!isSse) {
          // 非 SSE 模式：原有逻辑
          globalQueue = globalQueue.catchError((_) {}).then((_) => process());
          return completer.future;
        } else {
          return request.hijack((channel) async {
            final sseController = StreamController<String>();
            sseControllers[model] = sseController;

            globalQueue = globalQueue.catchError((_) {}).then((_) => process());

            final sink = channel.sink;
            // 手动写 HTTP 响应头，写入后立即刷到 TCP socket（不经过 HttpResponse 缓冲）
            sink.add(utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: text/event-stream; charset=utf-8\r\n'
              'Cache-Control: no-cache\r\n'
              'Connection: keep-alive\r\n'
              'X-Accel-Buffering: no\r\n'
              'Access-Control-Allow-Origin: *\r\n'
              '\r\n',
            ));

            try {
              await for (final sseEvent in sseController.stream) {
                sink.add(utf8.encode(sseEvent));
              }
            } catch (_) {}

            await sink.close();
          });
        }
      });

      app.post('/v1/chat/completions', (Request request) async {
        // 1. 解析请求体
        final payload = await request.readAsString();
        Map<String, dynamic> data;
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          return Response(
            400,
            body: jsonEncode({"error": {"message": "Invalid JSON", "type": "invalid_request_error"}}),
            headers: {'content-type': 'application/json'},
          );
        }

        // 2. 提取字段
        final clientModel = (data['model'] ?? 'gemini').toString();
        final model = mapModelName(clientModel);
        final messages = data['messages'];
        if (messages == null || messages is! List || messages.isEmpty) {
          return Response(
            400,
            body: jsonEncode({"error": {"message": "messages is required", "type": "invalid_request_error"}}),
            headers: {'content-type': 'application/json'},
          );
        }
        final prompt = extractLastUserMessage(messages as List<dynamic>);
        if (prompt.isEmpty) {
          return Response(
            400,
            body: jsonEncode({"error": {"message": "No user message found", "type": "invalid_request_error"}}),
            headers: {'content-type': 'application/json'},
          );
        }
        final bool isStream = data['stream'] == true;
        final sessionId = (data['user'] ?? 'default').toString();
        final sessionKey = '${model}_$sessionId';

        // 3. 检查插件连接
        if (extensionWebSockets[model] == null && extensionWebSockets['_manager'] == null) {
          return Response(
            503,
            body: jsonEncode({"error": {"message": "Chrome 插件未连接 ($model)", "type": "server_error"}}),
            headers: {'content-type': 'application/json'},
          );
        }

        Logger.info('[OpenAI Compat] model=$model, stream=$isStream, session=$sessionId');

        // 4. 生成唯一 completion id
        final completionId = 'chatcmpl-${Uuid().v4().substring(0, 8)}';
        final createdTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        // 5. 复用内部 process 逻辑（与 /api/chat 完全相同的结构）
        final completer = Completer<Response>();

        Future<void> process() async {
          try {
            String? targetUrl = sessionUrls[sessionKey];
            if (targetUrl == null) {
              if (model == 'doubao')      targetUrl = 'https://www.doubao.com/chat/';
              else if (model == 'gemini') targetUrl = 'https://gemini.google.com/app';
              else if (model == 'gpt')    targetUrl = 'https://chatgpt.com/';
              else if (model == 'glm')    targetUrl = 'https://chat.z.ai/';
              else if (model == 'dola')   targetUrl = 'https://www.dola.com/';
              else if (model == 'qwen')   targetUrl = 'https://chat.qwen.ai/';
              else if (model == 'kimi')   targetUrl = 'https://www.kimi.com/';
              else                        targetUrl = currentExtensionUrls[model] ?? '';
            }

            lastActivityTimes[model] = DateTime.now();

            if (extensionWebSockets[model] == null) {
              if (extensionWebSockets['_manager'] == null) {
                completer.complete(Response(503,
                  body: jsonEncode({"error": {"message": "Chrome 插件未连接 ($model)", "type": "server_error"}}),
                  headers: {'content-type': 'application/json'},
                ));
                return;
              }
              extensionWebSockets['_manager']!.sink.add(jsonEncode({"action": "open_tab", "url": targetUrl}));
              int attempts = 0;
              while (attempts < 60) {
                await Future.delayed(Duration(milliseconds: 500));
                if (extensionWebSockets[model] != null && currentExtensionUrls[model] != null) break;
                attempts++;
              }
              if (extensionWebSockets[model] == null) {
                completer.complete(Response(503,
                  body: jsonEncode({"error": {"message": "标签页唤起超时 ($model)", "type": "server_error"}}),
                  headers: {'content-type': 'application/json'},
                ));
                return;
              }
              await Future.delayed(Duration(seconds: 2));
            }

            final reqCompleter = Completer<Response>();
            pendingRequests[model] = reqCompleter;
            pendingSessionKeys[model] = sessionKey;

            String currentUrl = currentExtensionUrls[model] ?? '';
            if (currentUrl != targetUrl) {
              isNavigating[model] = true;
              extensionWebSockets[model]!.sink.add(jsonEncode({"action": "navigate", "url": targetUrl}));
              int attempts = 0;
              while (attempts < 10) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] == null) break;
                attempts++;
              }
              attempts = 0;
              while (attempts < 50) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] != null && currentExtensionUrls[model] != null) break;
                attempts++;
              }
              isNavigating[model] = false;
              if (attempts >= 50) throw Exception("Timeout waiting for navigation");
              await Future.delayed(Duration(milliseconds: 1500));
            }

            if (extensionWebSockets[model] == null) {
              throw Exception("Extension disconnected after navigation");
            }

            extensionWebSockets[model]!.sink.add(jsonEncode({"action": "prompt", "text": prompt, "sse": isStream}));

            final innerResponse = await reqCompleter.future;
            // innerResponse 是原始 /api/chat 格式的 Response，我们不直接用 body
            // 此处我们需要从 pendingRequests 完成后拿到响应文本。
            // 但实际上 reqCompleter 完成时返回的是 Response 对象，我们解析其 body。
            final bodyStr = await innerResponse.readAsString();
            final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
            final responseText = bodyJson['response']?.toString() ?? bodyJson['answer']?.toString() ?? '';

            // 格式化为 OpenAI 格式
            final openAIResponse = {
              "id": completionId,
              "object": "chat.completion",
              "created": createdTs,
              "model": clientModel,
              "choices": [
                {
                  "index": 0,
                  "message": {"role": "assistant", "content": responseText},
                  "finish_reason": "stop",
                }
              ],
              "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            };
            completer.complete(Response.ok(
              jsonEncode(openAIResponse),
              headers: {'content-type': 'application/json'},
            ));
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(Response(500,
                body: jsonEncode({"error": {"message": e.toString(), "type": "server_error"}}),
                headers: {'content-type': 'application/json'},
              ));
            }
            if (sseControllers.containsKey(model) && !sseControllers[model]!.isClosed) {
              sseControllers[model]!.close();
              sseControllers.remove(model);
            }
            pendingRequests.remove(model);
          } finally {
            await Future.delayed(Duration(seconds: 6));
          }
        }

        if (!isStream) {
          globalQueue = globalQueue.catchError((_) {}).then((_) => process());
          return completer.future;
        }

        // SSE 流式响应
        return request.hijack((channel) async {
          final sseController = StreamController<String>();
          sseControllers[model] = sseController;

          globalQueue = globalQueue.catchError((_) {}).then((_) => process());

          final sink = channel.sink;
          sink.add(utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream; charset=utf-8\r\n'
            'Cache-Control: no-cache\r\n'
            'Connection: keep-alive\r\n'
            'X-Accel-Buffering: no\r\n'
            'Access-Control-Allow-Origin: *\r\n'
            '\r\n',
          ));

          // 发送 role 初始化 chunk
          final initChunk = jsonEncode({
            "id": completionId, "object": "chat.completion.chunk",
            "created": createdTs, "model": clientModel,
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": null}],
          });
          sink.add(utf8.encode('data: $initChunk\n\n'));

          try {
            await for (final sseEvent in sseController.stream) {
              // sseEvent 是内部格式：'data: {"delta":"..."}\n\n' 或 'data: {"done":true,...}\n\n'
              // 需要转换为 OpenAI chunk 格式
              final raw = sseEvent.trim();
              if (!raw.startsWith('data: ')) continue;
              final jsonStr = raw.substring(6);
              try {
                final eventData = jsonDecode(jsonStr) as Map<String, dynamic>;
                if (eventData.containsKey('delta')) {
                  // 增量 chunk
                  final deltaText = eventData['delta']?.toString() ?? '';
                  final chunk = jsonEncode({
                    "id": completionId, "object": "chat.completion.chunk",
                    "created": createdTs, "model": clientModel,
                    "choices": [{"index": 0, "delta": {"content": deltaText}, "finish_reason": null}],
                  });
                  sink.add(utf8.encode('data: $chunk\n\n'));
                } else if (eventData['done'] == true) {
                  // 结束 chunk
                  final stopChunk = jsonEncode({
                    "id": completionId, "object": "chat.completion.chunk",
                    "created": createdTs, "model": clientModel,
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                  });
                  sink.add(utf8.encode('data: $stopChunk\n\n'));
                  sink.add(utf8.encode('data: [DONE]\n\n'));
                } else if (eventData.containsKey('error')) {
                  final errChunk = jsonEncode({
                    "id": completionId, "object": "chat.completion.chunk",
                    "created": createdTs, "model": clientModel,
                    "choices": [{"index": 0, "delta": {"content": "[Error: ${eventData['error']}]"}, "finish_reason": "stop"}],
                  });
                  sink.add(utf8.encode('data: $errChunk\n\n'));
                  sink.add(utf8.encode('data: [DONE]\n\n'));
                }
              } catch (_) {}
            }
          } catch (_) {}

          await sink.close();
        });
      });

      app.get('/v1/models', (Request request) {
        final data = kSupportedModels.entries.map((entry) => {
          'id': entry.key,
          'object': 'model',
          'created': kModelCreatedTs,
          'owned_by': 'web-ai-proxy',
        }).toList();

        return Response.ok(
          jsonEncode({'object': 'list', 'data': data}),
          headers: {'content-type': 'application/json'},
        );
      });

      app.get('/v1/models/<modelId>', (Request request, String modelId) {
        final internalId = kSupportedModels.containsKey(modelId)
            ? modelId
            : (kSupportedModels.containsKey(mapModelName(modelId))
                ? mapModelName(modelId)
                : null);

        if (internalId == null) {
          return Response(
            404,
            body: jsonEncode({
              'error': {
                'message': "The model '$modelId' does not exist",
                'type': 'invalid_request_error',
                'code': 'model_not_found',
              }
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        return Response.ok(
          jsonEncode({
            'id': internalId,
            'object': 'model',
            'created': kModelCreatedTs,
            'owned_by': 'web-ai-proxy',
          }),
          headers: {'content-type': 'application/json'},
        );
      });

      app.post('/anthropic/v1/messages', (Request request) async {
        // 1. 解析请求体
        final payload = await request.readAsString();
        Map<String, dynamic> data;
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          return Response(
            400,
            body: jsonEncode({"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid JSON"}}),
            headers: {'content-type': 'application/json'},
          );
        }

        // 2. 提取字段
        final clientModel = (data['model'] ?? 'gemini').toString();
        final model = mapModelName(clientModel);
        final messages = data['messages'];
        if (messages == null || messages is! List || messages.isEmpty) {
          return Response(
            400,
            body: jsonEncode({"type": "error", "error": {"type": "invalid_request_error", "message": "messages is required"}}),
            headers: {'content-type': 'application/json'},
          );
        }
        final prompt = extractLastUserMessage(messages as List<dynamic>);
        if (prompt.isEmpty) {
          return Response(
            400,
            body: jsonEncode({"type": "error", "error": {"type": "invalid_request_error", "message": "No user message found"}}),
            headers: {'content-type': 'application/json'},
          );
        }
        final bool isStream = data['stream'] == true;
        final sessionId = 'default'; // Anthropic 无 user 字段，统一用 default
        final sessionKey = '${model}_$sessionId';

        // 3. 检查插件连接
        if (extensionWebSockets[model] == null && extensionWebSockets['_manager'] == null) {
          return Response(
            503,
            body: jsonEncode({"type": "error", "error": {"type": "overloaded_error", "message": "Chrome 插件未连接 ($model)"}}),
            headers: {'content-type': 'application/json'},
          );
        }

        Logger.info('[Anthropic Compat] model=$model, stream=$isStream');

        final msgId = 'msg_${Uuid().v4().substring(0, 8)}';
        final createdTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        final completer = Completer<Response>();

        Future<void> process() async {
          try {
            String? targetUrl = sessionUrls[sessionKey];
            if (targetUrl == null) {
              if (model == 'doubao')      targetUrl = 'https://www.doubao.com/chat/';
              else if (model == 'gemini') targetUrl = 'https://gemini.google.com/app';
              else if (model == 'gpt')    targetUrl = 'https://chatgpt.com/';
              else if (model == 'glm')    targetUrl = 'https://chat.z.ai/';
              else if (model == 'dola')   targetUrl = 'https://www.dola.com/';
              else if (model == 'qwen')   targetUrl = 'https://chat.qwen.ai/';
              else if (model == 'kimi')   targetUrl = 'https://www.kimi.com/';
              else                        targetUrl = currentExtensionUrls[model] ?? '';
            }

            lastActivityTimes[model] = DateTime.now();

            if (extensionWebSockets[model] == null) {
              if (extensionWebSockets['_manager'] == null) {
                completer.complete(Response(503,
                  body: jsonEncode({"type": "error", "error": {"type": "overloaded_error", "message": "Chrome 插件未连接 ($model)"}}),
                  headers: {'content-type': 'application/json'},
                ));
                return;
              }
              extensionWebSockets['_manager']!.sink.add(jsonEncode({"action": "open_tab", "url": targetUrl}));
              int attempts = 0;
              while (attempts < 60) {
                await Future.delayed(Duration(milliseconds: 500));
                if (extensionWebSockets[model] != null && currentExtensionUrls[model] != null) break;
                attempts++;
              }
              if (extensionWebSockets[model] == null) {
                completer.complete(Response(503,
                  body: jsonEncode({"type": "error", "error": {"type": "overloaded_error", "message": "标签页唤起超时 ($model)"}}),
                  headers: {'content-type': 'application/json'},
                ));
                return;
              }
              await Future.delayed(Duration(seconds: 2));
            }

            final reqCompleter = Completer<Response>();
            pendingRequests[model] = reqCompleter;
            pendingSessionKeys[model] = sessionKey;

            String currentUrl = currentExtensionUrls[model] ?? '';
            if (currentUrl != targetUrl) {
              isNavigating[model] = true;
              extensionWebSockets[model]!.sink.add(jsonEncode({"action": "navigate", "url": targetUrl}));
              int attempts = 0;
              while (attempts < 10) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] == null) break;
                attempts++;
              }
              attempts = 0;
              while (attempts < 50) {
                await Future.delayed(Duration(milliseconds: 200));
                if (extensionWebSockets[model] != null && currentExtensionUrls[model] != null) break;
                attempts++;
              }
              isNavigating[model] = false;
              if (attempts >= 50) throw Exception("Timeout waiting for navigation");
              await Future.delayed(Duration(milliseconds: 1500));
            }

            if (extensionWebSockets[model] == null) {
              throw Exception("Extension disconnected after navigation");
            }

            extensionWebSockets[model]!.sink.add(jsonEncode({"action": "prompt", "text": prompt, "sse": isStream}));

            final innerResponse = await reqCompleter.future;
            final bodyStr = await innerResponse.readAsString();
            final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
            final responseText = bodyJson['response']?.toString() ?? bodyJson['answer']?.toString() ?? '';

            // 格式化为 Anthropic 格式
            final anthropicResponse = {
              "id": msgId,
              "type": "message",
              "role": "assistant",
              "model": clientModel,
              "content": [{"type": "text", "text": responseText}],
              "stop_reason": "end_turn",
              "stop_sequence": null,
              "usage": {"input_tokens": 0, "output_tokens": 0},
            };
            completer.complete(Response.ok(
              jsonEncode(anthropicResponse),
              headers: {'content-type': 'application/json'},
            ));
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(Response(500,
                body: jsonEncode({"type": "error", "error": {"type": "api_error", "message": e.toString()}}),
                headers: {'content-type': 'application/json'},
              ));
            }
            if (sseControllers.containsKey(model) && !sseControllers[model]!.isClosed) {
              sseControllers[model]!.close();
              sseControllers.remove(model);
            }
            pendingRequests.remove(model);
          } finally {
            await Future.delayed(Duration(seconds: 6));
          }
        }

        if (!isStream) {
          globalQueue = globalQueue.catchError((_) {}).then((_) => process());
          return completer.future;
        }

        // SSE 流式响应（Anthropic 格式）
        return request.hijack((channel) async {
          final sseController = StreamController<String>();
          sseControllers[model] = sseController;

          globalQueue = globalQueue.catchError((_) {}).then((_) => process());

          final sink = channel.sink;
          sink.add(utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream; charset=utf-8\r\n'
            'Cache-Control: no-cache\r\n'
            'Connection: keep-alive\r\n'
            'X-Accel-Buffering: no\r\n'
            'Access-Control-Allow-Origin: *\r\n'
            '\r\n',
          ));

          // 发送 message_start
          final msgStart = jsonEncode({
            "type": "message_start",
            "message": {"id": msgId, "type": "message", "role": "assistant", "model": clientModel,
                        "content": [], "stop_reason": null, "usage": {"input_tokens": 0, "output_tokens": 0}},
          });
          sink.add(utf8.encode('event: message_start\ndata: $msgStart\n\n'));

          // 发送 content_block_start
          final blockStart = jsonEncode({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}});
          sink.add(utf8.encode('event: content_block_start\ndata: $blockStart\n\n'));

          // 发送 ping
          sink.add(utf8.encode('event: ping\ndata: {"type":"ping"}\n\n'));

          StringBuffer fullText = StringBuffer();

          try {
            await for (final sseEvent in sseController.stream) {
              final raw = sseEvent.trim();
              if (!raw.startsWith('data: ')) continue;
              final jsonStr = raw.substring(6);
              try {
                final eventData = jsonDecode(jsonStr) as Map<String, dynamic>;
                if (eventData.containsKey('delta')) {
                  final deltaText = eventData['delta']?.toString() ?? '';
                  fullText.write(deltaText);
                  final delta = jsonEncode({
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": deltaText},
                  });
                  sink.add(utf8.encode('event: content_block_delta\ndata: $delta\n\n'));
                } else if (eventData['done'] == true) {
                  // content_block_stop
                  sink.add(utf8.encode('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'));
                  // message_delta
                  final msgDelta = jsonEncode({
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": null},
                    "usage": {"output_tokens": fullText.length},
                  });
                  sink.add(utf8.encode('event: message_delta\ndata: $msgDelta\n\n'));
                  // message_stop
                  sink.add(utf8.encode('event: message_stop\ndata: {"type":"message_stop"}\n\n'));
                } else if (eventData.containsKey('error')) {
                  sink.add(utf8.encode('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'));
                  sink.add(utf8.encode('event: message_stop\ndata: {"type":"message_stop"}\n\n'));
                }
              } catch (_) {}
            }
          } catch (_) {}

          await sink.close();
        });
      });

      app.get('/anthropic/v1/models', (Request request) {
        final modelIds = kSupportedModels.keys.toList();
        final data = kSupportedModels.entries.map((entry) => {
          'type': 'model',
          'id': entry.key,
          'display_name': '${entry.value['display_name']} (via Web AI Proxy)',
          'created_at': kModelCreatedAt,
        }).toList();

        return Response.ok(
          jsonEncode({
            'data': data,
            'has_more': false,
            'first_id': modelIds.isNotEmpty ? modelIds.first : null,
            'last_id': modelIds.isNotEmpty ? modelIds.last : null,
          }),
          headers: {'content-type': 'application/json'},
        );
      });

      app.get('/anthropic/v1/models/<modelId>', (Request request, String modelId) {
        final internalId = kSupportedModels.containsKey(modelId)
            ? modelId
            : (kSupportedModels.containsKey(mapModelName(modelId))
                ? mapModelName(modelId)
                : null);

        if (internalId == null) {
          return Response(
            404,
            body: jsonEncode({
              'type': 'error',
              'error': {
                'type': 'not_found_error',
                'message': "Model '$modelId' not found",
              }
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        final info = kSupportedModels[internalId]!;
        return Response.ok(
          jsonEncode({
            'type': 'model',
            'id': internalId,
            'display_name': '${info['display_name']} (via Web AI Proxy)',
            'created_at': kModelCreatedAt,
          }),
          headers: {'content-type': 'application/json'},
        );
      });

      final handler = const Pipeline()
          .addMiddleware(customLogRequests())
          .addMiddleware(apiAuthMiddleware(apiKey))
          .addHandler(app.call);

      final server = await io.serve(handler, InternetAddress(host), port);
      Logger.info('HTTP server is starting...');
      Logger.info('Started server process [$pid]');

      // Close idle model tabs after 5 minutes of inactivity
      Timer.periodic(Duration(minutes: 1), (_) {
        final now = DateTime.now();
        for (final model in extensionWebSockets.keys.toList()) {
          if (model == '_manager') continue;
          if (pendingRequests.containsKey(model)) continue;
          final lastActivity = lastActivityTimes[model];
          if (lastActivity != null &&
              now.difference(lastActivity) > Duration(minutes: 5)) {
            Logger.info('Closing idle tab for model: $model');
            // Tell the _manager to close the tab, not navigate to about:blank
            if (extensionWebSockets['_manager'] != null) {
              extensionWebSockets['_manager']!.sink.add(
                jsonEncode({"action": "close_tab", "model": model}),
              );
            } else {
              // Fallback: just disconnect the content script's WS
              extensionWebSockets[model]?.sink.close();
            }
            lastActivityTimes.remove(model);
          }
        }
      });

      if (host.contains(":")) {
        Logger.info(
          'HTTP server listening on http://[$host]:$port (Ctrl+C to quit)',
        );
        Logger.info('WebSocket server listening on ws://[$host]:$port/ws');
      } else {
        Logger.info('Serving at http://$host:$port (Ctrl+C to quit)');
        Logger.info('WebSocket server listening on ws://$host:$port/ws');
      }
    },
    (error, stackTrace) {
      Logger.error('Unhandled Exception: $error\nStack Trace:\n$stackTrace');
    },
  );
}
