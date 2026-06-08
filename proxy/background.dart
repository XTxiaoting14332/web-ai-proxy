import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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

void main() {
  print("Background Service Worker loaded!");

  final runtime = chrome.getProperty('runtime'.toJS) as JSObject;
  final onMessage = runtime.getProperty('onMessage'.toJS) as JSObject;

  final listener =
      ((JSObject request, JSObject sender, JSFunction sendResponse) {
        final action = request.getProperty('action'.toJS) as JSString?;

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
}

Future<void> _performPhysicalInput(
  JSObject target,
  String text,
  double x,
  double y,
) async {
  await attachDebugger(target);

  for (int i = 0; i < text.length; i++) {
    // 处理换行符：如果是 \n，我们最好发送 Shift+Enter 保证只是换行而不是发送
    if (text[i] == '\n') {
      await sendDebuggerCommand(
        target,
        "Input.dispatchKeyEvent",
        JSObject()
          ..setProperty('type'.toJS, 'keyDown'.toJS)
          ..setProperty('key'.toJS, 'Enter'.toJS)
          ..setProperty('code'.toJS, 'Enter'.toJS)
          ..setProperty('modifiers'.toJS, 8.toJS) // Shift is modifier 8 in CDP
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
