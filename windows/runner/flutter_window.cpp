#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Channel used to hand dropped file/folder paths over to the Dart side.
  drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.dsh.musicorganizer/drop",
      &flutter::StandardMethodCodec::GetInstance());

  // 外观三态（0.3.17）：标题栏深浅跟随应用 + 系统明暗变化通知。
  appearance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.dsh.musicorganizer/appearance",
          &flutter::StandardMethodCodec::GetInstance());
  appearance_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "isSystemDark") {
          result->Success(flutter::EncodableValue(Win32Window::IsSystemDark()));
          return;
        }
        if (call.method_name() == "setDarkTitleBar") {
          // 参数为 null 表示「跟随系统」，否则是应用显式选择的明暗。
          if (call.arguments() == nullptr) {
            Win32Window::ClearTitleBarOverride(GetHandle());
          } else {
            const bool* dark = std::get_if<bool>(call.arguments());
            if (dark == nullptr) {
              result->Error("bad_args", "setDarkTitleBar expects bool or null");
              return;
            }
            Win32Window::SetTitleBarDark(GetHandle(), *dark);
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  // Accept files and folders dragged onto this window (enables WM_DROPFILES).
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Collect every dropped path, forward it to Dart, then finish the drop.
  if (message == WM_DROPFILES) {
    auto drop = reinterpret_cast<HDROP>(wparam);
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    flutter::EncodableList paths;
    for (UINT i = 0; i < count; ++i) {
      const UINT len = DragQueryFileW(drop, i, nullptr, 0);
      if (len == 0) {
        continue;
      }
      std::wstring buf(len + 1, L'\0');
      const UINT copied = DragQueryFileW(drop, i, buf.data(), len + 1);
      if (copied == 0) {
        continue;
      }
      buf.resize(copied);
      paths.push_back(flutter::EncodableValue(Utf8FromUtf16(buf.c_str())));
    }
    DragFinish(drop);
    if (drop_channel_ && !paths.empty()) {
      drop_channel_->InvokeMethod(
          "onDrop",
          std::make_unique<flutter::EncodableValue>(paths));
    }
    return 0;
  }

  // 系统深浅色切换（0.3.17）：Windows 广播 WM_SETTINGCHANGE("ImmersiveColorSet")。
  // 1. 按当前覆盖 / 系统设置重设原生标题栏；
  // 2. 推给 Dart —— Windows 上 Flutter 的 platformBrightness 不保证随系统刷新，
  //    「跟随系统」靠这条消息才能即时生效。
  if (message == WM_SETTINGCHANGE && lparam != 0 &&
      std::wstring(reinterpret_cast<const wchar_t*>(lparam)) ==
          L"ImmersiveColorSet") {
    Win32Window::UpdateTheme(hwnd);
    if (appearance_channel_) {
      appearance_channel_->InvokeMethod(
          "systemThemeChanged",
          std::make_unique<flutter::EncodableValue>(
              Win32Window::IsSystemDark()));
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
