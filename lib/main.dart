import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final LinkedHashSet<int> _compareSelection = LinkedHashSet<int>();
  final LinkedHashSet<int> _syncSelection = LinkedHashSet<int>();

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        windowManager.addListener(this);
        _isMaximized = await windowManager.isMaximized();
        if (mounted) setState(() {});
      } catch (_) {}
    });
    _initAllWebViews();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

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

    final targets = _syncTargets();
    for (final index in targets) {
      final controller = _controllers[index];
      if (!controller.value.isInitialized) continue;
      try {
        await controller.executeScript(focusClearJs);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await controller.insertText(text);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await controller.executeScript(clickSendJs);
      } catch (e) {
        debugPrint('同步发送失败 (${_aiConfigs[index]['name']}): $e');
      }
    }
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
  }

  void _exitSyncMode() {
    _inputController.clear();
    FocusScope.of(context).unfocus();
    setState(() => _syncMode = false);
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
  }

  Future<void> _reloadCurrent() async {
    final targets = _compareMode
        ? _compareSelection.toList()
        : <int>[_selectedIndex];
    for (final index in targets) {
      final controller = _controllers[index];
      if (!controller.value.isInitialized) continue;
      try {
        await controller.reload();
      } catch (e) {
        debugPrint('刷新页面失败: $e');
      }
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
  }

  void _exitCompareMode() {
    setState(() {
      _compareMode = false;
      if (_compareSelection.isNotEmpty) {
        _selectedIndex = _compareSelection.first;
      }
    });
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
      return;
    }
    setState(() => _selectedIndex = index);
  }

  @override
  void dispose() {
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    for (var c in _controllers) { c.dispose(); }
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      body: Column(
        children: [
          _buildWindowTitleBar(context),
          Expanded(
            child: Row(
              children: [
                _buildSideBar(context),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            _compareMode
                                ? _buildCompareView()
                                : _buildWebView(_selectedIndex),
                            Positioned(
                              right: 48,
                              bottom: 48,
                              child: Material(
                                elevation: 2,
                                shadowColor: Colors.black26,
                                borderRadius: BorderRadius.circular(28),
                                color: Colors.white.withOpacity(0.94),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 4),
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

  Widget _buildWindowTitleBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
            child: DragToMoveArea(
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
                child: Padding(
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
                ),
              ),
            ),
          ),
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
      ),
    );
  }

  Widget _buildSideBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 108,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Colors.black.withOpacity(0.06)),
        ),
      ),
      child: Column(
        children: [
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
                      onTap: () => _onAiTapped(index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 6),
                        child: Column(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Material(
              color: _syncMode
                  ? colorScheme.primary.withOpacity(0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  if (_syncMode) {
                    _exitSyncMode();
                  } else {
                    _enterSyncMode();
                  }
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                  child: Column(
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
          '请在左侧勾选要对比的 AI',
          style: TextStyle(color: Colors.black.withOpacity(0.45)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const minPaneWidth = 340.0;
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

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
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
                      onSelected: (_) => _toggleSyncTarget(i),
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
                      decoration: InputDecoration(
                        hintText: '输入问题，同步发送到已选的 ${targets.length} 个 AI…',
                      ),
                      onSubmitted: (_) => _sendToAll(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _sendToAll,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text('同步发送 (${targets.length})'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
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

  Widget _buildWebView(int index) {
    if (!_isInitialized[index]) {
      return const Center(child: CircularProgressIndicator());
    }

    // Remount when layout mode changes so surface size is reported fresh.
    return Webview(
      _controllers[index],
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
