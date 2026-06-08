import 'dart:async';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void main() {
  final input = web.document.getElementById('wsUrl') as web.HTMLInputElement;
  final saveBtn = web.document.getElementById('saveBtn') as web.HTMLButtonElement;
  final status = web.document.getElementById('status') as web.HTMLElement;

  // Read the current storage setting
  final chrome = globalContext.getProperty('chrome'.toJS) as JSObject;
  final storage = chrome.getProperty('storage'.toJS) as JSObject;
  final local = storage.getProperty('local'.toJS) as JSObject;
  
  final getCallback = ((JSObject result) {
    final urlObj = result.getProperty('wsUrl'.toJS);
    if (urlObj != null && !urlObj.isUndefined) {
      input.value = (urlObj as JSString).toDart;
    } else {
      input.value = 'ws://127.0.0.1:8080/ws';
    }
  }).toJS;

  // chrome.storage.local.get(['wsUrl'], getCallback);
  local.callMethod('get'.toJS, ['wsUrl'.toJS].toJS, getCallback);

  saveBtn.onClick.listen((_) {
    String newUrl = input.value.trim();
    if (newUrl.isEmpty) {
      newUrl = 'ws://127.0.0.1:8080/ws';
    }
    
    final data = JSObject()..setProperty('wsUrl'.toJS, newUrl.toJS);
    
    final setCallback = (() {
      status.innerText = 'Settings saved! Please refresh AI chat pages.';
      Timer(Duration(seconds: 3), () {
        status.innerText = '';
      });
    }).toJS;

    // chrome.storage.local.set({ wsUrl: newUrl }, setCallback);
    local.callMethod('set'.toJS, data, setCallback);
  });
}
