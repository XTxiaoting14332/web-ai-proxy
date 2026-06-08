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

    ws = web.WebSocket('$wsUrl?model=gemini');

    ws?.addEventListener(
      'message',
      (web.Event event) {
        final msgEvent = event as web.MessageEvent;
        final prompt = msgEvent.data.toString();

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
    final inputElement = web.document.querySelector(
      'div[data-placeholder*="Gemini"]',
    );
    if (inputElement == null) return "Error: Input element not found!";

    final inputArea = inputElement as web.HTMLElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    print("Requesting Background Script to type and hit Enter...");
    
    final completer = Completer<bool>();

    final requestPayload = JSObject()
      ..setProperty('action'.toJS, 'simulateInputAndClick'.toJS)
      ..setProperty('text'.toJS, prompt.toJS)
      ..setProperty('buttonCoords'.toJS, JSObject()
        ..setProperty('x'.toJS, 0.toJS)
        ..setProperty('y'.toJS, 0.toJS));

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
          web.document.querySelector('[aria-label*="Stop"]') ??
          web.document.querySelector('button[aria-label*="停"]') ??
          web.document.querySelector('gem-icon-button[aria-label*="停"]');

      if (stopBtn != null) {
        stableCount = 0;
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      final responseList = web.document.querySelectorAll('model-response');
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

    // 5. 提取所有回复容器并进行逆序清洗
    final responseList = web.document.querySelectorAll('model-response');
    if (responseList.length == 0)
      return "Error: No model-response elements found!";

    web.HTMLElement? lastResponse;
    for (int i = responseList.length - 1; i >= 0; i--) {
      final current = responseList.item(i) as web.HTMLElement;
      final currentText = current.innerText.trim();
      if (currentText.isNotEmpty &&
          currentText != "Gemini 说" &&
          currentText.length > 5) {
        lastResponse = current;
        break;
      }
    }

    if (lastResponse == null) {
      lastResponse =
          responseList.item(responseList.length - 1) as web.HTMLElement;
    }

    // 6. 精准提取正文
    final textContainer =
        lastResponse.querySelector('message-content') ??
        lastResponse.querySelector('.message-content') ??
        lastResponse.querySelector('.markdown') ??
        lastResponse.querySelector('.rt-content') ??
        lastResponse.querySelector('div[class*="content"]');

    if (textContainer != null) {
      final cleanText = (textContainer as web.HTMLElement).innerText.trim();
      if (cleanText.isNotEmpty) {
        return cleanText;
      }
    }

    // 7. 基础非空纯文本兜底
    final fallbackText = lastResponse.innerText
        .replaceAll("Gemini 说", "")
        .trim();
    if (fallbackText.isNotEmpty) {
      return fallbackText;
    }

    return "Error: Failed to extract text. Raw content: " +
        lastResponse.innerText;
  } catch (e, stackTrace) {
    print("Error inside reqAI: $e");
    return "Error caught in script: $e";
  }
}
