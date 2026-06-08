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
    final inputElement = web.document.querySelector('#chat-input');
    if (inputElement == null)
      return jsonEncode({"error": "Input element not found"});

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

    if (sendButtonElement == null)
      return jsonEncode({"error": "Send button element not found"});

    final sendButton = sendButtonElement as web.HTMLElement;
    sendButton.click();
    print("Send button clicked. Waiting for response...");

    await Future.delayed(Duration(seconds: 1));
    print("Monitoring generation status...");
    String lastBodyText = "";
    int stableCount = 0;
    int maxAttempts = 360;

    for (int i = 0; i < maxAttempts; i++) {
      final String currentBodyText = web.document.body?.innerText ?? "";

      final bool isThinking =
          currentBodyText.contains("正在思考") ||
          currentBodyText.contains("跳过") ||
          web.document.querySelector('[aria-label*="停"]') != null ||
          web.document.querySelector('[aria-label*="Stop"]') != null;

      if (isThinking) {
        stableCount = 0;
        lastBodyText = currentBodyText;
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      if (currentBodyText.isNotEmpty && currentBodyText == lastBodyText) {
        stableCount++;
        print("Text status stable count: $stableCount/4");
        if (stableCount >= 4) {
          print("Generation completed.");
          break;
        }
      } else {
        stableCount = 0;
        lastBodyText = currentBodyText;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    final assistantMessages = web.document.querySelectorAll('.chat-assistant');
    if (assistantMessages.length == 0)
      return jsonEncode({"error": "No assistant messages found"});

    final lastAssistant =
        assistantMessages.item(assistantMessages.length - 1) as web.HTMLElement;

    final markdownProse =
        lastAssistant.querySelector('.markdown-prose') as web.HTMLElement?;
    if (markdownProse == null) {
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
          child.classList.contains('thinking-block')) {
        continue;
      }

      final text = child.innerText.trim();
      if (text.isNotEmpty) {
        textParts.add(text);
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
    print("Error inside reqAI: $e");
    return jsonEncode({"error": e.toString()});
  }
}
