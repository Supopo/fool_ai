#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);

  if (!window.Create(L"AI Toolbox", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    // Windows delivers WM_MOUSEWHEEL to the focused HWND, which may be WebView2
    // after a click. The page is a Flutter texture, so the event must reach the
    // Flutter view and be forwarded into WebView2 from Dart.
    if (msg.message == WM_MOUSEWHEEL || msg.message == WM_MOUSEHWHEEL) {
      HWND app = window.GetHandle();
      HWND flutter_view = window.GetChildContent();
      HWND under_cursor = ::WindowFromPoint(msg.pt);
      if (app && flutter_view && under_cursor &&
          (under_cursor == app || ::IsChild(app, under_cursor)) &&
          msg.hwnd != flutter_view) {
        ::SendMessage(flutter_view, msg.message, msg.wParam, msg.lParam);
        continue;
      }
    }

    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
