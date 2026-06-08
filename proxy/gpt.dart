import 'dart:async';
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

    ws = web.WebSocket('$wsUrl?model=gpt');

    ws?.addEventListener(
      'message',
      (web.Event event) {
        final msgEvent = event as web.MessageEvent;
        final prompt = msgEvent.data.toString();

        final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
        final runtime = chrome.getProperty('runtime'.toJS) as JSObject;
        runtime.callMethod('sendMessage'.toJS, JSObject()..setProperty('action'.toJS, 'activateTab'.toJS));

        reqAI(prompt).then((answer) {
          ws?.send((answer ?? "Error: reqAI returned null").toJS);
        });
      }.toJS,
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
    print("Searching for input area...");
    final inputElement = web.document.querySelector('#prompt-textarea');
    if (inputElement == null) return "Error: Input element not found!";

    final inputArea = inputElement as web.HTMLElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    print("Requesting Background Script to type and hit Enter...");

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
    print("Physical input and click completed. Waiting for response...");
    await Future.delayed(Duration(seconds: 1));
    print("Monitoring generation status...");
    String lastText = "";
    int stableCount = 0;
    int maxAttempts = 300;

    for (int i = 0; i < maxAttempts; i++) {
      final stopBtn =
          web.document.querySelector('[aria-label*="停"]') ??
          web.document.querySelector('[aria-label*="Stop"]');

      if (stopBtn != null) {
        stableCount = 0;
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      final responseList = web.document.querySelectorAll(
        '[data-message-author-role="assistant"]',
      );
      if (responseList.length > 0) {
        final currentResponse =
            responseList.item(responseList.length - 1) as web.HTMLElement;
        final currentText = currentResponse.innerText.trim();

        if (currentText.isNotEmpty && currentText == lastText) {
          stableCount++;
          if (stableCount >= 3) {
            break;
          }
        } else {
          stableCount = 0;
          lastText = currentText;
        }
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    final responseList = web.document.querySelectorAll(
      '[data-message-author-role="assistant"]',
    );
    if (responseList.length == 0) return "Error: No assistant messages found!";

    final lastResponse =
        responseList.item(responseList.length - 1) as web.HTMLElement;
    final textContainer = lastResponse.querySelector('.markdown');

    if (textContainer != null) {
      final cleanText = (textContainer as web.HTMLElement).innerText.trim();
      if (cleanText.isNotEmpty) {
        return cleanText;
      }
    }

    final fallbackText = lastResponse.innerText.trim();
    if (fallbackText.isNotEmpty) {
      return fallbackText;
    }

    return "Error: Failed to extract text.";
  } catch (e, stackTrace) {
    print("Error inside reqAI: $e");
    return "Error caught in script: $e";
  }
}
