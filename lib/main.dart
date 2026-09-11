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
      // 应用程序在任务栏和窗口管理器中显示的标题
      title: 'AI Toolbox',
      // 隐藏右上角的 "Debug" 标志
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 使用深紫色作为主题种子色，并开启 Material 3 设计规范
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 设置首页为多 AI 聚合页面
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
  // 当前左侧边栏选中的 AI 索引
  int _selectedIndex = 0; 
  // 控制底部全局输入框内容的控制器
  final TextEditingController _inputController = TextEditingController();
  
  // AI 平台的配置列表：包含显示名称、访问网址以及对应的图标
  final List<Map<String, dynamic>> _aiConfigs = [
    {'name': '豆包', 'url': 'https://www.doubao.com', 'icon': Icons.auto_awesome},
    {'name': 'DeepSeek', 'url': 'https://chat.deepseek.com', 'icon': Icons.psychology},
  ];

  // 为每个 AI 平台创建独立的 Webview 控制器，确保页面状态（如登录、对话）不冲突
  final List<WebviewController> _controllers = [
    WebviewController(),
    WebviewController(),
  ];

  // 记录每个 Webview 实例是否已完成初始化
  final List<bool> _isInitialized = [false, false];

  @override
  void initState() {
    super.initState();
    // 页面加载时开始初始化所有 AI 窗口
    _initAllWebViews();
  }

  /// 初始化所有 Webview 实例的异步方法
  Future<void> _initAllWebViews() async {
    for (int i = 0; i < _aiConfigs.length; i++) {
      try {
        // 初始化浏览器核心
        await _controllers[i].initialize();
        // 设置默认背景色为白色，避免加载瞬间出现黑边
        await _controllers[i].setBackgroundColor(Colors.white);
        // 禁止弹出独立的新窗口，强制在当前视图内跳转
        await _controllers[i].setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
        // 加载配置中的 URL
        await _controllers[i].loadUrl(_aiConfigs[i]['url']);
        
        if (mounted) {
          setState(() {
            _isInitialized[i] = true;
          });
        }
      } catch (e) {
        // 如果初始化失败，在控制台打印错误
        debugPrint('WebView $i 初始化失败: $e');
      }
    }
  }

  /// 一键同步咨询逻辑：将全局输入框的内容注入到所有正在运行的 AI 页面并尝试触发发送
  void _sendToAll() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    for (var controller in _controllers) {
      // 仅处理已初始化成功的 Webview
      if (!controller.value.isInitialized) continue;
      
      // JavaScript 强效注入脚本：
      // 1. 自动寻找各个大模型页面的输入框（textarea 或 contenteditable 元素）
      // 2. 使用 execCommand('insertText') 模拟物理键盘输入，这是绕过 React/Vue 状态拦截的关键
      // 3. 寻找并点击“发送”按钮，或者模拟回车键保底
      const jsCode = """
        (function(val) {
          var el = document.getElementById('chat-input') || 
                   document.querySelector('textarea') || 
                   document.querySelector('[contenteditable="true"]');
          if (el) {
            el.focus();
            try {
              // 全选内容并插入，确保触发网页框架的数据双向绑定
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, val);
            } catch(e) {
              el.value = val;
            }
            // 派发输入事件通知网页
            el.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
            el.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
            
            // 延迟 400ms，等待网页 UI 响应输入后再模拟点击发送
            setTimeout(function() {
              var buttons = Array.from(document.querySelectorAll('button'));
              var sendBtn = buttons.find(function(btn) {
                var html = btn.innerHTML.toLowerCase();
                var btnText = btn.innerText.trim();
                // 智能匹配：包含“发送”字样、"Send" 或包含特定的 svg 图标路径
                return (btnText === '发送' || btnText === 'Send' || html.includes('send') || html.includes('arrow')) && !btn.disabled;
              });
              if (sendBtn) {
                sendBtn.click();
              } else {
                // 如果没找到确定的发送按钮，发送物理回车按键事件
                var keyParams = { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
                el.dispatchEvent(new KeyboardEvent('keydown', keyParams));
              }
            }, 400);
          }
        })
      """;
      controller.executeScript("$jsCode('${text.replaceAll("'", "\\'").replaceAll("\n", "\\n")}');");
    }
    // 操作完成后，清空本地全局输入框
    _inputController.clear();
  }

  @override
  void dispose() {
    // 页面销毁时释放 Webview 资源
    for (var c in _controllers) { c.dispose(); }
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 左侧固定导航栏
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) => setState(() => _selectedIndex = index),
            labelType: NavigationRailLabelType.all,
            destinations: _aiConfigs.map((ai) => NavigationRailDestination(
              icon: Icon(ai['icon']),
              label: Text(ai['name']),
            )).toList(),
          ),
          // 垂直分割线
          const VerticalDivider(thickness: 1, width: 1),
          // 右侧内容主体
          Expanded(
            child: Column(
              children: [
                // 使用 IndexedStack 包裹 Webview 视图，确保切换 Tab 时后台页面不被销毁，保持会话状态
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      _buildWebView(0),
                      _buildWebView(1),
                    ],
                  ),
                ),
                // 底部全局输入控制栏
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    // 使用 surfaceVariant 柔和配色，并设置微弱透明
                    color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                    border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.1))),
                  ),
                  child: Row(
                    children: [
                      // 同步输入框
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          decoration: const InputDecoration(
                            hintText: '在此写下问题，一键同步发送...',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          // 支持回车键触发同步咨询
                          onSubmitted: (_) => _sendToAll(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 发送按钮
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

  /// 构建单个 Webview 的小部件封装，处理未初始化时的加载反馈
  Widget _buildWebView(int index) {
    if (!_isInitialized[index]) {
      return const Center(child: CircularProgressIndicator());
    }
    return Webview(_controllers[index]);
  }
}
