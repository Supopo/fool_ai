import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Toolbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
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

class _MultiAIPageState extends State<MultiAIPage> {
  int _selectedIndex = 0;
  final TextEditingController _inputController = TextEditingController();

  final List<Map<String, dynamic>> _aiConfigs = [
    {'name': 'ChatGPT', 'url': 'https://chatgpt.com', 'icon': Icons.smart_toy},
    {'name': 'DeepSeek', 'url': 'https://chat.deepseek.com', 'icon': Icons.psychology},
    {'name': '豆包', 'url': 'https://www.doubao.com', 'icon': Icons.auto_awesome},
    {'name': '通义千问', 'url': 'https://www.tongyi.com/qianwen', 'icon': Icons.travel_explore},
    {'name': '文心一言', 'url': 'https://yiyan.baidu.com', 'icon': Icons.chat_bubble_outline},
  ];

  late final List<WebviewController> _controllers =
      List.generate(_aiConfigs.length, (_) => WebviewController());

  late final List<bool> _isInitialized =
      List.filled(_aiConfigs.length, false);

  @override
  void initState() {
    super.initState();
    _initAllWebViews();
  }

  Future<void> _initAllWebViews() async {
    for (int i = 0; i < _aiConfigs.length; i++) {
      try {
        await _controllers[i].initialize();
        await _controllers[i].setBackgroundColor(Colors.white);
        await _controllers[i].setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
        await _controllers[i].loadUrl(_aiConfigs[i]['url']);
        if (mounted) {
          setState(() {
            _isInitialized[i] = true;
          });
        }
      } catch (e) {
        debugPrint('WebView $i 初始化失败: $e');
      }
    }
  }

  Future<void> _sendToAll() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    FocusScope.of(context).unfocus();

    // Focus + clear only. Do not write text via DOM — Qianwen/ProseMirror will
    // show ghost text while keeping the real editor state empty (gray send).
    const focusClearJs = r'''
      (function() {
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

    const clickSendJs = r'''
      (function() {
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
        function isDisabled(el) {
          return !!(el.disabled || el.getAttribute('aria-disabled') === 'true' ||
            el.classList.contains('disabled'));
        }
        function findSendBtn(input) {
          var root = (input && input.closest(
            'form, [class*="footer"], [class*="input"], [class*="composer"], [class*="operate"], [class*="bottom"]'
          )) || document;
          var nodes = Array.from(root.querySelectorAll('button, [role="button"]')).filter(visible);
          var scored = nodes.map(function(btn) {
            var label = (
              (btn.getAttribute('aria-label') || '') + ' ' +
              (btn.getAttribute('title') || '') + ' ' +
              (btn.innerText || '') + ' ' +
              (btn.className || '')
            ).toLowerCase();
            var score = 0;
            if (/search|搜索|查找|history|历史/.test(label)) score -= 20;
            if (/发送|提交|\bsend\b|\bsubmit\b/.test(label)) score += 6;
            if (/\b(paper-?plane|send-?icon)\b/.test(label)) score += 3;
            if (isDisabled(btn)) score -= 10;
            return { btn: btn, score: score };
          }).filter(function(x) { return x.score > 0; })
            .sort(function(a, b) { return b.score - a.score; });
          return scored.length ? scored[0].btn : null;
        }
        function pressKey(el, key, mods) {
          mods = mods || {};
          var opts = {
            bubbles: true, cancelable: true, key: key, code: key,
            keyCode: 13, which: 13,
            ctrlKey: !!mods.ctrl, metaKey: !!mods.meta, shiftKey: !!mods.shift
          };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
        }
        var el = findInput();
        if (!el) return false;
        el.focus();
        function tryOnce() {
          var btn = findSendBtn(el);
          if (btn && !isDisabled(btn)) {
            btn.click();
            return true;
          }
          return false;
        }
        if (tryOnce()) return true;
        var n = 0;
        var timer = setInterval(function() {
          if (tryOnce() || ++n >= 10) {
            clearInterval(timer);
            if (n >= 10) {
              pressKey(el, 'Enter');
              setTimeout(function() { pressKey(el, 'Enter', { ctrl: true }); }, 120);
            }
          }
        }, 200);
        return true;
      })()
    ''';

    for (final controller in _controllers) {
      if (!controller.value.isInitialized) continue;
      try {
        await controller.executeScript(focusClearJs);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await controller.insertText(text);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await controller.executeScript(clickSendJs);
      } catch (e) {
        debugPrint('同步发送失败: $e');
      }
    }
  }

  Future<void> _reloadCurrent() async {
    final controller = _controllers[_selectedIndex];
    if (!controller.value.isInitialized) return;
    try {
      await controller.reload();
    } catch (e) {
      debugPrint('刷新当前页失败: $e');
    }
  }

  Future<void> _reloadAll() async {
    for (final controller in _controllers) {
      if (!controller.value.isInitialized) continue;
      try {
        await controller.reload();
      } catch (e) {
        debugPrint('刷新页面失败: $e');
      }
    }
  }

  @override
  void dispose() {
    for (var c in _controllers) { c.dispose(); }
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 88,
            child: Material(
              color: colorScheme.surfaceContainerLow,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _aiConfigs.length,
                itemBuilder: (context, index) {
                  final ai = _aiConfigs[index];
                  final selected = index == _selectedIndex;
                  return InkWell(
                    onTap: () => setState(() => _selectedIndex = index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 4,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            ai['icon'] as IconData,
                            color: selected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ai['name'] as String,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: selected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                  fontWeight:
                                      selected ? FontWeight.w600 : FontWeight.w400,
                                ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      IndexedStack(
                        index: _selectedIndex,
                        children: List.generate(
                          _aiConfigs.length,
                          _buildWebView,
                        ),
                      ),
                      Positioned(
                        right: 48,
                        bottom: 48,
                        child: Material(
                          elevation: 3,
                          borderRadius: BorderRadius.circular(24),
                          color: colorScheme.surface.withOpacity(0.92),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _reloadCurrent,
                                  icon: const Icon(Icons.refresh),
                                  tooltip: '刷新当前页',
                                ),
                                IconButton(
                                  onPressed: _reloadAll,
                                  icon: const Icon(Icons.replay_circle_filled),
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withOpacity(0.3),
                    border: Border(
                      top: BorderSide(color: Colors.grey.withOpacity(0.1)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          decoration: const InputDecoration(
                            hintText: '在此输入问题，一键同步发送...',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _sendToAll(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _sendToAll,
                        icon: const Icon(Icons.send),
                        tooltip: '同步发送',
                      ),
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

  Widget _buildWebView(int index) {
    if (!_isInitialized[index]) {
      return const Center(child: CircularProgressIndicator());
    }

    return Webview(_controllers[index]);
  }
}
