import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'ai_webview.dart';
import 'platform_support.dart';

const _kAppBarColor = Colors.white;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isMobile) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: _kAppBarColor,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
    );
  }
  if (isWindowsDesktop) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      title: '智慧饼',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6FED);
    return MaterialApp(
      title: '智慧饼',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        appBarTheme: const AppBarTheme(
          backgroundColor: _kAppBarColor,
          foregroundColor: Colors.black87,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: _kAppBarColor,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.black.withOpacity(0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.black.withOpacity(0.08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: seed, width: 1.5),
          ),
        ),
      ),
      home: const MultiAIPage(),
    );
  }
}

class MultiAIPage extends StatefulWidget {
  const MultiAIPage({super.key});

  @override
  State<MultiAIPage> createState() => _MultiAIPageState();
}

class _MultiAIPageState extends State<MultiAIPage> with WindowListener {
  int _selectedIndex = 0;
  final TextEditingController _inputController = TextEditingController();
  bool _isMaximized = false;
  bool _compareMode = false;
  bool _syncMode = false;
  bool _isSending = false;
  DateTime? _lastSendAt;
  String? _lastSentText;
  /// Queued sync text: sent to other selected AIs when the user switches to them.
  String? _pendingSyncText;
  final LinkedHashSet<int> _pendingSyncTargets = LinkedHashSet<int>();
  final LinkedHashSet<int> _compareSelection = LinkedHashSet<int>();
  final LinkedHashSet<int> _syncSelection = LinkedHashSet<int>();
  final ScrollController _aiChipScrollController = ScrollController();

  static const _sendCooldown = Duration(seconds: 2);
  static const _sameTextCooldown = Duration(seconds: 6);

  final List<Map<String, dynamic>> _aiConfigs = [
    {'name': 'ChatGPT', 'url': 'https://chatgpt.com', 'icon': Icons.smart_toy},
    {'name': 'DeepSeek', 'url': 'https://chat.deepseek.com', 'icon': Icons.psychology},
    {'name': '豆包', 'url': 'https://www.doubao.com', 'icon': Icons.auto_awesome},
    {'name': '通义千问', 'url': 'https://www.qianwen.com/', 'icon': Icons.travel_explore},
    {'name': '文心一言', 'url': 'https://wenxin.baidu.com/?enter_type=chat_site', 'icon': Icons.chat_bubble_outline},
  ];

  late final List<AiWebViewController> _controllers =
      List.generate(_aiConfigs.length, (_) => createAiWebViewController());

  late final List<bool> _isInitialized =
      List.filled(_aiConfigs.length, false);

  final Set<int> _initializing = <int>{};

  @override
  void initState() {
    super.initState();
    if (isWindowsDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          windowManager.addListener(this);
          _isMaximized = await windowManager.isMaximized();
          if (mounted) setState(() {});
        } catch (_) {}
      });
    }
    _bootstrapWebViews();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  Future<void> _bootstrapWebViews() async {
    // Phone: only the current page. Desktop can warm all tabs.
    if (isMobile) {
      await _ensureWebView(_selectedIndex);
      return;
    }
    for (var i = 0; i < _aiConfigs.length; i++) {
      await _ensureWebView(i);
    }
  }

  Future<void> _ensureWebView(int index) async {
    if (_isInitialized[index]) return;
    if (_initializing.contains(index)) {
      while (_initializing.contains(index)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return;
    }
    _initializing.add(index);
    try {
      await _controllers[index].initialize();
      await _controllers[index].loadUrl(_aiConfigs[index]['url'] as String);
      if (mounted) {
        setState(() {
          _isInitialized[index] = true;
        });
      } else {
        _isInitialized[index] = true;
      }
    } catch (e) {
      debugPrint('WebView $index 初始化失败: $e');
    } finally {
      _initializing.remove(index);
    }
  }

  Future<void> _ensureWebViews(Iterable<int> indices) async {
    for (final index in indices) {
      await _ensureWebView(index);
    }
  }

  /// Mount and warm sync targets so first send is not racing cold SPA pages.
  Future<void> _prewarmSyncTargets() async {
    final targets = _syncSelection.isNotEmpty
        ? _syncSelection.toList()
        : List<int>.generate(_aiConfigs.length, (i) => i);
    await _ensureWebViews(targets);
    if (!mounted) return;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 160));
    for (final index in targets) {
      final controller = _controllers[index];
      if (!controller.isInitialized) continue;
      unawaited(() async {
        try {
          await controller.waitUntilReady();
          await controller.waitUntilComposerReady(
            timeout: const Duration(seconds: 25),
          );
        } catch (e) {
          debugPrint('预热失败 (${_aiConfigs[index]['name']}): $e');
        }
      }());
    }
  }

  Future<void> _sendToAll() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    final now = DateTime.now();
    if (_lastSendAt != null) {
      final elapsed = now.difference(_lastSendAt!);
      if (elapsed < _sendCooldown) return;
      if (_lastSentText == text && elapsed < _sameTextCooldown) return;
    }

    setState(() => _isSending = true);
    _inputController.clear();
    FocusScope.of(context).unfocus();

    // Focus + clear only. Do not write text via DOM — Qianwen/ProseMirror will
    // show ghost text while keeping the real editor state empty (gray send).
    // Also cancel any leftover send timers from a previous attempt on this page.
    const focusClearJs = r'''
      (function() {
        try {
          if (window.__foolAiSendTimer) {
            clearInterval(window.__foolAiSendTimer);
            window.__foolAiSendTimer = null;
          }
          if (window.__foolAiSendFallback) {
            clearTimeout(window.__foolAiSendFallback);
            window.__foolAiSendFallback = null;
          }
        } catch (e) {}
        function visible(el) {
          if (!el) return false;
          var r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        function findInput() {
          var nodes = Array.from(document.querySelectorAll(
            '.ProseMirror[contenteditable="true"], textarea, #chat-input, [contenteditable="true"], [role="textbox"]'
          )).filter(visible);
          if (!nodes.length) return null;
          nodes.sort(function(a, b) {
            return b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom;
          });
          return nodes[0];
        }
        var el = findInput();
        if (!el) return false;
        el.focus();
        try { el.click(); } catch (e) {}
        try {
          document.execCommand('selectAll', false, null);
          document.execCommand('delete', false, null);
        } catch (e) {}
        return true;
      })()
    ''';

    // Click send once. DeepSeek: wait for ds-icon-button aria-disabled=false.
    // Tongyi: never click mode chips like 快速/思考/研究 — prefer Enter.
    const clickSendJs = r'''
      (function() {
        try {
          if (window.__foolAiSendTimer) {
            clearInterval(window.__foolAiSendTimer);
            window.__foolAiSendTimer = null;
          }
          if (window.__foolAiSendFallback) {
            clearTimeout(window.__foolAiSendFallback);
            window.__foolAiSendFallback = null;
          }
        } catch (e) {}
        var host = (location.hostname || '').toLowerCase();
        var isDeepSeek = host.indexOf('deepseek') >= 0;
        var isDoubao = host.indexOf('doubao') >= 0;
        var isTongyi = /tongyi|qianwen|aliyun/.test(host);
        var isYiyan = host.indexOf('yiyan') >= 0 ||
          host.indexOf('wenxin') >= 0 ||
          host.indexOf('chat.baidu') >= 0 ||
          !!document.querySelector('#chat-textarea') ||
          !!document.querySelector('#dialogue-input');
        // Dismiss common Wenxin overlays that block send.
        if (isYiyan) {
          try {
            Array.from(document.querySelectorAll('div, span, button')).forEach(function(el) {
              var t = (el.innerText || '').trim();
              if (t === '我知道了' || t === '接受协议' || t === '开始体验') {
                try { el.click(); } catch (e) {}
              }
            });
          } catch (e) {}
        }
        function visible(el) {
          if (!el) return false;
          var r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        function findInput() {
          var preferred = [];
          if (isDeepSeek) {
            preferred = preferred.concat([
              'textarea#chat-input',
              'textarea[data-testid="chat-input"]',
              'textarea[placeholder="Message DeepSeek"]',
              'textarea[placeholder*="DeepSeek"]',
              'textarea[placeholder*="Message"]',
              'textarea'
            ]);
          }
          if (isYiyan) {
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
              '[role="textbox"]'
            ]);
          }
          if (isDoubao) {
            preferred = preferred.concat([
              '.tiptap.ProseMirror[contenteditable="true"]',
              '.ProseMirror[contenteditable="true"]',
              'textarea[data-testid="chat_input_input"]',
              'textarea.semi-input-textarea'
            ]);
          }
          if (isTongyi) {
            preferred = preferred.concat([
              '[role="textbox"][contenteditable="true"]',
              '[contenteditable="true"][data-placeholder]',
              '.ProseMirror[contenteditable="true"]',
              '#chat-input',
              'textarea',
              '[contenteditable="true"]'
            ]);
          }
          preferred = preferred.concat([
            '#chat-input-box',
            '#chat-textarea',
            'textarea.ci-textarea',
            '[role="textbox"][contenteditable="true"]',
            '.yc-editor[contenteditable="true"]',
            '#dialogue-input',
            '.ProseMirror[contenteditable="true"]',
            'textarea', '#chat-input',
            '[contenteditable="true"]', '[role="textbox"]'
          ]);
          for (var i = 0; i < preferred.length; i++) {
            try {
              var list = Array.from(document.querySelectorAll(preferred[i])).filter(visible);
              if (list.length) {
                list.sort(function(a, b) {
                  return b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom;
                });
                return list[0];
              }
            } catch (e) {}
          }
          return null;
        }
        function isDisabled(el) {
          return !!(el.disabled || el.getAttribute('aria-disabled') === 'true' ||
            el.classList.contains('disabled') ||
            el.getAttribute('data-disabled') === 'true');
        }
        function btnLabel(btn) {
          return (
            (btn.getAttribute('aria-label') || '') + ' ' +
            (btn.getAttribute('title') || '') + ' ' +
            (btn.getAttribute('data-testid') || '') + ' ' +
            (btn.innerText || '') + ' ' +
            (btn.className || '')
          ).toLowerCase();
        }
        function isModeOrToolBtn(btn) {
          var label = btnLabel(btn);
          return /快速|思考|研究|深度|联网|搜索|附件|上传|新对话|模型|语音|麦克风|deep.?think|\br1\b|search|upload|attach|image|voice|mic|history|历史|stop|停止/.test(label);
        }
        function nearInput(btn, input) {
          if (!input) return true;
          var ir = input.getBoundingClientRect();
          var br = btn.getBoundingClientRect();
          return Math.abs(br.bottom - ir.bottom) < 100 && br.top >= ir.top - 40;
        }
        function composerRoot(input) {
          if (!input) return document;
          var el = input;
          for (var i = 0; i < 10 && el; i++) {
            var cls = (el.className || '').toString().toLowerCase();
            if (/footer|input|composer|operate|bottom|chat-input|editor|textarea/.test(cls)) {
              return el;
            }
            el = el.parentElement;
          }
          return input.parentElement || document;
        }
        function findDeepSeekSend(input) {
          var buttons = Array.from(document.querySelectorAll(
            'div.ds-icon-button[aria-disabled="false"], div[role="button"][aria-disabled="false"], div[aria-label="Send"], button[aria-label="Send"]'
          )).filter(visible).filter(function(b) {
            if (isModeOrToolBtn(b)) return false;
            if (b.getAttribute('aria-checked') != null) return false;
            return true;
          });
          var near = buttons.filter(function(b) { return nearInput(b, input); });
          var pool = near.length ? near : buttons;
          if (!pool.length) return null;
          pool.sort(function(a, b) {
            return b.getBoundingClientRect().right - a.getBoundingClientRect().right;
          });
          return pool[0];
        }
        function findYiyanSend(input) {
          // Desktop: #ci-submit-button-ai; mobile: .cs-input-ds-send-btn
          var sendBtn = document.querySelector(
            '#ci-submit-button-ai, .ci-submit-button-ai-active, .ci-submit-button, .cs-input-ds-send-btn, #sendBtn'
          );
          if (sendBtn && visible(sendBtn)) return sendBtn;
          var el = input ||
            document.querySelector('#chat-input-box') ||
            document.querySelector('#chat-textarea') ||
            document.querySelector('.yc-editor[contenteditable="true"]') ||
            document.querySelector('#dialogue-input');
          var candidates = [];
          function push(node) {
            if (!node || !visible(node)) return;
            if (candidates.indexOf(node) >= 0) return;
            candidates.push(node);
          }
          if (el && el.parentElement) {
            push(el.parentElement.nextElementSibling);
            var p = el.parentElement;
            for (var up = 0; up < 5 && p; up++) {
              Array.from(p.querySelectorAll(
                '#ci-submit-button-ai, .ci-submit-button, .cs-input-ds-send-btn, #sendBtn, button, [role="button"], div[role="button"], span[role="button"], [class*="submit"], [class*="send"], [class*="Send"]'
              )).forEach(push);
              if (p.nextElementSibling) push(p.nextElementSibling);
              p = p.parentElement;
            }
          }
          if (!candidates.length) return null;
          candidates.sort(function(a, b) {
            var score = function(n) {
              var id = n.id || '';
              var cn = (n.className || '').toString();
              var s = 0;
              if (id === 'ci-submit-button-ai' || id === 'sendBtn') s += 1000;
              if (/ci-submit-button|cs-input-ds-send/.test(cn)) s += 500;
              return s;
            };
            var d = score(b) - score(a);
            if (d !== 0) return d;
            return b.getBoundingClientRect().right - a.getBoundingClientRect().right;
          });
          return candidates[0];
        }
        function tapDeep(el) {
          if (!el) return;
          tap(el);
          try {
            var kids = el.querySelectorAll(
              'button, [role="button"], div[role="button"], svg, path, i, span, img'
            );
            for (var i = 0; i < Math.min(kids.length, 8); i++) {
              tap(kids[i]);
            }
          } catch (e) {}
        }
        function findTongyiSend(input) {
          var labeled = document.querySelector('button[aria-label="发送消息"]');
          if (labeled && visible(labeled)) return labeled;
          var root = composerRoot(input);
          var nodes = Array.from(root.querySelectorAll(
            'button, [role="button"], div[role="button"]'
          )).filter(visible);
          for (var i = 0; i < nodes.length; i++) {
            var b = nodes[i];
            if (isModeOrToolBtn(b)) continue;
            var label = btnLabel(b);
            var raw = ((b.getAttribute('aria-label') || '') + (b.innerText || '')).trim();
            if (raw === '发送' || raw === '发送消息') return b;
            if (/发送消息|^发送$/.test(raw)) return b;
            if (/\bsend\b|submit|paper-?plane|send-btn|btn-send/.test(label) &&
                !/search|mode|think|快速|思考/.test(label)) return b;
          }
          return null;
        }
        function findSendBtn(input) {
          var direct = document.querySelector(
            '#ci-submit-button-ai, .ci-submit-button, .cs-input-ds-send-btn, button[aria-label="发送消息"], #sendBtn, #flow-end-msg-send, [data-testid="chat_input_send"]'
          );
          if (direct && visible(direct) && !isDisabled(direct) && !isModeOrToolBtn(direct)) {
            return direct;
          }

          if (isDeepSeek) return findDeepSeekSend(input);
          if (isYiyan) return findYiyanSend(input);
          if (isTongyi) return findTongyiSend(input);

          var root = composerRoot(input);
          if (isDoubao) {
            var doubaoBtns = Array.from(root.querySelectorAll(
              'button, [role="button"], [data-dbx-name="button"]'
            )).filter(visible).filter(function(b) { return !isDisabled(b); });
            for (var d = 0; d < doubaoBtns.length; d++) {
              var dc = (doubaoBtns[d].className || '').toString();
              if (/fill-highlight|dbx-fill-highlight/.test(dc) && !isModeOrToolBtn(doubaoBtns[d])) {
                return doubaoBtns[d];
              }
            }
            var labeled = doubaoBtns.find(function(b) {
              var label = ((b.getAttribute('aria-label') || '') + (b.innerText || '')).trim();
              return label === '发送' || label === '发送消息';
            });
            if (labeled) return labeled;
          }

          var nodes = Array.from(root.querySelectorAll(
            'button, [role="button"], div[role="button"]'
          )).filter(visible);
          var scored = nodes.map(function(btn) {
            if (isModeOrToolBtn(btn)) return { btn: btn, score: -100 };
            var label = btnLabel(btn);
            var score = 0;
            if (/发送|提交|\bsend\b|\bsubmit\b/.test(label)) score += 8;
            if (/paper-?plane|send-?icon|sendbtn|btn-send|fill-highlight/.test(label)) score += 5;
            if (btn.tagName === 'BUTTON' && btn.type === 'submit') score += 4;
            if (isDisabled(btn)) score -= 10;
            return { btn: btn, score: score };
          }).filter(function(x) { return x.score > 0; })
            .sort(function(a, b) { return b.score - a.score; });
          return scored.length ? scored[0].btn : null;
        }
        function pressKey(el, key, mods) {
          mods = mods || {};
          var opts = {
            bubbles: true, cancelable: true, key: key, code: 'Enter',
            keyCode: 13, which: 13,
            ctrlKey: !!mods.ctrl, metaKey: !!mods.meta, shiftKey: !!mods.shift
          };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keypress', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
        }
        function tap(el) {
          try { el.focus(); } catch (e) {}
          try {
            el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'touch' }));
            el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
            el.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'touch' }));
            el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
          } catch (e) {}
          try { el.click(); } catch (e) {}
        }
        function hasText(el) {
          if (!el) return false;
          if ('value' in el && typeof el.value === 'string') {
            return (el.value || '').trim().length > 0;
          }
          if ((el.innerText || el.textContent || '').trim().length > 0) return true;
          // Qianwen Slate may enable send before DOM text catches up.
          if (isTongyi) {
            var qw = document.querySelector('button[aria-label="发送消息"]');
            if (qw && !isDisabled(qw)) return true;
          }
          return false;
        }
        var el = findInput();
        if (!el) return false;
        try { el.focus(); } catch (e) {}
        function tryOnce() {
          if (isYiyan) {
            var sendBtn = document.querySelector(
              '#ci-submit-button-ai, .ci-submit-button-ai-active, .ci-submit-button, #sendBtn'
            );
            if (sendBtn) {
              try {
                sendBtn.removeAttribute('disabled');
                sendBtn.removeAttribute('aria-disabled');
              } catch (e) {}
              tapDeep(sendBtn);
              tap(sendBtn);
              try { if (sendBtn.parentElement) tap(sendBtn.parentElement); } catch (e) {}
            }
            // Nudge composer so Vue enables send after JS fill.
            try {
              var now = ('value' in el && typeof el.value === 'string')
                ? (el.value || '')
                : (el.innerText || el.textContent || '');
              el.focus();
              el.dispatchEvent(new InputEvent('input', {
                bubbles: true, data: now, inputType: 'insertText'
              }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            } catch (e) {}
            var yBtn = findYiyanSend(el);
            if (yBtn && yBtn !== sendBtn) {
              tapDeep(yBtn);
            }
            pressKey(el, 'Enter');
            pressKey(el, 'Enter', { ctrl: true });
            return !!(sendBtn || yBtn) || hasText(el);
          }
          var btn = findSendBtn(el);
          if (btn && !isDisabled(btn) && !isModeOrToolBtn(btn)) {
            tap(btn);
            return true;
          }
          if (isTongyi && hasText(el)) {
            pressKey(el, 'Enter');
            return true;
          }
          return false;
        }
        if (tryOnce()) {
          if (!isYiyan) return true;
          // Wenxin: keep retrying briefly even after first tap.
        }
        var n = 0;
        var maxTries = (isDoubao || isDeepSeek || isYiyan) ? 24 : (isTongyi ? 16 : 12);
        window.__foolAiSendTimer = setInterval(function() {
          if (tryOnce() && !isYiyan) {
            clearInterval(window.__foolAiSendTimer);
            window.__foolAiSendTimer = null;
            return;
          }
          if (isYiyan && n > 0 && n % 3 === 0) {
            // Periodic re-nudge + sibling click for Wenxin.
            tryOnce();
          }
          if (++n >= maxTries) {
            clearInterval(window.__foolAiSendTimer);
            window.__foolAiSendTimer = null;
            if (hasText(el) && (isTongyi || isDeepSeek || isDoubao || isYiyan)) {
              pressKey(el, 'Enter');
              if (isYiyan) {
                pressKey(el, 'Enter', { ctrl: true });
                var lastBtn = findYiyanSend(el);
                if (lastBtn) tapDeep(lastBtn);
              }
            }
          }
        }, 250);
        return true;
      })()
    ''';

    try {
      final targets = _syncTargets();
      if (targets.isEmpty) return;

      // Queue other selected AIs; only send the current page now.
      // User switches tabs later → those pages get the same text then.
      final current = _selectedIndex;
      final pending = targets.where((i) => i != current).toList();
      setState(() {
        _pendingSyncText = text;
        _pendingSyncTargets
          ..clear()
          ..addAll(pending);
      });

      // Warm remaining targets in background so switch-send is snappy.
      if (pending.isNotEmpty) {
        unawaited(_ensureWebViews(pending));
      }

      final wasReady = _isInitialized[current];
      await _ensureWebView(current);
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;

      final controller = _controllers[current];
      if (controller.isInitialized && targets.contains(current)) {
        var sendTargetSeq = 1;
        try {
          await _sendToOneTarget(
            index: current,
            controller: controller,
            text: text,
            freshlyOpened: !wasReady,
            focusClearJs: focusClearJs,
            clickSendJs: clickSendJs,
            seq: 1,
            currentSeq: () => sendTargetSeq,
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              sendTargetSeq++;
              debugPrint('同步发送超时: ${_aiConfigs[current]['name']}');
            },
          );
        } catch (e) {
          debugPrint('同步发送失败 (${_aiConfigs[current]['name']}): $e');
        }
      }

      if (mounted && _pendingSyncTargets.isEmpty) {
        setState(() => _pendingSyncText = null);
      } else if (mounted && _pendingSyncTargets.isNotEmpty) {
        // Keep pending; hint user to switch tabs.
        setState(() {});
      }
    } finally {
      _lastSendAt = DateTime.now();
      _lastSentText = text;
      if (mounted) {
        setState(() => _isSending = false);
      } else {
        _isSending = false;
      }
    }
  }

  /// User picked an AI tab. Flush queued sync text for that page if needed.
  void _selectAi(int index) {
    final changed = index != _selectedIndex;
    setState(() {
      _compareMode = false;
      _selectedIndex = index;
    });
    unawaited(_ensureWebView(index));
    if (changed) {
      unawaited(_flushPendingSyncFor(index));
    }
  }

  Future<void> _flushPendingSyncFor(int index) async {
    final text = _pendingSyncText;
    if (text == null || text.isEmpty) return;
    if (!_pendingSyncTargets.contains(index)) return;

    // Wait out any in-flight send (e.g. still finishing previous page).
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (_isSending && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (!mounted) return;
    if (_selectedIndex != index) return;
    if (!_pendingSyncTargets.contains(index)) return;
    if (_isSending) return;

    setState(() {
      _pendingSyncTargets.remove(index);
      if (_pendingSyncTargets.isEmpty) {
        _pendingSyncText = null;
      }
      _isSending = true;
    });

    // Reuse the same inject/click scripts as the initial sync send.
    const focusClearJs = r'''
      (function() {
        try {
          if (window.__foolAiSendTimer) {
            clearInterval(window.__foolAiSendTimer);
            window.__foolAiSendTimer = null;
          }
        } catch (e) {}
        function visible(el) {
          if (!el) return false;
          var r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        var nodes = Array.from(document.querySelectorAll(
          '.ProseMirror[contenteditable="true"], textarea, #chat-input, #chat-textarea, [contenteditable="true"]'
        )).filter(visible);
        if (!nodes.length) return false;
        nodes.sort(function(a, b) {
          return b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom;
        });
        var el = nodes[0];
        el.focus();
        try {
          document.execCommand('selectAll', false, null);
          document.execCommand('delete', false, null);
        } catch (e) {}
        return true;
      })()
    ''';
    // Full click script lives in _sendToAll; for switch-flush use site helpers
    // inside _sendToOneTarget (Wenxin path) + a compact generic click.
    const clickSendJs = r'''
      (function() {
        var host = (location.hostname || '').toLowerCase();
        function visible(el) {
          if (!el) return false;
          var r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        var wenxin = document.querySelector('#ci-submit-button-ai') ||
          document.querySelector('.ci-submit-button-ai-active') ||
          document.querySelector('.ci-submit-button') ||
          document.querySelector('.cs-input-ds-send-btn');
        if (wenxin) { try { wenxin.click(); } catch (e) {} return true; }
        var qw = document.querySelector('button[aria-label="发送消息"]');
        if (qw && !qw.disabled) { try { qw.click(); } catch (e) {} return true; }
        var el = document.querySelector('#chat-input-box') ||
          document.querySelector('#chat-textarea') ||
          document.querySelector('[role="textbox"][contenteditable="true"]') ||
          document.querySelector('textarea, .ProseMirror[contenteditable="true"], [contenteditable="true"]');
        if (el) {
          try { el.focus(); } catch (e) {}
          try {
            el.dispatchEvent(new KeyboardEvent('keydown', {
              bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13
            }));
          } catch (e) {}
        }
        var btns = Array.from(document.querySelectorAll('button, [role="button"]')).filter(visible);
        for (var i = 0; i < btns.length; i++) {
          var label = ((btns[i].getAttribute('aria-label') || '') + (btns[i].innerText || '')).trim();
          if (label === '发送' || label === '发送消息' || /^发送/.test(label)) {
            try { btns[i].click(); } catch (e) {}
            return true;
          }
        }
        return true;
      })()
    ''';

    try {
      await _ensureWebView(index);
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 280));

      final controller = _controllers[index];
      if (!controller.isInitialized) return;
      var seq = 1;
      await _sendToOneTarget(
        index: index,
        controller: controller,
        text: text,
        freshlyOpened: false,
        focusClearJs: focusClearJs,
        clickSendJs: clickSendJs,
        seq: 1,
        currentSeq: () => seq,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          seq++;
          debugPrint('切换补发超时: ${_aiConfigs[index]['name']}');
        },
      );
    } catch (e) {
      debugPrint('切换补发失败 (${_aiConfigs[index]['name']}): $e');
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      } else {
        _isSending = false;
      }
    }
  }

  /// Switch to this AI first, then fill+send immediately and move on.
  /// No long composer/armed waits — next tab switch is the pacing.
  Future<void> _sendToOneTarget({
    required int index,
    required AiWebViewController controller,
    required String text,
    required bool freshlyOpened,
    required String focusClearJs,
    required String clickSendJs,
    required int seq,
    required int Function() currentSeq,
  }) async {
    bool alive() => seq == currentSeq() && _isSending;

    // 1) Switch onto this AI (required on Android for reliable DOM writes).
    if (mounted && alive() && _selectedIndex != index) {
      setState(() => _selectedIndex = index);
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(
        Duration(milliseconds: isMobile ? 280 : 120),
      );
    }
    if (!alive()) return;

    // Fresh pages: tiny settle only. Do not block on long ready polls.
    if (freshlyOpened) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!alive()) return;
    }

    final url = (_aiConfigs[index]['url'] as String).toLowerCase();
    final hardSite = url.contains('deepseek');
    final isYiyanSite =
        url.contains('yiyan') || url.contains('wenxin') || url.contains('baidu');
    final isTongyiSite =
        url.contains('qianwen') || url.contains('tongyi') || url.contains('aliyun');

    if (isYiyanSite) {
      await controller.executeScript(r'''
        (function() {
          var host = (location.hostname || '').toLowerCase();
          var hasUi = !!document.querySelector('#chat-input-box') ||
            !!document.querySelector('#chat-textarea') ||
            !!document.querySelector('.cs-input-ds-send-btn') ||
            !!document.querySelector('#ci-submit-button-ai') ||
            !!document.querySelector('.ci-submit-button');
          if (!hasUi && host.indexOf('wenxin') < 0) {
            location.replace('https://wenxin.baidu.com/?enter_type=chat_site');
          }
        })();
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!alive()) return;
    }

    // 2) Fill + send right after the tab is visible.
    if (!hardSite && !isYiyanSite && !isTongyiSite) {
      await controller.executeScript(focusClearJs);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (!alive()) return;

    if (isYiyanSite) {
      final encoded = jsonEncode(text);
      await controller.executeScript('''
        (function() {
          var el = document.querySelector('#chat-input-box') ||
            document.querySelector('#chat-textarea') ||
            document.querySelector('textarea.ci-textarea') ||
            document.querySelector('#dialogue-input') ||
            document.querySelector('textarea, [contenteditable="true"]');
          if (!el) return 'no-editor';
          try { el.focus(); el.click(); } catch (e) {}
          if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
            var proto = el.tagName === 'INPUT'
              ? window.HTMLInputElement.prototype
              : window.HTMLTextAreaElement.prototype;
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            var prev = el.value;
            if (desc && desc.set) desc.set.call(el, $encoded);
            else el.value = $encoded;
            try {
              var tracker = el._valueTracker;
              if (tracker) tracker.setValue(prev == null ? '' : prev);
            } catch (e) {}
            try {
              var key = Object.keys(el).find(function(k) {
                return k.indexOf('__reactProps') === 0 ||
                  k.indexOf('__reactEventHandlers') === 0;
              });
              if (key && el[key] && typeof el[key].onChange === 'function') {
                el[key].onChange({
                  target: el, currentTarget: el, type: 'change',
                  bubbles: true,
                  preventDefault: function() {},
                  stopPropagation: function() {}
                });
              }
            } catch (e) {}
            try {
              el.dispatchEvent(new InputEvent('input', {
                bubbles: true, data: $encoded, inputType: 'insertText'
              }));
            } catch (e) {
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            try {
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
              document.execCommand('insertText', false, $encoded);
            } catch (e) {}
          }
          function forceWenxinSend() {
            var btn = document.querySelector('#ci-submit-button-ai') ||
              document.querySelector('.ci-submit-button-ai-active') ||
              document.querySelector('.ci-submit-button') ||
              document.querySelector('.cs-input-ds-send-btn') ||
              document.querySelector('.cs-input-function-btn');
            if (!btn) {
              try {
                el.dispatchEvent(new KeyboardEvent('keydown', {
                  bubbles: true, cancelable: true, key: 'Enter', code: 'Enter',
                  keyCode: 13, which: 13
                }));
              } catch (e) {}
              return false;
            }
            try {
              btn.removeAttribute('disabled');
              btn.removeAttribute('aria-disabled');
              btn.classList && btn.classList.remove('disabled');
            } catch (e) {}
            try {
              btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
            } catch (e) {}
            try { btn.click(); } catch (e) {}
            try { if (btn.parentElement) btn.parentElement.click(); } catch (e) {}
            return true;
          }
          forceWenxinSend();
          var n = 0;
          var timer = setInterval(function() {
            forceWenxinSend();
            if (++n >= 8) clearInterval(timer);
          }, 120);
          return 'ok';
        })();
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    } else if (isTongyiSite) {
      // Qianwen = Slate. Ghost DOM text leaves send gray; use editor.insertText + onChange.
      final encoded = jsonEncode(text);
      await controller.executeScript('''
        (function() {
          var t = $encoded;
          var el = document.querySelector('[role="textbox"][contenteditable="true"]') ||
            document.querySelector('[contenteditable="true"][data-placeholder]') ||
            document.querySelector('.ProseMirror[contenteditable="true"]') ||
            document.querySelector('[contenteditable="true"]');
          if (!el) return 'no-editor';
          try { el.focus(); el.click(); } catch (e) {}
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
          function findQwSend() {
            var labeled = document.querySelector('button[aria-label="发送消息"]');
            if (labeled) return labeled;
            var nodes = document.querySelectorAll('button, [role="button"]');
            for (var i = 0; i < nodes.length; i++) {
              var b = nodes[i];
              var label = ((b.getAttribute('aria-label') || '') + (b.innerText || '')).trim();
              if (label === '发送消息' || label === '发送') return b;
            }
            return null;
          }
          function sendEnabled(btn) {
            return !!(btn && !btn.disabled && btn.getAttribute('aria-disabled') !== 'true');
          }
          function tap(btn) {
            if (!btn) return;
            try {
              btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true }));
              btn.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
            } catch (e) {}
            try { btn.click(); } catch (e) {}
          }
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
            } catch (e) {}
          } else {
            // Fallback for non-Slate builds.
            try {
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
              document.execCommand('insertText', false, t);
            } catch (e) {}
          }
          function tryQwSend() {
            var btn = findQwSend();
            if (sendEnabled(btn)) {
              tap(btn);
              return true;
            }
            return false;
          }
          if (!tryQwSend()) {
            var n = 0;
            var timer = setInterval(function() {
              if (tryQwSend() || ++n >= 16) clearInterval(timer);
            }, 150);
          }
          return editor ? 'ok-slate' : 'ok-fallback';
        })();
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!alive()) return;
      await controller.executeScript(clickSendJs);
    } else {
      await controller.insertTextVerified(text);
      if (!alive()) return;
      await controller.executeScript(clickSendJs);
    }
    if (!alive()) return;

    // Extra force-send pass for Wenxin / Qianwen after fill settles.
    if (isYiyanSite || isTongyiSite) {
      await controller.executeScript(r'''
        (function() {
          var host = (location.hostname || '').toLowerCase();
          var isTongyi = /tongyi|qianwen|aliyun/.test(host);
          function tap(el, forceEnable) {
            if (!el) return;
            if (forceEnable) {
              try {
                el.removeAttribute('disabled');
                el.removeAttribute('aria-disabled');
                el.disabled = false;
              } catch (e) {}
            }
            try { el.click(); } catch (e) {}
            try { if (el.parentElement) el.parentElement.click(); } catch (e) {}
          }
          function enabled(el) {
            return !!(el && !el.disabled && el.getAttribute('aria-disabled') !== 'true');
          }
          if (!isTongyi) {
            var wenxin = document.querySelector('#ci-submit-button-ai') ||
              document.querySelector('.ci-submit-button-ai-active') ||
              document.querySelector('.ci-submit-button') ||
              document.querySelector('.cs-input-ds-send-btn');
            tap(wenxin, true);
          }
          var nodes = document.querySelectorAll('button, [role="button"]');
          for (var i = 0; i < nodes.length; i++) {
            var label = ((nodes[i].getAttribute('aria-label') || '') + (nodes[i].innerText || '')).trim();
            if (label.indexOf('\u53d1\u9001') >= 0) {
              // Qianwen: only click when truly enabled (force-enable does nothing useful).
              if (!isTongyi || enabled(nodes[i])) tap(nodes[i], !isTongyi);
            }
          }
          var box = document.querySelector('#chat-input-box') ||
            document.querySelector('[role="textbox"][contenteditable="true"]') ||
            document.querySelector('#chat-textarea');
          if (box) {
            try {
              box.dispatchEvent(new KeyboardEvent('keydown', {
                bubbles: true, cancelable: true, key: 'Enter', code: 'Enter',
                keyCode: 13, which: 13
              }));
            } catch (e) {}
          }
        })();
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    // 3) Brief linger so the click lands, then caller switches to next AI.
    await Future<void>.delayed(
      Duration(milliseconds: isMobile ? 350 : 180),
    );
  }

  /// Sync mode: user-picked AIs. Otherwise send to every initialized page.
  List<int> _syncTargets() {
    if (_syncMode && _syncSelection.isNotEmpty) {
      return _syncSelection.toList();
    }
    return List<int>.generate(_aiConfigs.length, (i) => i);
  }

  void _enterSyncMode() {
    setState(() {
      _syncMode = true;
      if (_syncSelection.isEmpty) {
        for (var i = 0; i < _aiConfigs.length; i++) {
          _syncSelection.add(i);
        }
      }
    });
    unawaited(_prewarmSyncTargets());
  }

  void _exitSyncMode() {
    _inputController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _syncMode = false;
      _pendingSyncText = null;
      _pendingSyncTargets.clear();
    });
  }

  void _toggleSyncTarget(int index) {
    setState(() {
      if (_syncSelection.contains(index)) {
        if (_syncSelection.length > 1) {
          _syncSelection.remove(index);
        }
      } else {
        _syncSelection.add(index);
      }
    });
    if (_syncSelection.contains(index)) {
      unawaited(() async {
        await _ensureWebView(index);
        if (!mounted) return;
        setState(() {});
        await WidgetsBinding.instance.endOfFrame;
        final controller = _controllers[index];
        if (!controller.isInitialized) return;
        await controller.waitUntilReady();
        await controller.waitUntilComposerReady(
          timeout: const Duration(seconds: 25),
        );
      }());
    }
  }

  Future<void> _reloadCurrent() async {
    final targets =
        _compareMode ? _compareSelection.toList() : <int>[_selectedIndex];
    await _ensureWebViews(targets);
    for (final index in targets) {
      final controller = _controllers[index];
      if (!controller.isInitialized) continue;
      try {
        await controller.reload();
      } catch (e) {
        debugPrint('刷新页面失败: $e');
      }
    }
  }

  Future<void> _reloadAll() async {
    for (final controller in _controllers) {
      if (!controller.isInitialized) continue;
      try {
        await controller.reload();
      } catch (e) {
        debugPrint('刷新页面失败: $e');
      }
    }
  }

  void _enterCompareMode() {
    setState(() {
      _compareMode = true;
      if (_compareSelection.isEmpty) {
        _compareSelection.add(_selectedIndex);
        if (_aiConfigs.length > 1) {
          _compareSelection.add((_selectedIndex + 1) % _aiConfigs.length);
        }
      }
    });
    _ensureWebViews(_compareSelection);
  }

  void _exitCompareMode() {
    setState(() {
      _compareMode = false;
      if (_compareSelection.isNotEmpty) {
        _selectedIndex = _compareSelection.first;
      }
    });
  }

  void _clampCompareSelection() {
    if (_compareSelection.isEmpty && _compareMode) {
      _compareSelection.add(_selectedIndex);
    }
  }

  void _onAiTapped(int index) {
    if (_compareMode) {
      setState(() {
        if (_compareSelection.contains(index)) {
          if (_compareSelection.length > 1) {
            _compareSelection.remove(index);
          }
        } else {
          _compareSelection.add(index);
        }
      });
      _ensureWebViews(_compareSelection);
      _clampCompareSelection();
      return;
    }
    _selectAi(index);
  }

  @override
  void dispose() {
    if (isWindowsDesktop) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    for (var c in _controllers) {
      c.dispose();
    }
    _inputController.dispose();
    _aiChipScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = isCompactLayout(MediaQuery.sizeOf(context).width);
    final fabMargin = compact ? 12.0 : 48.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      drawer: compact
          ? Drawer(
              width: 280,
              child: SafeArea(child: _buildSideBar(context, inDrawer: true)),
            )
          : null,
      body: Column(
        children: [
          if (compact)
            _buildMobileAppBar(context)
          else
            _buildWindowTitleBar(context),
          Expanded(
            child: Row(
              children: [
                if (!compact) _buildSideBar(context, inDrawer: false),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            (!compact && _compareMode)
                                ? _buildCompareView()
                                : (compact
                                    ? _buildMobileWebViewStack()
                                    : _buildWebView(_selectedIndex)),
                            if (!compact)
                              Positioned(
                                right: fabMargin,
                                bottom: fabMargin,
                                child: Material(
                                  elevation: 2,
                                  shadowColor: Colors.black26,
                                  borderRadius: BorderRadius.circular(28),
                                  color: Colors.white.withOpacity(0.94),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          onPressed: _reloadCurrent,
                                          icon: const Icon(Icons.refresh),
                                          tooltip: _compareMode
                                              ? '刷新对比中的页面'
                                              : '刷新当前页',
                                        ),
                                        IconButton(
                                          onPressed: _reloadAll,
                                          icon: const Icon(
                                              Icons.replay_circle_filled),
                                          tooltip: '刷新全部',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_syncMode) _buildBottomBar(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: _kAppBarColor,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Material(
        color: _kAppBarColor,
        elevation: 0,
        child: SafeArea(
          bottom: false,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.black.withOpacity(0.06)),
              ),
            ),
            child: Row(
              children: [
                Builder(
                  builder: (ctx) => IconButton(
                    tooltip: '菜单',
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                    icon: const Icon(Icons.menu),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _aiChipScrollController,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                    child: Row(
                      children: [
                        for (var i = 0; i < _aiConfigs.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          ChoiceChip(
                            selected: i == _selectedIndex,
                            avatar: Icon(
                              _aiConfigs[i]['icon'] as IconData,
                              size: 16,
                              color: i == _selectedIndex
                                  ? colorScheme.onPrimary
                                  : colorScheme.primary,
                            ),
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_aiConfigs[i]['name'] as String),
                                if (_pendingSyncTargets.contains(i)) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: i == _selectedIndex
                                          ? colorScheme.onPrimary
                                          : colorScheme.tertiary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            selectedColor: colorScheme.primary,
                            labelStyle: TextStyle(
                              color: i == _selectedIndex
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onSelected: (_) => _selectAi(i),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWindowTitleBar(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(0.06)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: isWindowsDesktop
                ? DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () async {
                        try {
                          if (await windowManager.isMaximized()) {
                            await windowManager.unmaximize();
                          } else {
                            await windowManager.maximize();
                          }
                        } catch (_) {}
                      },
                      child: _buildTitleIdentity(context),
                    ),
                  )
                : _buildTitleIdentity(context),
          ),
          if (isWindowsDesktop) ...[
            _TitleBarButton(
              icon: Icons.remove,
              tooltip: '最小化',
              onPressed: () {
                try {
                  windowManager.minimize();
                } catch (_) {}
              },
            ),
            _TitleBarButton(
              icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
              tooltip: _isMaximized ? '还原' : '最大化',
              iconSize: _isMaximized ? 14 : 16,
              onPressed: () async {
                try {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                } catch (_) {}
              },
            ),
            _TitleBarButton(
              icon: Icons.close,
              tooltip: '关闭',
              isClose: true,
              onPressed: () {
                try {
                  windowManager.close();
                } catch (_) {}
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTitleIdentity(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/app_icon.png',
              width: 20,
              height: 20,
              errorBuilder: (_, __, ___) => Icon(
                Icons.hub_outlined,
                size: 18,
                color: colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '智慧饼',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            child: Row(
              children: [
                Icon(icon, size: 22, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSideBar(BuildContext context, {required bool inDrawer}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: inDrawer ? double.infinity : 108,
      decoration: BoxDecoration(
        color: Colors.white,
        border: inDrawer
            ? null
            : Border(
                right: BorderSide(color: Colors.black.withOpacity(0.06)),
              ),
      ),
      child: Column(
        children: [
          if (inDrawer) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/app_icon.png',
                      width: 36,
                      height: 36,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.hub_outlined,
                        size: 32,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '智慧饼',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
              itemCount: _aiConfigs.length,
              itemBuilder: (context, index) {
                final ai = _aiConfigs[index];
                final selected = _compareMode
                    ? _compareSelection.contains(index)
                    : index == _selectedIndex;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: selected
                        ? colorScheme.primary.withOpacity(0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        if (inDrawer) {
                          _selectAi(index);
                          Navigator.of(context).maybePop();
                          return;
                        }
                        _onAiTapped(index);
                      },
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                            vertical: 12, horizontal: inDrawer ? 10 : 6),
                        child: inDrawer
                            ? Row(
                                children: [
                                  Icon(
                                    ai['icon'] as IconData,
                                    size: 22,
                                    color: selected
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      ai['name'] as String,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: selected
                                                ? colorScheme.primary
                                                : colorScheme.onSurface,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                    ),
                                  ),
                                  if (_compareMode && selected)
                                    Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: colorScheme.primary,
                                    ),
                                ],
                              )
                            : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  ai['icon'] as IconData,
                                  size: 22,
                                  color: selected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                ),
                                if (_compareMode && selected)
                                  Positioned(
                                    right: -6,
                                    top: -6,
                                    child: Icon(
                                      Icons.check_circle,
                                      size: 14,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              ai['name'] as String,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: selected
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    height: 1.2,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          if (inDrawer) ...[
            _buildDrawerAction(
              context,
              icon: Icons.refresh,
              label: '刷新当前页',
              onTap: () {
                Navigator.of(context).maybePop();
                _reloadCurrent();
              },
            ),
            _buildDrawerAction(
              context,
              icon: Icons.replay_circle_filled,
              label: '刷新全部',
              onTap: () {
                Navigator.of(context).maybePop();
                _reloadAll();
              },
            ),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, inDrawer ? 12 : 4),
            child: Material(
              color: _syncMode
                  ? colorScheme.primary.withOpacity(0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  if (inDrawer) {
                    Navigator.of(context).maybePop();
                  }
                  if (_syncMode) {
                    _exitSyncMode();
                  } else {
                    _enterSyncMode();
                  }
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: inDrawer ? 10 : 4,
                  ),
                  child: inDrawer
                      ? Row(
                          children: [
                            Icon(
                              Icons.sync_alt_rounded,
                              size: 22,
                              color: _syncMode
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _syncMode ? '退出同步' : '同步发送',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: _syncMode
                                          ? colorScheme.primary
                                          : colorScheme.onSurface,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            Icon(
                              Icons.sync_alt_rounded,
                              size: 22,
                              color: _syncMode
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _syncMode ? '退出同步' : '同步发送',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: _syncMode
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          if (!inDrawer)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Material(
                color: _compareMode
                    ? colorScheme.primary.withOpacity(0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    if (_compareMode) {
                      _exitCompareMode();
                    } else {
                      _enterCompareMode();
                    }
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    child: Column(
                      children: [
                        Icon(
                          Icons.compare_arrows_rounded,
                          size: 22,
                          color: _compareMode
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _compareMode ? '退出对比' : '对比查看',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: _compareMode
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompareView() {
    final indices = _compareSelection.toList();
    if (indices.isEmpty) {
      return Center(
        child: Text(
          '请勾选要对比的 AI',
          style: TextStyle(color: Colors.black.withOpacity(0.45)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const minPaneWidth = 280.0;
        final useScroll =
            constraints.maxWidth < minPaneWidth * indices.length;
        final paneWidth = useScroll
            ? minPaneWidth
            : constraints.maxWidth / indices.length;

        if (useScroll) {
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: indices.length,
            separatorBuilder: (_, __) => VerticalDivider(
              width: 1,
              thickness: 1,
              color: Colors.black.withOpacity(0.08),
            ),
            itemBuilder: (_, i) => SizedBox(
              width: paneWidth,
              child: _buildComparePane(indices[i]),
            ),
          );
        }

        return Row(
          children: [
            for (var i = 0; i < indices.length; i++) ...[
              if (i > 0)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Colors.black.withOpacity(0.08),
                ),
              Expanded(child: _buildComparePane(indices[i])),
            ],
          ],
        );
      },
    );
  }

  Widget _buildComparePane(int index) {
    final ai = _aiConfigs[index];
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Colors.black.withOpacity(0.06)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                ai['icon'] as IconData,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ai['name'] as String,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              IconButton(
                tooltip: '移出对比',
                onPressed: () {
                  if (_compareSelection.length <= 1) return;
                  setState(() => _compareSelection.remove(index));
                },
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
        Expanded(child: _buildWebView(index)),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final targets = _syncTargets();
    final compact = isCompactLayout(MediaQuery.sizeOf(context).width);

    return Container(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 20,
        12,
        compact ? 12 : 20,
        (compact ? 12 : 14) + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.black.withOpacity(0.06)),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _aiConfigs.length; i++)
                    FilterChip(
                      selected: _syncSelection.contains(i),
                      avatar: Icon(
                        _aiConfigs[i]['icon'] as IconData,
                        size: 16,
                        color: _syncSelection.contains(i)
                            ? colorScheme.onPrimary
                            : colorScheme.primary,
                      ),
                      label: Text(_aiConfigs[i]['name'] as String),
                      onSelected: _isSending ? null : (_) => _toggleSyncTarget(i),
                      selectedColor: colorScheme.primary,
                      checkmarkColor: colorScheme.onPrimary,
                      labelStyle: TextStyle(
                        color: _syncSelection.contains(i)
                            ? colorScheme.onPrimary
                            : colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                      showCheckmark: false,
                      side: BorderSide(
                        color: _syncSelection.contains(i)
                            ? colorScheme.primary
                            : Colors.black.withOpacity(0.12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      enabled: !_isSending,
                      decoration: InputDecoration(
                        hintText: _isSending
                            ? '正在发送…'
                            : (_pendingSyncTargets.isNotEmpty
                                ? '已排队 ${_pendingSyncTargets.length} 个，切换到对应 AI 时自动发送'
                                : '输入问题，先发当前页；切换其他已选 AI 时再发送'),
                      ),
                      onSubmitted: (_) {
                        if (!_isSending) _sendToAll();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () {
                      if (!_isSending) _sendToAll();
                    },
                    icon: _isSending
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: Text(
                      _isSending
                          ? '发送中…'
                          : (compact
                              ? '发送 (${targets.length})'
                              : '同步发送 (${targets.length})'),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: EdgeInsets.symmetric(
                          horizontal: compact ? 12 : 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileWebViewStack() {
    final selected = _selectedIndex.clamp(0, _aiConfigs.length - 1);
    // Keep every initialized WebView in the paint tree. IndexedStack hides
    // inactive children and Android then fails composer focus/React updates.
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _aiConfigs.length; i++)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: i != selected,
              child: Opacity(
                opacity: i == selected ? 1 : 0,
                child: _isInitialized[i]
                    ? _controllers[i]
                        .buildView(key: ValueKey('mobile-webview-$i'))
                    : const ColoredBox(
                        color: Colors.white,
                        child: Center(child: CircularProgressIndicator()),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWebView(int index) {
    if (!_isInitialized[index]) {
      return const Center(child: CircularProgressIndicator());
    }

    // Remount when layout mode changes so surface size is reported fresh.
    return _controllers[index].buildView(
      key: ValueKey(
        'webview-$index-${_compareMode ? 'compare-${_compareSelection.length}' : 'single'}',
      ),
    );
  }
}

class _TitleBarButton extends StatelessWidget {
  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 18,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 44,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: isClose ? const Color(0xFFE81123) : Colors.black12,
          child: Tooltip(
            message: tooltip,
            child: Center(
              child: Icon(icon, size: iconSize, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}
