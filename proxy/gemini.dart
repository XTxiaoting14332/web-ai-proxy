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

    ws = web.WebSocket('$wsUrl?model=gemini');

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
          bool sseMode = false;
          try {
            final data = jsonDecode(payload);
            if (data['action'] == 'navigate') {
               web.window.location.href = data['url'];
               return;
            }
            if (data['action'] == 'prompt') {
               prompt = data['text'];
               sseMode = data['sse'] == true;
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

          if (sseMode) {
            reqAIStream(prompt);
          } else {
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

void _clearInputBox(String selector) {
  try {
    final el = web.document.querySelector(selector);
    if (el == null) return;
    final div = el as web.HTMLElement;
    div.innerText = '';
    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    div.dispatchEvent(web.Event('input', eventInit));
    div.dispatchEvent(web.Event('change', eventInit));
    print('[Cleanup] Input box cleared.');
  } catch (e) {
    print('[Cleanup] Failed to clear input: $e');
  }
}

Future<String?> reqAI(String prompt) async {
  try {
    print("Searching for input area...");
    final inputElement = web.document.querySelector(
      'div[data-placeholder*="Gemini"]',
    );
    if (inputElement == null) {
      _clearInputBox('div[data-placeholder*="Gemini"]');
      return "Error: Input element not found!";
    }

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
    int maxAttempts = 180;

    for (int i = 0; i < maxAttempts; i++) {
      // 新增：弹窗检测
      final dialogs = web.document.querySelectorAll('dialog[open], [role="dialog"], .modal, .overlay');
      if (dialogs.length > 0) {
        bool closed = false;
        final closeBtns = web.document.querySelectorAll('button');
        for (int b = 0; b < closeBtns.length; b++) {
          final btn = closeBtns.item(b) as web.HTMLElement;
          final btnText = btn.innerText.toLowerCase();
          if (btnText.contains('close') || btnText.contains('关闭') || btnText.contains('确定') || btnText.contains('ok')) {
            btn.click();
            closed = true;
            break;
          }
        }
        if (!closed) {
          ws?.send(jsonEncode({"action": "error", "message": "网页出现弹窗拦截且无法自动关闭"}).toJS);
          throw Exception("Popup blocked");
        }
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
    if (responseList.length == 0) {
      _clearInputBox('div[data-placeholder*="Gemini"]');
      return "Error: No model-response elements found!";
    }

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

    _clearInputBox('div[data-placeholder*="Gemini"]');
    return "Error: Failed to extract text. Raw content: " +
        lastResponse.innerText;
  } catch (e, stackTrace) {
    _clearInputBox('div[data-placeholder*="Gemini"]');
    print("Error inside reqAI: $e");
    return "Error caught in script: $e";
  }
}

Future<void> reqAIStream(String prompt) async {
  try {
    final inputElement = web.document.querySelector('div[data-placeholder*="Gemini"]');
    if (inputElement == null) {
      _clearInputBox('div[data-placeholder*="Gemini"]');
      ws?.send(jsonEncode({"action": "done", "url": web.window.location.href, "response": "Error: Input element not found!"}).toJS);
      return;
    }
    final inputArea = inputElement as web.HTMLElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    final completer = Completer<bool>();
    final requestPayload = JSObject()
      ..setProperty('action'.toJS, 'simulateInputAndClick'.toJS)
      ..setProperty('text'.toJS, prompt.toJS)
      ..setProperty('buttonCoords'.toJS, JSObject()
        ..setProperty('x'.toJS, 0.toJS)
        ..setProperty('y'.toJS, 0.toJS));

    final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
    final runtime = chrome.getProperty('runtime'.toJS) as JSObject;
    runtime.callMethod('sendMessage'.toJS, requestPayload, ((JSObject _) {
      completer.complete(true);
    }).toJS);

    await completer.future;
    await Future.delayed(Duration(seconds: 1));

    String lastSentText = "";
    int stableCount = 0;
    const int maxAttempts = 180;

    for (int i = 0; i < maxAttempts; i++) {
      // 新增：弹窗检测
      final dialogs = web.document.querySelectorAll('dialog[open], [role="dialog"], .modal, .overlay');
      if (dialogs.length > 0) {
        bool closed = false;
        final closeBtns = web.document.querySelectorAll('button');
        for (int b = 0; b < closeBtns.length; b++) {
          final btn = closeBtns.item(b) as web.HTMLElement;
          final btnText = btn.innerText.toLowerCase();
          if (btnText.contains('close') || btnText.contains('关闭') || btnText.contains('确定') || btnText.contains('ok')) {
            btn.click();
            closed = true;
            break;
          }
        }
        if (!closed) {
          ws?.send(jsonEncode({"action": "error", "message": "网页出现弹窗拦截且无法自动关闭"}).toJS);
          throw Exception("Popup blocked");
        }
      }
      final responseList = web.document.querySelectorAll('model-response');
      String currentText = "";
      if (responseList.length > 0) {
        final el = responseList.item(responseList.length - 1) as web.HTMLElement;
        currentText = el.innerText.trim();
      }

      if (currentText.isNotEmpty) {
        if (currentText != lastSentText) {
          String delta = '';
          if (currentText.startsWith(lastSentText)) {
            delta = currentText.substring(lastSentText.length);
          } else {
            delta = currentText;
          }
          if (delta.isNotEmpty) {
            ws?.send(jsonEncode({"action": "chunk", "delta": delta}).toJS);
          }
          lastSentText = currentText;
          stableCount = 0;
        } else {
          stableCount++;
          if (stableCount >= 3) break;
        }
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    ws?.send(jsonEncode({
      "action": "done",
      "url": web.window.location.href,
      "response": lastSentText,
    }).toJS);

  } catch (e) {
    _clearInputBox('div[data-placeholder*="Gemini"]');
    ws?.send(jsonEncode({
      "action": "done",
      "url": web.window.location.href,
      "response": "Error: $e",
    }).toJS);
  }
}
