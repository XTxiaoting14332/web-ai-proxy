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
Map<String, Future<void>> modelQueues = {};

Map<String, String> sessionUrls = {};
Map<String, String> currentExtensionUrls = {};
Map<String, String> pendingSessionKeys = {};

void loadSessions() {
  final sessionFile = File('userdata/sessions.json');
  if (sessionFile.existsSync()) {
    try {
      sessionUrls = Map<String, String>.from(jsonDecode(sessionFile.readAsStringSync()));
    } catch (_) {}
  }
}

void saveSessions() {
  final dir = Directory('userdata');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final sessionFile = File('userdata/sessions.json');
  sessionFile.writeAsStringSync(JsonEncoder.withIndent('  ').convert(sessionUrls));
}

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
      if (request.url.path.startsWith('api/')) {
        final authHeader = request.headers['authorization'];
        final token = authHeader?.replaceFirst('Bearer ', '') ?? '';

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
      final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? config['port'] ?? 8080;
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
                    currentExtensionUrls[model] = decoded['url']?.toString() ?? '';
                    Logger.debug('Model $model registered URL: ${currentExtensionUrls[model]}');
                    return;
                  }

                  if (decoded['action'] == 'success' || decoded.containsKey("answer")) {
                    if (pendingRequests[model] != null && !pendingRequests[model]!.isCompleted) {
                      String finalResponse = decoded["answer"]?.toString() ?? decoded["response"]?.toString() ?? message.toString();
                      String? thinking;
                      if (decoded.containsKey("thinking") && decoded["thinking"].toString().isNotEmpty) {
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
                if (pendingRequests[model] != null && !pendingRequests[model]!.isCompleted) {
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
          return Response(400, body: jsonEncode({"error": "Missing session_id"}), headers: {'content-type': 'application/json'});
        }
        
        final sessionKey = "${model}_$sessionId";
        if (sessionUrls.containsKey(sessionKey)) {
          sessionUrls.remove(sessionKey);
          saveSessions();
          Logger.info('Deleted session: $sessionKey');
          return Response.ok(jsonEncode({"status": "success", "message": "Session deleted"}), headers: {'content-type': 'application/json'});
        }
        return Response.notFound(jsonEncode({"error": "Session not found"}), headers: {'content-type': 'application/json'});
      });

      app.post('/api/chat', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        final model = data['model'] ?? 'gemini';
        final sessionId = data['session_id'] ?? 'default';
        final sessionKey = "${model}_$sessionId";

        if (extensionWebSockets[model] == null) {
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
            if (extensionWebSockets[model] == null) {
              completer.complete(
                Response(
                  503,
                  body: jsonEncode({"error": "Chrome 插件未连接 ($model)"}),
                  headers: {'content-type': 'application/json'},
                ),
              );
              return;
            }

            Logger.info('Forwarding prompt to $model (session: $sessionId)...');
            final reqCompleter = Completer<Response>();
            pendingRequests[model] = reqCompleter;
            pendingSessionKeys[model] = sessionKey;

            String? targetUrl = sessionUrls[sessionKey];
            String currentUrl = currentExtensionUrls[model] ?? "";
            
            if (targetUrl == null) {
               if (model == 'doubao') targetUrl = 'https://www.doubao.com/chat/';
               else if (model == 'gemini') targetUrl = 'https://gemini.google.com/app';
               else if (model == 'gpt') targetUrl = 'https://chatgpt.com/';
               else if (model == 'glm') targetUrl = 'https://chat.z.ai/';
               else if (model == 'dola') targetUrl = 'https://www.dola.com/';
               else targetUrl = currentUrl;
            }

            if (currentUrl != targetUrl) {
               Logger.info('Navigating to target session URL: $targetUrl');
               extensionWebSockets[model]!.sink.add(jsonEncode({"action": "navigate", "url": targetUrl}));
               
               // Wait for WS to reconnect on the new URL
               int attempts = 0;
               while (attempts < 50) { // 10 seconds timeout
                 await Future.delayed(Duration(milliseconds: 200));
                 if (extensionWebSockets[model] != null && currentExtensionUrls[model] != null) {
                    if (currentExtensionUrls[model] == targetUrl) {
                        break;
                    }
                 }
                 attempts++;
               }
               
               if (attempts >= 50) {
                   throw Exception("Timeout waiting for browser to navigate to session URL");
               }
               // Short delay to let the SPA initialize DOM elements
               await Future.delayed(Duration(milliseconds: 1500));
            }
            
            extensionWebSockets[model]!.sink.add(jsonEncode({"action": "prompt", "text": prompt}));

            final response = await reqCompleter.future;
            completer.complete(response);
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(
                Response.internalServerError(body: jsonEncode({"error": e.toString()}), headers: {'content-type': 'application/json'}),
              );
            }
            pendingRequests.remove(model);
          } finally {
            Logger.info('Model $model cooling down for 6 seconds...');
            await Future.delayed(Duration(seconds: 6));
            Logger.info('Model $model ready for next request.');
          }
        }

        final previousTask = modelQueues[model] ?? Future.value();
        modelQueues[model] = previousTask
            .catchError((_) {})
            .then((_) => process());

        return completer.future;
      });

      final handler = const Pipeline()
          .addMiddleware(customLogRequests())
          .addMiddleware(apiAuthMiddleware(apiKey))
          .addHandler(app.call);

      final server = await io.serve(handler, InternetAddress(host), port);
      Logger.info('HTTP server is starting...');
      Logger.info('Started server process [$pid]');

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
