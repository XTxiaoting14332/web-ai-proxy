import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

web.WebSocket? ws;
final Random _random = Random();

void main() {
  print("AI Proxy Plugin Loaded.");
  initWebSocket();
}

void initWebSocket() {
  final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
  final storage = chrome.getProperty('storage'.toJS) as JSObject;
  final local = storage.getProperty('local'.toJS) as JSObject;

  final getCallback = ((JSObject result) {
    final urlObj = result.getProperty('wsUrl'.toJS);
    String wsUrl = 'ws://127.0.0.1:8080/ws';
    if (urlObj != null && !urlObj.isUndefined) {
      wsUrl = (urlObj as JSString).toDart;
    }

    ws = web.WebSocket('$wsUrl?model=doubao');

    ws?.addEventListener(
      'open',
      ((web.Event event) {
        ws?.send(
          jsonEncode({
            "action": "register",
            "url": web.window.location.href,
          }).toJS,
        );
      }).toJS,
    );

    ws?.addEventListener(
      'message',
      ((web.Event event) {
        void handleMessage() async {
          final msgEvent = event as web.MessageEvent;
          final payload = msgEvent.data.toString();
          print("[DOUBAO-DEBUG] Received WS message: $payload");
          String prompt = payload;
          try {
            final data = jsonDecode(payload);
            if (data['action'] == 'navigate') {
              print("[DOUBAO-DEBUG] Navigate action, going to: ${data['url']}");
              web.window.location.href = data['url'];
              return;
            }
            if (data['action'] == 'prompt') {
              prompt = data['text'];
              print("[DOUBAO-DEBUG] Prompt: $prompt");
            }
          } catch (_) {}

          final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
          final runtime = chrome.getProperty('runtime'.toJS) as JSObject;

          final completer = Completer<void>();
          runtime.callMethod(
            'sendMessage'.toJS,
            JSObject()..setProperty('action'.toJS, 'activateTab'.toJS),
            ((JSObject _) {
              completer.complete();
            }).toJS,
          );

          await completer.future;
          await Future.delayed(Duration(milliseconds: 300));

          reqAI(prompt).then((answer) {
            String ans = answer ?? "Error";
            print(
              "[DOUBAO-DEBUG] reqAI returned: ${ans.length > 100 ? ans.substring(0, 100) + '...' : ans}",
            );
            try {
              final data = jsonDecode(ans);
              data['url'] = web.window.location.href;
              data['action'] = 'success';
              ws?.send(jsonEncode(data).toJS);
            } catch (_) {
              ws?.send(
                jsonEncode({
                  "action": "success",
                  "url": web.window.location.href,
                  "response": ans,
                }).toJS,
              );
            }
            print("[DOUBAO-DEBUG] WS send completed");
          });
        }

        handleMessage();
      }).toJS,
    );

    ws?.addEventListener(
      'close',
      (web.Event e) {
        print("Reconnect in 3s...");
        Timer(Duration(seconds: 3), () => initWebSocket());
      }.toJS,
    );

    ws?.addEventListener(
      'error',
      (web.Event e) {
        print("WebSocket error occurred, will retry...");
      }.toJS,
    );

    ws?.addEventListener(
      'open',
      (web.Event e) {
        print("WebSocket connected successfully!");
      }.toJS,
    );
  }).toJS;

  local.callMethod('get'.toJS, ['wsUrl'.toJS].toJS, getCallback);
}

Future<void> _humanDelay(int minMs, int maxMs) async {
  final int delay = minMs + _random.nextInt(maxMs - minMs);
  await Future.delayed(Duration(milliseconds: delay));
}

Future<String?> reqAI(String prompt) async {
  try {
    print("[DOUBAO-DEBUG] reqAI START");

    // Poll for the input element
    web.Element? inputElement;
    for (int attempt = 0; attempt < 20; attempt++) {
      inputElement = web.document.querySelector('.semi-input-textarea');
      if (inputElement != null) {
        print("[DOUBAO-DEBUG] Found input element on attempt $attempt");
        break;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    if (inputElement == null) {
      return "Error: Input element not found.";
    }

    final inputArea = inputElement as web.HTMLElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    // Capture body text BEFORE sending, so we can detect new content
    final String bodyTextBefore = web.document.body?.innerText ?? "";
    print("[DOUBAO-DEBUG] Body text length before: ${bodyTextBefore.length}");

    // Use background script to type and send via Chrome Debugger
    print("[DOUBAO-DEBUG] Sending simulateInputAndClick...");
    final completer = Completer<bool>();
    final requestPayload = JSObject()
      ..setProperty('action'.toJS, 'simulateInputAndClick'.toJS)
      ..setProperty('text'.toJS, prompt.toJS)
      ..setProperty(
        'buttonCoords'.toJS,
        JSObject()
          ..setProperty('x'.toJS, 0.toJS)
          ..setProperty('y'.toJS, 0.toJS),
      );

    final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
    final runtime = chrome.getProperty('runtime'.toJS) as JSObject;

    final callback = ((JSObject response) {
      print("[DOUBAO-DEBUG] simulateInputAndClick done");
      completer.complete(true);
    }).toJS;

    runtime.callMethod('sendMessage'.toJS, requestPayload, callback);
    await completer.future;

    print("[DOUBAO-DEBUG] Waiting for response generation...");
    await Future.delayed(Duration(seconds: 2));

    // === Phase 1: Monitor page body text for stability (like GLM approach) ===
    String lastBodyText = "";
    int stableCount = 0;
    int maxAttempts = 120; // 60 seconds

    for (int i = 0; i < maxAttempts; i++) {
      final String currentBodyText = web.document.body?.innerText ?? "";

      // Check if Doubao is still "thinking"
      final bool isThinking =
          currentBodyText.contains("正在思考") ||
          currentBodyText.contains("正在搜索") ||
          currentBodyText.contains("跳过");

      if (isThinking) {
        stableCount = 0;
        lastBodyText = currentBodyText;
        if (i % 10 == 0) {
          print("[DOUBAO-DEBUG] Poll #$i: Doubao is thinking...");
        }
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      if (currentBodyText.isNotEmpty && currentBodyText == lastBodyText) {
        stableCount++;
        if (i % 10 == 0 || stableCount >= 3) {
          print(
            "[DOUBAO-DEBUG] Poll #$i: stable=$stableCount/5, bodyLen=${currentBodyText.length}",
          );
        }
        if (stableCount >= 5) {
          // 2.5 seconds of stability
          print("[DOUBAO-DEBUG] Body text stable. Generation complete.");
          break;
        }
      } else {
        stableCount = 0;
        lastBodyText = currentBodyText;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    // === Phase 2: Extract the actual response text ===
    print("[DOUBAO-DEBUG] Extracting response...");

    // Try .flow-markdown-body first
    final responseList = web.document.querySelectorAll('.flow-markdown-body');
    print("[DOUBAO-DEBUG] .flow-markdown-body count: ${responseList.length}");

    if (responseList.length > 0) {
      final lastResponse =
          responseList.item(responseList.length - 1) as web.HTMLElement;
      final cleanText = lastResponse.innerText.trim();
      if (cleanText.isNotEmpty) {
        print(
          "[DOUBAO-DEBUG] Extracted via .flow-markdown-body: ${cleanText.length} chars",
        );
        return cleanText;
      }
    }

    // Fallback: try to extract from receive-message-action-bar's preceding sibling
    final msgContainers = web.document.querySelectorAll(
      '[data-container-type="block-v2"]',
    );
    print("[DOUBAO-DEBUG] block-v2 containers: ${msgContainers.length}");
    if (msgContainers.length > 0) {
      final lastContainer =
          msgContainers.item(msgContainers.length - 1) as web.HTMLElement;
      final text = lastContainer.innerText.trim();
      if (text.isNotEmpty) {
        print("[DOUBAO-DEBUG] Extracted via block-v2: ${text.length} chars");
        return text;
      }
    }

    // Last resort: diff body text
    final bodyTextAfter = web.document.body?.innerText ?? "";
    if (bodyTextAfter.length > bodyTextBefore.length) {
      // Try to find the new text that appeared
      print(
        "[DOUBAO-DEBUG] Body text grew by ${bodyTextAfter.length - bodyTextBefore.length} chars, returning diff",
      );
      return "Error: Could not extract response cleanly. Body text length: ${bodyTextAfter.length}";
    }

    return "Error: No response detected.";
  } catch (e, stackTrace) {
    print("[DOUBAO-DEBUG] EXCEPTION: $e");
    return "Error caught in script: $e";
  }
}
