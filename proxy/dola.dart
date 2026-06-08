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

    ws = web.WebSocket('$wsUrl?model=dola');

    ws?.addEventListener(
      'open',
      ((web.Event event) {
        ws?.send(jsonEncode({
          "action": "register",
          "url": web.window.location.href,
        }).toJS);
      }).toJS,
    );

    ws?.addEventListener(
      'message',
      ((web.Event event) {
        void handleMessage() async {
          final msgEvent = event as web.MessageEvent;
          final payload = msgEvent.data.toString();
          String prompt = payload;
          try {
            final data = jsonDecode(payload);
            if (data['action'] == 'navigate') {
               web.window.location.href = data['url'];
               return;
            }
            if (data['action'] == 'prompt') {
               prompt = data['text'];
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
            }).toJS
          );
          
          await completer.future;
          await Future.delayed(Duration(milliseconds: 300));

          reqAI(prompt).then((answer) {
            String ans = answer ?? "Error";
            try {
               final data = jsonDecode(ans);
               data['url'] = web.window.location.href;
               data['action'] = 'success';
               ws?.send(jsonEncode(data).toJS);
            } catch (_) {
               ws?.send(jsonEncode({"action": "success", "url": web.window.location.href, "response": ans}).toJS);
            }
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
    final inputElement = web.document.querySelector('.semi-input-textarea');
    if (inputElement == null) return "Error: Input element not found.";

    final inputArea = inputElement as web.HTMLElement;
    await _humanDelay(300, 800);
    inputArea.focus();

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
      completer.complete(true);
    }).toJS;

    runtime.callMethod('sendMessage'.toJS, requestPayload, callback);

    await completer.future;
    await Future.delayed(Duration(seconds: 1));

    String lastText = "";
    int stableCount = 0;
    int maxAttempts = 300;

    for (int i = 0; i < maxAttempts; i++) {

      final responseList = web.document.querySelectorAll('.flow-markdown-body');
      if (responseList.length > 0) {
        final currentResponse =
            responseList.item(responseList.length - 1) as web.HTMLElement;
        final currentText = currentResponse.innerText.trim();

        if (currentText.isNotEmpty && currentText == lastText) {
          stableCount++;
          if (stableCount >= 10) {
            break;
          }
        } else {
          stableCount = 0;
          lastText = currentText;
        }
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    final responseList = web.document.querySelectorAll('.flow-markdown-body');
    if (responseList.length > 0) {
      final lastResponse = responseList.item(responseList.length - 1) as web.HTMLElement;
      final cleanText = lastResponse.innerText.trim();
      if (cleanText.isNotEmpty) {
        return cleanText;
      }
    }

    return lastText;
  } catch (e, stackTrace) {
    return "Error caught in script: $e";
  }
}
