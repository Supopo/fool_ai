# Local changes to webview_windows 0.4.0

Vendored from pub.dev with the upstream LICENSE.

windows/webview.cc scrolls via DevTools Input.dispatchMouseEvent at the last
cursor position. SendMouseInput(WHEEL) in composition mode often only works at
(0, 0), which misses nested chat panes.

lib/src/webview.dart refreshes the cursor position on each wheel and mouse
button event before forwarding input, so clicks after scrolling hit the
element under the cursor.

windows/runner/main.cpp forwards WM_MOUSEWHEEL to the Flutter view when the
pointer is over the app, because Windows sends wheel messages to the focused
HWND (often WebView2 after a click) instead of the texture that hosts the page.

windows/webview.cc calls put_ParentWindow(flutter_view) so WebView2's input
HWND stays in the Flutter window tree. Without this, the first click after
scrolling deactivates the app window and text selection needs a second click
(upstream #230).

windows/webview.cc adds InsertText via DevTools Input.insertText so rich
editors (Qianwen / ProseMirror) receive real typed input and enable send.
lib/src/webview.dart exposes insertText() for Dart callers.

windows/webview_windows_plugin.cc hides all WebView2 surfaces on
SIZE_MINIMIZED and shows them again on restore/maximize, so minimized apps
do not leave an invisible click-blocking overlay on the desktop.

After a full Windows rebuild, verify scrolling, text selection after scroll,
sync-send on Doubao / DeepSeek / ChatGPT / Qianwen / Wenxin, and that the
desktop stays clickable while the app is minimized.
