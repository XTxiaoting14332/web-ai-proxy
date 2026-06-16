import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('chrome')
external JSObject get chrome;

Future<JSAny?> sendDebuggerCommand(
  JSObject target,
  String method, [
  JSObject? params,
]) {
  final completer = Completer<JSAny?>();

  final debugger = chrome.getProperty('debugger'.toJS) as JSObject;

  final callback = ((JSAny? result) {
    final runtime = chrome.getProperty('runtime'.toJS) as JSObject;
    final lastError = runtime.getProperty('lastError'.toJS);
    if (lastError != null) {
      completer.completeError(lastError);
    } else {
      completer.complete(result);
    }
  }).toJS;

  if (params != null) {
    debugger.callMethod(
      'sendCommand'.toJS,
      target,
      method.toJS,
      params,
      callback,
    );
  } else {
    debugger.callMethod('sendCommand'.toJS, target, method.toJS, callback);
  }

  return completer.future;
}

Future<void> attachDebugger(JSObject target) {
  final completer = Completer<void>();
  final debugger = chrome.getProperty('debugger'.toJS) as JSObject;
  debugger.callMethod(
    'attach'.toJS,
    target,
    "1.3".toJS,
    (() {
      completer.complete();
    }).toJS,
  );
  return completer.future;
}

Future<void> detachDebugger(JSObject target) {
  final completer = Completer<void>();
  final debugger = chrome.getProperty('debugger'.toJS) as JSObject;
  debugger.callMethod(
    'detach'.toJS,
    target,
    (() {
      completer.complete();
    }).toJS,
  );
  return completer.future;
}

// Track which tabId belongs to which model
Map<String, int> modelTabIds = {};

void main() {
  print("Background Service Worker loaded!");

  final runtime = chrome.getProperty('runtime'.toJS) as JSObject;
  final onMessage = runtime.getProperty('onMessage'.toJS) as JSObject;

  final listener =
      ((JSObject request, JSObject sender, JSFunction sendResponse) {
        final action = request.getProperty('action'.toJS) as JSString?;

        if (action != null && action.toDart == "activateTab") {
          final tab = sender.getProperty('tab'.toJS) as JSObject?;
          if (tab != null) {
            final tabId = tab.getProperty('id'.toJS) as JSNumber;
            final windowId = tab.getProperty('windowId'.toJS) as JSNumber;

            // Detect model from tab URL to track tabId
            final tabUrl = tab.getProperty('url'.toJS) as JSString?;
            if (tabUrl != null) {
              final url = tabUrl.toDart;
              String? model;
              if (url.contains('chat.z.ai')) model = 'glm';
              else if (url.contains('gemini.google.com')) model = 'gemini';
              else if (url.contains('chatgpt.com')) model = 'gpt';
              else if (url.contains('www.doubao.com')) model = 'doubao';
              else if (url.contains('www.dola.com')) model = 'dola';
              else if (url.contains('chat.qwen.ai')) model = 'qwen';
              else if (url.contains('www.kimi.com')) model = 'kimi';
              if (model != null) {
                modelTabIds[model] = tabId.toDartInt;
                print("Tracked tab $tabId for model $model");
              }
            }

            final chromeTabs = chrome.getProperty('tabs'.toJS) as JSObject;
            chromeTabs.callMethod('update'.toJS, tabId, JSObject()..setProperty('active'.toJS, true.toJS));
            final chromeWindows = chrome.getProperty('windows'.toJS) as JSObject;
            chromeWindows.callMethod('update'.toJS, windowId, JSObject()..setProperty('focused'.toJS, true.toJS));
          }
          sendResponse.callAsFunction(null, JSObject()..setProperty('success'.toJS, true.toJS));
          return true.toJS;
        }

        if (action != null && action.toDart == "simulateInputAndClick") {
          final tab = sender.getProperty('tab'.toJS) as JSObject?;
          if (tab == null) return false.toJS;

          final tabId = tab.getProperty('id'.toJS) as JSNumber;
          final target = JSObject()..setProperty('tabId'.toJS, tabId);

          final text = (request.getProperty('text'.toJS) as JSString).toDart;
          final coords = request.getProperty('buttonCoords'.toJS) as JSObject;
          final x = coords.getProperty('x'.toJS) as JSNumber;
          final y = coords.getProperty('y'.toJS) as JSNumber;

          _performPhysicalInput(target, text, x.toDartDouble, y.toDartDouble)
              .then((_) {
                sendResponse.callAsFunction(
                  null,
                  JSObject()..setProperty('success'.toJS, true.toJS),
                );
              })
              .catchError((e) {
                sendResponse.callAsFunction(
                  null,
                  JSObject()
                    ..setProperty('success'.toJS, false.toJS)
                    ..setProperty('error'.toJS, e.toString().toJS),
                );
              });

          return true.toJS;
        }
        return false.toJS;
      }).toJS;

  onMessage.callMethod('addListener'.toJS, listener);

  // Connect to backend as manager for tab lifecycle commands
  initManagerWebSocket();

  // Keep the service worker alive with a periodic alarm
  final alarms = chrome.getProperty('alarms'.toJS) as JSObject;
  alarms.callMethod(
    'create'.toJS,
    'keepalive'.toJS,
    JSObject()..setProperty('periodInMinutes'.toJS, 0.4.toJS),
  );
  (alarms.getProperty('onAlarm'.toJS) as JSObject)
      .callMethod('addListener'.toJS, ((JSObject _) {}).toJS);
}

web.WebSocket? _managerWs;

void initManagerWebSocket() {
  final ctx = globalContext;
  final chromeObj = ctx.getProperty('chrome'.toJS) as JSObject;
  final local = (chromeObj.getProperty('storage'.toJS) as JSObject)
      .getProperty('local'.toJS) as JSObject;

  final getCallback = ((JSObject result) {
    final urlObj = result.getProperty('wsUrl'.toJS);
    String wsUrl = 'ws://127.0.0.1:8080/ws';
    if (urlObj != null && !urlObj.isUndefined) {
      wsUrl = (urlObj as JSString).toDart;
    }

    _managerWs = web.WebSocket('$wsUrl?model=_manager');

    _managerWs?.addEventListener(
      'message',
      ((web.Event event) {
        final payload = (event as web.MessageEvent).data.toString();
        try {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          if (data['action'] == 'open_tab') {
            final url = data['url']?.toString() ?? '';
            if (url.isNotEmpty) {
              final tabs = (globalContext.getProperty('chrome'.toJS) as JSObject)
                  .getProperty('tabs'.toJS) as JSObject;
              final createCallback = ((JSObject newTab) {
                final newTabId = (newTab.getProperty('id'.toJS) as JSNumber).toDartInt;
                // Detect model from URL to track the new tab
                String? model;
                if (url.contains('chat.z.ai')) model = 'glm';
                else if (url.contains('gemini.google.com')) model = 'gemini';
                else if (url.contains('chatgpt.com')) model = 'gpt';
                else if (url.contains('www.doubao.com')) model = 'doubao';
                else if (url.contains('www.dola.com')) model = 'dola';
                else if (url.contains('chat.qwen.ai')) model = 'qwen';
                else if (url.contains('www.kimi.com')) model = 'kimi';
                if (model != null) {
                  modelTabIds[model] = newTabId;
                  print("Tracked new tab $newTabId for model $model");
                }
              }).toJS;
              tabs.callMethod(
                'create'.toJS,
                JSObject()..setProperty('url'.toJS, url.toJS),
                createCallback,
              );
            }
          } else if (data['action'] == 'close_tab') {
            final model = data['model']?.toString() ?? '';
            if (model.isNotEmpty && modelTabIds.containsKey(model)) {
              final tabId = modelTabIds[model]!;
              print("Closing tab $tabId for idle model $model");
              final tabs = (globalContext.getProperty('chrome'.toJS) as JSObject)
                  .getProperty('tabs'.toJS) as JSObject;
              tabs.callMethod('remove'.toJS, tabId.toJS);
              modelTabIds.remove(model);
            } else {
              print("No tracked tab for model $model, skipping close");
            }
          }
        } catch (_) {}
      }).toJS,
    );

    _managerWs?.addEventListener(
      'close',
      (web.Event _) {
        Timer(Duration(seconds: 3), initManagerWebSocket);
      }.toJS,
    );

    _managerWs?.addEventListener(
      'error',
      (web.Event _) {
        print("Manager WebSocket error, will retry...");
      }.toJS,
    );
  }).toJS;

  local.callMethod('get'.toJS, ['wsUrl'.toJS].toJS, getCallback);
}

Future<void> _performPhysicalInput(
  JSObject target,
  String text,
  double x,
  double y,
) async {
  await attachDebugger(target);

  for (int i = 0; i < text.length; i++) {
    if (text[i] == '\n') {
      await sendDebuggerCommand(
        target,
        "Input.dispatchKeyEvent",
        JSObject()
          ..setProperty('type'.toJS, 'keyDown'.toJS)
          ..setProperty('key'.toJS, 'Enter'.toJS)
          ..setProperty('code'.toJS, 'Enter'.toJS)
          ..setProperty('modifiers'.toJS, 8.toJS)
          ..setProperty('windowsVirtualKeyCode'.toJS, 13.toJS)
          ..setProperty('nativeVirtualKeyCode'.toJS, 13.toJS)
          ..setProperty('text'.toJS, '\r'.toJS),
      );
      await sendDebuggerCommand(
        target,
        "Input.dispatchKeyEvent",
        JSObject()
          ..setProperty('type'.toJS, 'keyUp'.toJS)
          ..setProperty('key'.toJS, 'Enter'.toJS)
          ..setProperty('code'.toJS, 'Enter'.toJS)
          ..setProperty('modifiers'.toJS, 8.toJS)
          ..setProperty('windowsVirtualKeyCode'.toJS, 13.toJS)
          ..setProperty('nativeVirtualKeyCode'.toJS, 13.toJS),
      );
    } else {
      await sendDebuggerCommand(
        target,
        "Input.dispatchKeyEvent",
        JSObject()
          ..setProperty('type'.toJS, 'char'.toJS)
          ..setProperty('text'.toJS, text[i].toJS),
      );
    }
    await Future.delayed(Duration(milliseconds: 20));
  }

  await Future.delayed(Duration(milliseconds: 300));

  // 发送回车键
  await sendDebuggerCommand(
    target,
    "Input.dispatchKeyEvent",
    JSObject()
      ..setProperty('type'.toJS, 'keyDown'.toJS)
      ..setProperty('key'.toJS, 'Enter'.toJS)
      ..setProperty('code'.toJS, 'Enter'.toJS)
      ..setProperty('windowsVirtualKeyCode'.toJS, 13.toJS)
      ..setProperty('nativeVirtualKeyCode'.toJS, 13.toJS)
      ..setProperty('text'.toJS, '\r'.toJS),
  );

  await sendDebuggerCommand(
    target,
    "Input.dispatchKeyEvent",
    JSObject()
      ..setProperty('type'.toJS, 'keyUp'.toJS)
      ..setProperty('key'.toJS, 'Enter'.toJS)
      ..setProperty('code'.toJS, 'Enter'.toJS)
      ..setProperty('windowsVirtualKeyCode'.toJS, 13.toJS)
      ..setProperty('nativeVirtualKeyCode'.toJS, 13.toJS),
  );

  await detachDebugger(target);
}
