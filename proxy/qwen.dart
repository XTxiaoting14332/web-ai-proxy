import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

web.WebSocket? ws;
final Random _random = Random();

void main() {
  print("AI Proxy Plugin Loaded (Qwen).");
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

    ws = web.WebSocket('$wsUrl?model=qwen');

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
            }).toJS,
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
                ws?.send(jsonEncode({
                  "action": "success",
                  "url": web.window.location.href,
                  "response": ans,
                }).toJS);
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
    final textarea = el as web.HTMLTextAreaElement;
    textarea.value = '';
    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    textarea.dispatchEvent(web.Event('input', eventInit));
    textarea.dispatchEvent(web.Event('change', eventInit));
    print('[Cleanup] Input box cleared.');
  } catch (e) {
    print('[Cleanup] Failed to clear input: $e');
  }
}

Future<String?> reqAI(String prompt) async {
  try {
    // Wait for SPA to render the input (chat.qwen.ai/c/ loads asynchronously)
    web.Element? inputElement;
    for (int i = 0; i < 20; i++) {
      inputElement = web.document.querySelector('.message-input-textarea');
      if (inputElement != null) break;
      await Future.delayed(Duration(milliseconds: 500));
    }
    if (inputElement == null) {
      _clearInputBox('.message-input-textarea');
      return jsonEncode({"error": "Input element not found"});
    }

    final inputArea = inputElement as web.HTMLTextAreaElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    await _humanDelay(200, 500);
    inputArea.value = prompt;

    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    inputArea.dispatchEvent(web.Event('input', eventInit));
    print("Input event dispatched.");

    await _humanDelay(400, 900);

    // Wait for send button to become enabled
    web.HTMLElement? sendButton;
    for (int i = 0; i < 20; i++) {
      final btn = web.document.querySelector('.send-button');
      if (btn != null) {
        final btnEl = btn as web.HTMLButtonElement;
        if (!btnEl.disabled) {
          sendButton = btnEl;
          break;
        }
      }
      await Future.delayed(Duration(milliseconds: 200));
    }

    if (sendButton == null) {
      _clearInputBox('.message-input-textarea');
      return jsonEncode({"error": "Send button did not become enabled"});
    }

    // Record response count before sending
    final initialCount = web.document.querySelectorAll('.qwen-markdown').length;

    sendButton.click();
    print("Send button clicked. Waiting for response...");
    await Future.delayed(Duration(seconds: 1));

    // Poll until a new response appears and stabilizes
    String lastText = "";
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
      final responseList = web.document.querySelectorAll('.qwen-markdown');
      if (responseList.length > initialCount) {
        final currentResponse =
            responseList.item(responseList.length - 1) as web.HTMLElement;
        final currentText = currentResponse.innerText.trim();

        if (currentText.isNotEmpty && currentText == lastText) {
          stableCount++;
          if (stableCount >= 6) {
            print("Generation complete.");
            break;
          }
        } else {
          stableCount = 0;
          lastText = currentText;
        }
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    final responseList = web.document.querySelectorAll('.qwen-markdown');
    if (responseList.length <= initialCount) {
      _clearInputBox('.message-input-textarea');
      return jsonEncode({"error": "No response received"});
    }

    final lastResponse =
        responseList.item(responseList.length - 1) as web.HTMLElement;
    final cleanText = lastResponse.innerText.trim();
    return cleanText.isNotEmpty ? cleanText : lastText;
  } catch (e) {
    _clearInputBox('.message-input-textarea');
    print("Error in reqAI: $e");
    return jsonEncode({"error": e.toString()});
  }
}

Future<void> reqAIStream(String prompt) async {
  try {
    web.Element? inputElement;
    for (int i = 0; i < 20; i++) {
      inputElement = web.document.querySelector('.message-input-textarea');
      if (inputElement != null) break;
      await Future.delayed(Duration(milliseconds: 500));
    }
    if (inputElement == null) {
      _clearInputBox('.message-input-textarea');
      ws?.send(jsonEncode({"action": "done", "url": web.window.location.href, "response": "Error: Input element not found"}).toJS);
      return;
    }

    final inputArea = inputElement as web.HTMLTextAreaElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    await _humanDelay(200, 500);
    inputArea.value = prompt;

    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    inputArea.dispatchEvent(web.Event('input', eventInit));

    await _humanDelay(400, 900);

    web.HTMLElement? sendButton;
    for (int i = 0; i < 20; i++) {
      final btn = web.document.querySelector('.send-button');
      if (btn != null) {
        final btnEl = btn as web.HTMLButtonElement;
        if (!btnEl.disabled) {
          sendButton = btnEl;
          break;
        }
      }
      await Future.delayed(Duration(milliseconds: 200));
    }

    if (sendButton == null) {
      _clearInputBox('.message-input-textarea');
      ws?.send(jsonEncode({"action": "done", "url": web.window.location.href, "response": "Error: Send button did not become enabled"}).toJS);
      return;
    }

    final initialCount = web.document.querySelectorAll('.qwen-markdown').length;

    sendButton.click();
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
      final responseList = web.document.querySelectorAll('.qwen-markdown');
      String currentText = "";
      if (responseList.length > initialCount) {
        final currentResponse = responseList.item(responseList.length - 1) as web.HTMLElement;
        currentText = currentResponse.innerText.trim();
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
          if (stableCount >= 6) break;
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
    _clearInputBox('.message-input-textarea');
    ws?.send(jsonEncode({
      "action": "done",
      "url": web.window.location.href,
      "response": "Error: $e",
    }).toJS);
  }
}
