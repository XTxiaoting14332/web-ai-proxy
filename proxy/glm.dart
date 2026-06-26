import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

web.WebSocket? ws;
final Random _random = Random();

void main() {
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

    ws = web.WebSocket('$wsUrl?model=glm');

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
                ws?.send(
                  jsonEncode({
                    "action": "success",
                    "url": web.window.location.href,
                    "response": ans,
                  }).toJS,
                );
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
    print("Searching for input area...");
    final inputElement = web.document.querySelector('#chat-input');
    if (inputElement == null) {
      _clearInputBox('#chat-input');
      return jsonEncode({"error": "Input element not found"});
    }

    final inputArea = inputElement as web.HTMLTextAreaElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    await _humanDelay(400, 1200);
    inputArea.value = prompt;

    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    inputArea.dispatchEvent(web.Event('input', eventInit));
    print("Input event finished.");
    await _humanDelay(600, 1500);

    print("Searching for send button.");
    final sendButtonElement =
        web.document.querySelector('send-message-button') ??
        web.document.querySelector('.send-btn') ??
        web.document.querySelector('button[class*="send"]') ??
        web.document.querySelector('div[class*="send"]');

    if (sendButtonElement == null) {
      _clearInputBox('#chat-input');
      return jsonEncode({"error": "Send button element not found"});
    }

    // Record initial assistant count before sending
    final initialAssistants = web.document.querySelectorAll('.chat-assistant');
    final initialCount = initialAssistants.length;

    final sendButton = sendButtonElement as web.HTMLElement;
    sendButton.click();
    print("Send button clicked. Waiting for response...");

    await Future.delayed(Duration(seconds: 1));
    print("Monitoring generation status...");
    String lastBodyText = "";
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
      final String currentBodyText = web.document.body?.innerText ?? "";

      final bool isThinking =
          currentBodyText.contains("正在思考") || currentBodyText.contains("跳过");

      if (isThinking) {
        stableCount = 0;
        lastBodyText = currentBodyText;
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      bool hasNewProse = false;
      final assistantMessages = web.document.querySelectorAll(
        '.chat-assistant',
      );
      if (assistantMessages.length > initialCount) {
        final lastAssistant =
            assistantMessages.item(assistantMessages.length - 1)
                as web.HTMLElement;
        if (lastAssistant.querySelector('.markdown-prose') != null) {
          hasNewProse = true;
        }
      }

      if (currentBodyText.isNotEmpty && currentBodyText == lastBodyText) {
        if (hasNewProse) {
          stableCount++;
          print("Text status stable count: $stableCount/4");
          if (stableCount >= 4) {
            print("Generation completed.");
            break;
          }
        } else {
          stableCount = 0;
        }
      } else {
        stableCount = 0;
        lastBodyText = currentBodyText;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    final assistantMessages = web.document.querySelectorAll('.chat-assistant');
    if (assistantMessages.length == 0) {
      _clearInputBox('#chat-input');
      return jsonEncode({"error": "No assistant messages found"});
    }

    final lastAssistant =
        assistantMessages.item(assistantMessages.length - 1) as web.HTMLElement;

    final markdownProse =
        lastAssistant.querySelector('.markdown-prose') as web.HTMLElement?;
    if (markdownProse == null) {
      _clearInputBox('#chat-input');
      return jsonEncode({"error": ".markdown-prose container not found"});
    }

    String thinkingText = "";
    final thinkingBlock =
        lastAssistant.querySelector('.thinking-block blockquote') ??
        lastAssistant.querySelector('.thinking-chain-container blockquote');
    if (thinkingBlock != null) {
      thinkingText = (thinkingBlock as web.HTMLElement).innerText.trim();
    }

    final children = markdownProse.children;
    final List<String> textParts = [];

    for (int i = 0; i < children.length; i++) {
      final child = children.item(i) as web.HTMLElement;

      if (child.classList.contains('thinking-chain-container') ||
          child.querySelector('.thinking-chain-container') != null ||
          child.classList.contains('thinking-block') ||
          child.querySelector('.thinking-block') != null) {
        continue;
      }

      final text = child.innerText.trim();
      if (text.isNotEmpty) {
        if (thinkingText.isNotEmpty && text.contains(thinkingText)) {
          // If the thinking text is somehow fully embedded inside a single child text block
          final replaced = text.replaceFirst(thinkingText, '').trim();
          if (replaced.isNotEmpty) {
            textParts.add(replaced);
          }
        } else {
          textParts.add(text);
        }
      }
    }

    String answerText = textParts.isNotEmpty ? textParts.join('\n\n') : "";

    // 降级正文提取兜底方案
    if (answerText.isEmpty) {
      answerText = markdownProse.innerText
          .replaceAll("思考过程", "")
          .replaceAll("收起", "")
          .replaceAll(thinkingText, "")
          .trim();
    }

    final Map<String, String> responseMap = {
      "thinking": thinkingText,
      "answer": answerText,
    };

    return jsonEncode(responseMap);
  } catch (e, stackTrace) {
    _clearInputBox('#chat-input');
    print("Error inside reqAI: $e");
    return jsonEncode({"error": e.toString()});
  }
}

Future<void> reqAIStream(String prompt) async {
  try {
    final inputElement = web.document.querySelector('#chat-input');
    if (inputElement == null) {
      _clearInputBox('#chat-input');
      ws?.send(jsonEncode({"action": "done", "url": web.window.location.href, "response": "Error: Input element not found"}).toJS);
      return;
    }

    final inputArea = inputElement as web.HTMLTextAreaElement;
    await _humanDelay(300, 800);
    inputArea.focus();

    await _humanDelay(400, 1200);
    inputArea.value = prompt;

    final eventInit = web.EventInit()
      ..bubbles = true
      ..cancelable = true;
    inputArea.dispatchEvent(web.Event('input', eventInit));
    await _humanDelay(600, 1500);

    final sendButtonElement =
        web.document.querySelector('send-message-button') ??
        web.document.querySelector('.send-btn') ??
        web.document.querySelector('button[class*="send"]') ??
        web.document.querySelector('div[class*="send"]');

    if (sendButtonElement == null) {
      _clearInputBox('#chat-input');
      ws?.send(jsonEncode({"action": "done", "url": web.window.location.href, "response": "Error: Send button element not found"}).toJS);
      return;
    }

    final initialAssistants = web.document.querySelectorAll('.chat-assistant');
    final initialCount = initialAssistants.length;

    final sendButton = sendButtonElement as web.HTMLElement;
    sendButton.click();

    await Future.delayed(Duration(seconds: 1));

    String lastSentText = "";
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
      final String bodyText = web.document.body?.innerText ?? "";

      final bool isThinking =
          bodyText.contains("正在思考") || bodyText.contains("跳过");

      if (isThinking) {
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      final assistantMessages = web.document.querySelectorAll('.chat-assistant');
      String currentText = "";
      if (assistantMessages.length > initialCount) {
        final lastAssistant =
            assistantMessages.item(assistantMessages.length - 1)
                as web.HTMLElement;
        final markdownProse = lastAssistant.querySelector('.markdown-prose') as web.HTMLElement?;
        
        if (markdownProse != null) {
          final children = markdownProse.children;
          final List<String> textParts = [];

          for (int j = 0; j < children.length; j++) {
            final child = children.item(j) as web.HTMLElement;

            if (child.classList.contains('thinking-chain-container') ||
                child.querySelector('.thinking-chain-container') != null ||
                child.classList.contains('thinking-block') ||
                child.querySelector('.thinking-block') != null) {
              continue;
            }

            final text = child.innerText.trim();
            if (text.isNotEmpty) {
              textParts.add(text);
            }
          }
          currentText = textParts.join('\n\n');
          if (currentText.isEmpty) {
            currentText = markdownProse.innerText.trim();
          }
        }
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
          if (stableCount >= 4) break;
        }
      } else {
        stableCount = 0;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    String thinkingText = "";
    final assistantMessages = web.document.querySelectorAll('.chat-assistant');
    if (assistantMessages.length > initialCount) {
      final lastAssistant = assistantMessages.item(assistantMessages.length - 1) as web.HTMLElement;
      final thinkingBlock = lastAssistant.querySelector('.thinking-block blockquote') ??
          lastAssistant.querySelector('.thinking-chain-container blockquote');
      if (thinkingBlock != null) {
        thinkingText = (thinkingBlock as web.HTMLElement).innerText.trim();
      }
    }

    final doneResponse = jsonEncode({"thinking": thinkingText, "answer": lastSentText});
    ws?.send(jsonEncode({
      "action": "done",
      "url": web.window.location.href,
      "response": doneResponse,
    }).toJS);

  } catch (e) {
    _clearInputBox('#chat-input');
    ws?.send(jsonEncode({
      "action": "done",
      "url": web.window.location.href,
      "response": "Error: $e",
    }).toJS);
  }
}
