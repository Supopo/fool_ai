import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_windows/webview_windows.dart' as win;

const _composerProbeJs = r'''
(function() {
  function visible(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    // Soft check: some composers report 0 height while still usable.
    return (r.width > 0 && r.height > 0) || !!el.offsetParent;
  }
  function docs() {
    var out = [document];
    try {
      var iframes = document.querySelectorAll('iframe');
      for (var i = 0; i < iframes.length; i++) {
        try {
          if (iframes[i].contentDocument) out.push(iframes[i].contentDocument);
        } catch (e) {}
      }
    } catch (e) {}
    return out;
  }
  var sel = '#chat-input-box, #chat-textarea, textarea.ci-textarea, .yc-editor[contenteditable="true"], .tiptap.ProseMirror[contenteditable="true"], .ProseMirror[contenteditable="true"], [role="textbox"][contenteditable="true"], #dialogue-input, textarea, #chat-input, [contenteditable="true"], [role="textbox"]';
  var list = docs();
  for (var d = 0; d < list.length; d++) {
    try {
      var nodes = Array.from(list[d].querySelectorAll(sel)).filter(visible);
      if (nodes.length > 0) return true;
    } catch (e) {}
  }
  return false;
})()
''';

const _sendArmedProbeJs = r'''
(function() {
  function visible(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  var host = (location.hostname || '').toLowerCase();
  if (host.indexOf('deepseek') >= 0) {
    var ds = Array.from(document.querySelectorAll(
      'div.ds-icon-button[aria-disabled="false"], div[role="button"][aria-disabled="false"], button[aria-label="Send"], div[aria-label="Send"]'
    )).filter(visible);
    return ds.length > 0;
  }
  if (host.indexOf('yiyan') >= 0 || host.indexOf('wenxin') >= 0 || host.indexOf('baidu') >= 0) {
    var sendBtn = document.querySelector(
      '#ci-submit-button-ai, .ci-submit-button-ai-active, .ci-submit-button, .cs-input-ds-send-btn, #sendBtn'
    );
    if (sendBtn && visible(sendBtn)) {
      var inactive = (sendBtn.className || '').toString().indexOf('inactive') >= 0;
      if (sendBtn.disabled || sendBtn.getAttribute('aria-disabled') === 'true' || inactive) {
        return false;
      }
      return true;
    }
    var input = document.querySelector(
      '#chat-input-box, #chat-textarea, textarea.ci-textarea, .yc-editor[contenteditable="true"], #dialogue-input'
    );
    if (!input) return false;
    var text = (('value' in input ? input.value : '') || input.innerText || input.textContent || '').trim();
    return text.length > 0;
  }
  return false;
})()
''';

bool _jsTruthy(dynamic value) {
  if (value == true || value == 1) return true;
  final text = '$value'.trim().toLowerCase();
  return text == 'true' || text == '"true"';
}

AiWebViewController createAiWebViewController() {
  if (!kIsWeb && Platform.isWindows) {
    return _WindowsAiWebViewController();
  }
  return _FlutterAiWebViewController();
}

abstract class AiWebViewController {
  bool get isInitialized;
  Future<void> initialize();
  Future<void> loadUrl(String url);
  Future<void> reload();
  Future<void> executeScript(String script);
  Future<void> insertText(String text);
  /// Returns true when the page composer appears to contain [text].
  Future<bool> insertTextVerified(String text);
  Future<bool> waitUntilSendArmed({Duration timeout});
  Future<void> waitUntilReady({Duration timeout});
  Future<bool> waitUntilComposerReady({Duration timeout});
  Future<void> dispose();
  Widget buildView({Key? key});
}

class _WindowsAiWebViewController implements AiWebViewController {
  final win.WebviewController _controller = win.WebviewController();

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  Future<void> initialize() async {
    await _controller.initialize();
    await _controller.setBackgroundColor(Colors.white);
    await _controller.setPopupWindowPolicy(win.WebviewPopupWindowPolicy.deny);
  }

  @override
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<void> executeScript(String script) async {
    await _controller.executeScript(script);
  }

  @override
  Future<void> insertText(String text) => _controller.insertText(text);

  @override
  Future<bool> insertTextVerified(String text) async {
    await insertText(text);
    return true;
  }

  @override
  Future<bool> waitUntilSendArmed({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    return true;
  }

  @override
  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<bool> waitUntilComposerReady({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result = await _controller.executeScript(_composerProbeJs);
        if (_jsTruthy(result)) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  Widget buildView({Key? key}) {
    return win.Webview(_controller, key: key);
  }
}

class _FlutterAiWebViewController implements AiWebViewController {
  WebViewController? _controller;
  bool _initialized = false;
  Completer<void>? _pageReady;
  String? _loadedUrl;

  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  // Qianwen desktop layout is clipped on phones; use a real mobile UA.
  static const _mobileUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static bool _preferMobileUa(String url) {
    final host = url.toLowerCase();
    // These sites' desktop shells are clipped on phones.
    return host.contains('qianwen') ||
        host.contains('tongyi.com') ||
        host.contains('tongyi.aliyun') ||
        host.contains('wenxin') ||
        host.contains('yiyan') ||
        host.contains('chat.baidu');
  }

  @override
  bool get isInitialized => _initialized && _controller != null;

  @override
  Future<void> initialize() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(Colors.white);
    await controller.enableZoom(true);
    // Default desktop UA; loadUrl() may switch to mobile for Qianwen.
    await controller.setUserAgent(_desktopUa);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) => NavigationDecision.navigate,
        onPageFinished: (url) {
          final ready = _pageReady;
          if (ready != null && !ready.isCompleted) {
            ready.complete();
          }
          // Ensure mobile viewport for phone-targeted sites.
          if (_preferMobileUa(url) ||
              (_loadedUrl != null && _preferMobileUa(_loadedUrl!))) {
            unawaited(_injectMobileViewport());
          }
        },
      ),
    );

    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      await platform.setMediaPlaybackRequiresUserGesture(false);
      // Fit site content to the WebView width on phones.
      await platform.setUseWideViewPort(true);
    }

    _controller = controller;
    _initialized = true;
  }

  Future<void> _injectMobileViewport() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(r'''
        (function() {
          var m = document.querySelector('meta[name="viewport"]');
          if (!m) {
            m = document.createElement('meta');
            m.setAttribute('name', 'viewport');
            (document.head || document.documentElement).appendChild(m);
          }
          m.setAttribute(
            'content',
            'width=device-width, initial-scale=1.0, maximum-scale=5.0, viewport-fit=cover'
          );
          try {
            document.documentElement.style.overflowX = 'auto';
            document.body && (document.body.style.maxWidth = '100%');
          } catch (e) {}
        })();
      ''');
    } catch (_) {}
  }

  @override
  Future<void> loadUrl(String url) async {
    final controller = _controller;
    if (controller == null) return;
    _loadedUrl = url;
    _pageReady = Completer<void>();
    await controller.setUserAgent(
      _preferMobileUa(url) ? _mobileUa : _desktopUa,
    );
    await controller.loadRequest(Uri.parse(url));
  }

  @override
  Future<void> reload() async {
    final controller = _controller;
    if (controller == null) return;
    _pageReady = Completer<void>();
    await controller.reload();
  }

  @override
  Future<void> executeScript(String script) async {
    await _controller?.runJavaScript(script);
  }

  @override
  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final ready = _pageReady;
    if (ready == null) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return;
    }
    if (ready.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return;
    }
    try {
      await ready.future.timeout(timeout);
    } on TimeoutException {
      // Continue anyway — page may still be interactive.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Future<bool> waitUntilComposerReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final controller = _controller;
    if (controller == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result =
            await controller.runJavaScriptReturningResult(_composerProbeJs);
        if (_jsTruthy(result)) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  @override
  Future<bool> waitUntilSendArmed({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final controller = _controller;
    if (controller == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result =
            await controller.runJavaScriptReturningResult(_sendArmedProbeJs);
        if (_jsTruthy(result)) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Android/iOS cannot use CDP Input.insertText. Drive the composer via DOM
  /// with paste / native value setters so React and ProseMirror pick it up.
  @override
  Future<void> insertText(String text) async {
    await insertTextVerified(text);
  }

  @override
  Future<bool> insertTextVerified(String text) async {
    final controller = _controller;
    if (controller == null) return false;
    final encoded = jsonEncode(text);
    final trimmed = text.trim();
    final sampleEnd = trimmed.length < 12 ? trimmed.length : 12;
    final sample = jsonEncode(trimmed.isEmpty ? text : trimmed.substring(0, sampleEnd));
    try {
      final result = await controller.runJavaScriptReturningResult('''
      (function() {
        var t = $encoded;
        var sample = $sample;
        function visible(el) {
          if (!el) return false;
          try {
            var r = el.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) return true;
            if (el.offsetParent) return true;
            var st = window.getComputedStyle(el);
            return st && st.display !== 'none' && st.visibility !== 'hidden';
          } catch (e) {
            return true;
          }
        }
        function findInput() {
          var host = (location.hostname || '').toLowerCase();
          var preferred = [];
          if (host.indexOf('deepseek') >= 0) {
            preferred = preferred.concat([
              'textarea#chat-input',
              'textarea[data-testid="chat-input"]',
              'textarea[placeholder="Message DeepSeek"]',
              'textarea[placeholder*="DeepSeek"]',
              'textarea[placeholder*="Message"]',
              'textarea'
            ]);
          }
          if (host.indexOf('doubao') >= 0) {
            preferred = preferred.concat([
              '.tiptap.ProseMirror[contenteditable="true"]',
              '.ProseMirror[contenteditable="true"]',
              'textarea[data-testid="chat_input_input"]',
              'textarea.semi-input-textarea'
            ]);
          }
          if (host.indexOf('yiyan') >= 0 || host.indexOf('wenxin') >= 0 || host.indexOf('baidu') >= 0) {
            preferred = preferred.concat([
              '#chat-input-box',
              'textarea#chat-input-box',
              '#chat-textarea',
              'textarea.ci-textarea',
              'textarea#chat-textarea',
              '.yc-editor[contenteditable="true"]',
              'div.yc-editor[contenteditable="true"]',
              '#dialogue-input',
              'textarea#dialogue-input',
              '[id="dialogue-input"]',
              'textarea',
              '[contenteditable="true"]',
              '[role="textbox"]',
              '.ProseMirror[contenteditable="true"]'
            ]);
          }
          if (/tongyi|qianwen|aliyun/.test(host)) {
            preferred = preferred.concat([
              '[role="textbox"][contenteditable="true"]',
              '[contenteditable="true"][data-placeholder]',
              '.ProseMirror[contenteditable="true"]',
              '#chat-input',
              'textarea',
              '[contenteditable="true"]',
              '[role="textbox"]'
            ]);
          }
          preferred = preferred.concat([
            '#chat-input-box',
            '#chat-textarea',
            'textarea.ci-textarea',
            '[role="textbox"][contenteditable="true"]',
            '.yc-editor[contenteditable="true"]',
            '#dialogue-input',
            '.tiptap.ProseMirror[contenteditable="true"]',
            '.ProseMirror[contenteditable="true"]',
            'textarea[placeholder*="DeepSeek"]',
            'textarea[placeholder*="Message"]',
            'textarea[placeholder*="发送"]',
            'textarea',
            '#chat-input',
            '[contenteditable="true"]',
            '[role="textbox"]'
          ]);
          var allDocs = [document];
          try {
            var iframes = document.querySelectorAll('iframe');
            for (var f = 0; f < iframes.length; f++) {
              try {
                if (iframes[f].contentDocument) allDocs.push(iframes[f].contentDocument);
              } catch (e) {}
            }
          } catch (e) {}
          for (var i = 0; i < preferred.length; i++) {
            for (var d = 0; d < allDocs.length; d++) {
              try {
                var list = Array.from(allDocs[d].querySelectorAll(preferred[i])).filter(visible);
                if (!list.length) {
                  list = Array.from(allDocs[d].querySelectorAll(preferred[i]));
                }
                if (list.length) {
                  list.sort(function(a, b) {
                    return b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom;
                  });
                  return list[0];
                }
              } catch (e) {}
            }
          }
          return null;
        }
        function readText(el) {
          if (!el) return '';
          if ('value' in el && typeof el.value === 'string') return (el.value || '').trim();
          return (el.innerText || el.textContent || '').trim();
        }
        function looksFilled(el) {
          var now = readText(el);
          if (!now) return false;
          if (!sample) return now.length > 0;
          return now.indexOf(sample) !== -1 || now.length >= Math.min(sample.length, 8);
        }
        function reactPropKey(el) {
          return Object.keys(el).find(function(k) {
            return k.indexOf('__reactProps') === 0 ||
              k.indexOf('__reactEventHandlers') === 0 ||
              k.indexOf('__reactFiber') === 0;
          });
        }
        function setNativeValue(el, value) {
          var proto = el.tagName === 'INPUT'
            ? window.HTMLInputElement.prototype
            : window.HTMLTextAreaElement.prototype;
          var desc = Object.getOwnPropertyDescriptor(proto, 'value');
          var prev = el.value;
          if (desc && desc.set) desc.set.call(el, value);
          else el.value = value;
          try {
            var tracker = el._valueTracker;
            if (tracker) tracker.setValue(prev == null ? '' : prev);
          } catch (e) {}
        }
        function triggerReact(el, value) {
          try {
            setNativeValue(el, value);
            var key = reactPropKey(el);
            if (!key) return looksFilled(el);
            var props = el[key];
            if (props && props.memoizedProps) props = props.memoizedProps;
            else if (props && props.pendingProps) props = props.pendingProps;
            var evt = {
              target: el,
              currentTarget: el,
              type: 'change',
              bubbles: true,
              preventDefault: function() {},
              stopPropagation: function() {}
            };
            if (props && typeof props.onChange === 'function') props.onChange(evt);
            evt.type = 'input';
            if (props && typeof props.onInput === 'function') props.onInput(evt);
            return looksFilled(el);
          } catch (e) {
            return false;
          }
        }
        function clearEl(el) {
          try { el.focus(); el.click(); } catch (e) {}
          try {
            document.execCommand('selectAll', false, null);
            document.execCommand('delete', false, null);
          } catch (e) {}
          if ('value' in el) {
            triggerReact(el, '');
            setNativeValue(el, '');
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
        }
        function insertEditable(el) {
          try {
            el.focus();
            el.click();
            var sel = window.getSelection();
            if (sel) {
              sel.removeAllRanges();
              var range = document.createRange();
              range.selectNodeContents(el);
              range.collapse(true);
              sel.addRange(range);
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
              range = document.createRange();
              range.selectNodeContents(el);
              range.collapse(false);
              sel.removeAllRanges();
              sel.addRange(range);
            }
          } catch (e) {}
          try {
            el.dispatchEvent(new InputEvent('beforeinput', {
              bubbles: true, cancelable: true, inputType: 'insertText', data: t
            }));
          } catch (e) {}
          try {
            if (document.execCommand('insertText', false, t) && looksFilled(el)) {
              el.dispatchEvent(new InputEvent('input', {
                bubbles: true, data: t, inputType: 'insertText'
              }));
              return true;
            }
          } catch (e) {}
          try {
            var dt = new DataTransfer();
            dt.setData('text/plain', t);
            el.dispatchEvent(new ClipboardEvent('paste', {
              bubbles: true, cancelable: true, clipboardData: dt
            }));
            if (looksFilled(el)) return true;
          } catch (e) {}
          try {
            // Last resort for editors that only mirror textContent.
            el.focus();
            while (el.firstChild) el.removeChild(el.firstChild);
            el.appendChild(document.createTextNode(t));
            el.dispatchEvent(new InputEvent('input', {
              bubbles: true, data: t, inputType: 'insertText'
            }));
            triggerReact(el, t);
          } catch (e) {}
          return looksFilled(el);
        }
        function insertValue(el) {
          try { el.focus(); el.click(); } catch (e) {}
          if (triggerReact(el, t)) return true;
          try {
            el.focus();
            el.select();
            if (document.execCommand('insertText', false, t) && looksFilled(el)) return true;
          } catch (e) {}
          setNativeValue(el, t);
          try { el.selectionStart = el.selectionEnd = t.length; } catch (e) {}
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          try {
            el.dispatchEvent(new InputEvent('input', {
              bubbles: true, data: t, inputType: 'insertText'
            }));
          } catch (e) {}
          triggerReact(el, t);
          return looksFilled(el);
        }
        var el = findInput();
        if (!el) return 'no-input';
        var host2 = (location.hostname || '').toLowerCase();
        var isDeepSeek = host2.indexOf('deepseek') >= 0;
        var isYiyan = host2.indexOf('yiyan') >= 0 ||
          host2.indexOf('wenxin') >= 0 ||
          host2.indexOf('baidu') >= 0;
        var isTongyi = /tongyi|qianwen|aliyun/.test(host2);
        // DeepSeek: avoid execCommand clear (breaks React). Set value directly.
        if (isDeepSeek && el.tagName === 'TEXTAREA') {
          try { el.focus(); el.click(); } catch (e) {}
          if (triggerReact(el, t)) return 'ok-ds-react';
          setNativeValue(el, t);
          try {
            el.dispatchEvent(new InputEvent('input', {
              bubbles: true, data: t, inputType: 'insertText'
            }));
          } catch (e) {
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
          triggerReact(el, t);
          return looksFilled(el) ? 'ok-ds-value' : 'fail-ds';
        }
        // Qianwen: Slate. DOM/execCommand = ghost text (visible, send stays gray).
        // Must mutate Slate editor + editor.onChange() so React enables send.
        if (isTongyi && (el.isContentEditable || el.getAttribute('contenteditable') === 'true')) {
          function findSlateEditor(node) {
            try {
              var fiberKey = Object.keys(node).find(function(k) {
                return k.indexOf('__reactFiber') === 0;
              });
              if (!fiberKey) return null;
              var cur = node[fiberKey];
              for (var i = 0; i < 30 && cur; i++) {
                var p = cur.memoizedProps || cur.pendingProps || {};
                if (p.editor && typeof p.editor.insertText === 'function') return p.editor;
                cur = cur.return;
              }
            } catch (e) {}
            return null;
          }
          function qwSendEnabled() {
            var btn = document.querySelector('button[aria-label="发送消息"]');
            return !!(btn && !btn.disabled && btn.getAttribute('aria-disabled') !== 'true');
          }
          function slateHasText(editor) {
            try {
              var raw = JSON.stringify(editor.children || []);
              if (!sample) return raw.length > 20;
              return raw.indexOf(sample) !== -1 || raw.indexOf(t) !== -1;
            } catch (e) {
              return false;
            }
          }
          try { el.focus(); el.click(); } catch (e) {}
          var editor = findSlateEditor(el);
          if (editor) {
            try {
              editor.children = [{ type: 'paragraph', children: [{ text: '' }] }];
              if (typeof editor.select === 'function') {
                editor.select({
                  anchor: { path: [0, 0], offset: 0 },
                  focus: { path: [0, 0], offset: 0 }
                });
              }
              if (typeof editor.onChange === 'function') editor.onChange();
              editor.insertText(t);
              if (typeof editor.onChange === 'function') editor.onChange();
              if (slateHasText(editor) || qwSendEnabled() || looksFilled(el)) {
                return 'ok-qw-slate';
              }
            } catch (e) {}
            try {
              if (typeof editor.insertData === 'function') {
                var dt = new DataTransfer();
                dt.setData('text/plain', t);
                editor.insertData(dt);
                if (typeof editor.onChange === 'function') editor.onChange();
                if (slateHasText(editor) || qwSendEnabled() || looksFilled(el)) {
                  return 'ok-qw-data';
                }
              }
            } catch (e) {}
          }
          // Fallback: React onBeforeInput (older builds).
          var propsKey = reactPropKey(el);
          var props = propsKey ? el[propsKey] : null;
          if (props && props.memoizedProps) props = props.memoizedProps;
          try {
            document.execCommand('selectAll', false, null);
            document.execCommand('delete', false, null);
          } catch (e) {}
          try {
            var before = new InputEvent('beforeinput', {
              bubbles: true, cancelable: true, inputType: 'insertText', data: t
            });
            if (props && typeof props.onBeforeInput === 'function') props.onBeforeInput(before);
            else el.dispatchEvent(before);
          } catch (e) {}
          try { document.execCommand('insertText', false, t); } catch (e) {}
          try {
            var inputEvt = new InputEvent('input', {
              bubbles: true, data: t, inputType: 'insertText'
            });
            if (props && typeof props.onInput === 'function') props.onInput(inputEvt);
            else el.dispatchEvent(inputEvt);
          } catch (e) {}
          return (looksFilled(el) || qwSendEnabled()) ? 'ok-qw-fallback' : 'fail-qw';
        }
        if (isYiyan) {
          try { el.focus(); el.click(); } catch (e) {}
          // Never use textContent/innerText — that creates ghost text (visible but
          // send stays disabled). Prefer execCommand / InputEvent typing.
          function clearYiyan(target) {
            try { target.focus(); } catch (e) {}
            try {
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
            } catch (e) {}
            try {
              if ('value' in target && target.tagName !== 'DIV') {
                setNativeValue(target, '');
                target.dispatchEvent(new Event('input', { bubbles: true }));
              } else if (target.isContentEditable) {
                var sel = window.getSelection();
                if (sel) {
                  var range = document.createRange();
                  range.selectNodeContents(target);
                  sel.removeAllRanges();
                  sel.addRange(range);
                }
                document.execCommand('delete', false, null);
              }
            } catch (e) {}
          }
          function typeYiyan(target, value) {
            clearYiyan(target);
            try { target.focus(); } catch (e) {}
            // Whole-string insertText (closest to real typing).
            try {
              if (document.execCommand('insertText', false, value) && looksFilled(target)) {
                try {
                  target.dispatchEvent(new InputEvent('input', {
                    bubbles: true, data: value, inputType: 'insertText'
                  }));
                } catch (e) {}
                return true;
              }
            } catch (e) {}
            // Char-by-char (better for Vue/React controlled composers).
            try {
              clearYiyan(target);
              for (var i = 0; i < value.length; i++) {
                var ch = value.charAt(i);
                try {
                  target.dispatchEvent(new InputEvent('beforeinput', {
                    bubbles: true, cancelable: true, inputType: 'insertText', data: ch
                  }));
                } catch (e) {}
                document.execCommand('insertText', false, ch);
                try {
                  target.dispatchEvent(new InputEvent('input', {
                    bubbles: true, data: ch, inputType: 'insertText'
                  }));
                } catch (e) {}
              }
              if (looksFilled(target)) return true;
            } catch (e) {}
            // Textarea value path.
            if ('value' in target && target.tagName !== 'DIV') {
              if (triggerReact(target, value)) return true;
              setNativeValue(target, value);
              try {
                target.dispatchEvent(new InputEvent('input', {
                  bubbles: true, data: value, inputType: 'insertText'
                }));
              } catch (e) {
                target.dispatchEvent(new Event('input', { bubbles: true }));
              }
              try {
                target.dispatchEvent(new CompositionEvent('compositionend', {
                  bubbles: true, data: value
                }));
              } catch (e) {}
              triggerReact(target, value);
              return looksFilled(target);
            }
            return insertEditable(target);
          }
          return typeYiyan(el, t) ? 'ok-yy' : 'fail-yy';
        }
        clearEl(el);
        var ok = false;
        if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
          ok = insertEditable(el);
        } else if ('value' in el) {
          ok = insertValue(el);
        }
        return ok ? 'ok' : 'fail';
      })();
    ''');
      final textResult = '$result'.replaceAll('"', '').trim().toLowerCase();
      final ok = _jsTruthy(result) || textResult.startsWith('ok');
      if (!ok) {
        debugPrint('insertTextVerified result: $result');
      }
      return ok;
    } catch (e) {
      debugPrint('insertTextVerified failed: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _controller = null;
    _initialized = false;
    _pageReady = null;
  }

  @override
  Widget buildView({Key? key}) {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return WebViewWidget(key: key, controller: controller);
  }
}
