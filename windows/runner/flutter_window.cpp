#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <optional>
#include <string>
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

  // Accept files and folders dragged onto this window (enables WM_DROPFILES).
  DragAcceptFiles(GetHandle(), TRUE);

  // Window controls for the custom title bar (0.4.0 phase 3).
  //
  // 自绘标题栏没有系统边框，拖动/最小化/最大化/关闭都得走这里。拖动用
  // `WM_NCLBUTTONDOWN + HTCAPTION` 交给系统处理——自己算鼠标位移在贴边
  // 吸附、跨屏 DPI 变化时会出错。
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.dsh.musicorganizer/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HWND hwnd = GetHandle();
        const std::string& method = call.method_name();
        if (method == "startDrag") {
          ReleaseCapture();
          SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else {
          result->NotImplemented();
        }
      });

  // 最大化状态变化 → 推给 Dart（换「还原/最大化」图标）。
  SetMaximizedCallback([this](bool maximized) {
    if (window_channel_) {
      window_channel_->InvokeMethod(
          "maximizedChanged",
          std::make_unique<flutter::EncodableValue>(maximized));
    }
  });

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
    // 自绘标题栏（0.4.0 第三期）：**边缘缩放必须在这里判**。
    //
    // 鼠标在客户区时落在 Flutter 的视图子窗口（FLUTTERVIEW）上，
    // WM_NCHITTEST 发给了它；父窗口 HitTestBorder 根本收不到（实测
    // 拖右下角窗口纹丝不动，WindowFromPoint 查出来是 FLUTTERVIEW）。
    // 这里把子窗口的命中改写成边框常量，系统就会执行缩放。
    case WM_NCHITTEST: {
      HWND root = GetAncestor(hwnd, GA_ROOT);
      if (root != nullptr && root != hwnd) {
        return HitTestWindowBorder(root, lparam);
      }
      break;
    }

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
