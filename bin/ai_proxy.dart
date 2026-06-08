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
  runZonedGuarded(
    () async {
      final configFile = File('config.json');
      late Map<String, dynamic> config;

      if (!configFile.existsSync()) {
        final newApiKey = Uuid().v4().substring(0, 8);
        config = {'host': '127.0.0.1', 'port': 8080, 'api_key': newApiKey};
        configFile.writeAsStringSync(
          JsonEncoder.withIndent('  ').convert(config),
        );
        Logger.success('Generated default config.json. API Key: $newApiKey');
      } else {
        final content = configFile.readAsStringSync();
        config = jsonDecode(content);
        Logger.info('Loaded existing config.json.');
      }

      final host = config['host'] ?? '127.0.0.1';
      final port = config['port'] ?? 8080;
      final apiKey = config['api_key'] ?? '';

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
              if (pendingRequests[model] != null &&
                  !pendingRequests[model]!.isCompleted) {
                Logger.debug('Received reply from model: $model');

                String? thinking;
                String finalResponse = message.toString();

                try {
                  final decoded = jsonDecode(finalResponse);
                  if (decoded is Map<String, dynamic>) {
                    if (decoded.containsKey("answer")) {
                      finalResponse = decoded["answer"].toString();
                    }
                    if (decoded.containsKey("thinking") &&
                        decoded["thinking"].toString().isNotEmpty) {
                      thinking = decoded["thinking"].toString();
                    }
                  }
                } catch (_) {
                  // If it's not JSON, treat it as a raw string
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
            },
            onDone: () {
              Logger.warn('WebSocket connection closed for model: $model');
              extensionWebSockets.remove(model);
            },
            onError: (error) {
              Logger.error('WebSocket error for model $model: $error');
              extensionWebSockets.remove(model);
            },
          );
        });

        return handler(request);
      });

      app.post('/api/chat', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        final model = data['model'] ?? 'gemini';

        if (extensionWebSockets[model] == null) {
          Logger.error('Chrome plugin not connected for model: $model');
          return Response(
            503,
            body: jsonEncode({"error": "Chrome 插件未连接 ($model)"}),
            headers: {'content-type': 'application/json'},
          );
        }

        final prompt = data['prompt'] ?? '';
        Logger.info('Queuing prompt for $model...');

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

            Logger.info('Forwarding prompt to $model...');
            final reqCompleter = Completer<Response>();
            pendingRequests[model] = reqCompleter;

            extensionWebSockets[model]!.sink.add(prompt);

            final response = await reqCompleter.future;
            completer.complete(response);
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(
                Response.internalServerError(body: e.toString()),
              );
            }
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
