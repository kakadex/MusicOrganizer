#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <functional>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// 窗口位置 / 大小记忆的注册表位置（0.3.9 第二期）。
///
/// 纯系统 API（RegSetValueEx / GetWindowPlacement），不引第三方窗口库：
/// `window_manager` 那类包能做的「记住窗口」它都能做，少一个依赖少一类问题。
constexpr const wchar_t kWindowRectRegKey[] = L"Software\\MusicOrganizer\\Window";
constexpr const wchar_t kWindowRectRegValue[] = L"Placement";

/// 窗口最小客户区尺寸（逻辑像素）：再小布局就挤坏了。
constexpr int kMinClientWidth = 720;
constexpr int kMinClientHeight = 480;

/// 读上次的窗口摆放；成功返回 true。
bool LoadWindowPlacement(HWND hwnd) {
  DWORD size = 0;
  if (RegGetValueW(HKEY_CURRENT_USER, kWindowRectRegKey, kWindowRectRegValue,
                   RRF_RT_REG_BINARY, nullptr, nullptr, &size) != ERROR_SUCCESS ||
      size != sizeof(WINDOWPLACEMENT)) {
    return false;
  }
  WINDOWPLACEMENT wp = {};
  wp.length = sizeof(WINDOWPLACEMENT);
  if (RegGetValueW(HKEY_CURRENT_USER, kWindowRectRegKey, kWindowRectRegValue,
                   RRF_RT_REG_BINARY, nullptr, &wp, &size) != ERROR_SUCCESS) {
    return false;
  }
  wp.length = sizeof(WINDOWPLACEMENT);
  // 只恢复位置/大小，不恢复最大化状态（用户可能换过显示器，恢复最大化
  // 容易落在看不见的地方）；越界的坐标也丢弃。
  wp.flags = 0;
  wp.showCmd = SW_SHOWNORMAL;
  if (wp.rcNormalPosition.right - wp.rcNormalPosition.left < kMinClientWidth ||
      wp.rcNormalPosition.bottom - wp.rcNormalPosition.top < kMinClientHeight) {
    return false;
  }
  // 位置必须落在某个显示器上，否则丢弃（比如拔掉了外接屏）
  HMONITOR mon =
      MonitorFromRect(&wp.rcNormalPosition, MONITOR_DEFAULTTONULL);
  if (mon == nullptr) return false;
  return SetWindowPlacement(hwnd, &wp) != 0;
}

/// 保存当前窗口摆放（关闭时调用）。
void SaveWindowPlacement(HWND hwnd) {
  if (hwnd == nullptr) return;
  WINDOWPLACEMENT wp = {};
  wp.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &wp)) return;
  // 最大化 / 最小化时记录的是还原后的位置，这才是用户想要的
  wp.flags = 0;
  // RegSetValueExW 不会自动创建父键，必须先建
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowRectRegKey, 0, nullptr, 0,
                      KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  RegSetValueExW(key, kWindowRectRegValue, 0, REG_BINARY,
                 reinterpret_cast<const BYTE*>(&wp), sizeof(WINDOWPLACEMENT));
  RegCloseKey(key);
}

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

// 自绘标题栏（0.4.0 第三期）：无边框窗口样式。
//
// WS_POPUP 去掉系统标题栏与边框（省一行空间），但**保留 WS_THICKFRAME**——
// 没有它就不能拖窗口边缘缩放。WS_CLIPCHILDREN 避免 Flutter 子窗口重绘闪烁。
static const DWORD kWindowStyle = WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX |
                                  WS_MAXIMIZEBOX | WS_SYSMENU | WS_CLIPCHILDREN;

// 最大化状态变化回调（自绘标题栏需要知道什么时候换「还原」图标）。
// 由 FlutterWindow 注册，把状态推给 Dart。
static std::function<void(bool)> g_maximized_callback;

// 最小窗口尺寸（物理像素，含边框）。WM_GETMINMAXINFO 里用（0.3.9 第二期）。
static LONG g_min_track_width = 0;
static LONG g_min_track_height = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// 自绘标题栏（0.4.0 第三期）：无边框窗口的边缘缩放命中判定。
//
// 返回 HTLEFT / HTTOPLEFT / ... / HTCLIENT。**父窗口和 Flutter 子窗口
// 都要用这同一套判定**——鼠标在客户区里命中的是子窗口 FLUTTERVIEW，
// 只在父窗口判是拦不住的（实测拖右下角纹丝不动）。
LRESULT HitTestBorder(HWND hwnd, LPARAM lparam) {
  const LRESULT base = DefWindowProc(hwnd, WM_NCHITTEST, 0, lparam);
  if (base != HTCLIENT) return base;

  POINT pt = {static_cast<LONG>(static_cast<short>(LOWORD(lparam))),
              static_cast<LONG>(static_cast<short>(HIWORD(lparam)))};
  RECT rc;
  GetWindowRect(hwnd, &rc);

  const UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
  const int border = static_cast<int>(8 * dpi / 96.0);

  const bool left = pt.x < rc.left + border;
  const bool right = pt.x >= rc.right - border;
  const bool top = pt.y < rc.top + border;
  const bool bottom = pt.y >= rc.bottom - border;

  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// 子类化 Flutter 视图子窗口（FLUTTERVIEW）所需的上下文。
// 用全局单例（而非 GWLP_USERDATA），避免覆盖 Flutter 自己对 USERDATA 的使用。
struct FlutterViewSubclass {
  WNDPROC original = nullptr;  // 原 Flutter WndProc，其它消息交还它
};
static FlutterViewSubclass g_flutter_view_subclass;

// 子窗口自己的窗口过程：只在 WM_NCHITTEST 抢边框判定，其余一律交还 Flutter。
LRESULT CALLBACK FlutterViewProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (g_flutter_view_subclass.original == nullptr) {
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  if (message == WM_NCHITTEST) {
    // 边缘 8px 命中为边框方向，系统据此执行缩放并切换缩放光标；
    // 命中内部时交还 Flutter 自己的过程（其内部处理鼠标事件）。
    const LRESULT ht = HitTestBorder(hwnd, lparam);
    if (ht != HTCLIENT) return ht;
  }
  return CallWindowProc(g_flutter_view_subclass.original, hwnd, message, wparam,
                        lparam);
}

// 子类化 Flutter 视图子窗口：把它的 WM_NCHITTEST 改走 HitTestBorder。
// 无边框窗口整个客户区被 FLUTTERVIEW 铺满，鼠标在边缘时命中消息只发给这个
// 子窗口、顶层窗口过程收不到，所以必须在这里也判边框，否则「拖边框纹丝不动、
// 也无缩放光标」。
void SubclassFlutterView(HWND child) {
  if (child == nullptr || g_flutter_view_subclass.original != nullptr) return;
  g_flutter_view_subclass.original = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      child, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&FlutterViewProc)));
}

// 最大化状态变化回调注册（自绘标题栏，0.4.0 第三期）。
// 必须放在匿名 namespace **外面**，否则外部编译单元（flutter_window.cpp）
// 链接不到——曾因此报 LNK2019 无法解析的外部符号。
void SetMaximizedCallback(std::function<void(bool)> cb) {
  g_maximized_callback = std::move(cb);
}

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), kWindowStyle,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  // 0.3.9 第二期：恢复上次的窗口位置 / 大小，并设置最小尺寸（客户区）。
  LoadWindowPlacement(window);
  {
    const UINT dpi2 = FlutterDesktopGetDpiForMonitor(
        MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
    const double sf = dpi2 / 96.0;
    RECT frame = {0, 0, Scale(kMinClientWidth, sf),
                  Scale(kMinClientHeight, sf)};
    AdjustWindowRectEx(&frame, kWindowStyle, FALSE, 0);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    // WM_GETMINMAXINFO 里读这两个值，这里用静态存储传过去
    g_min_track_width = frame.right - frame.left;
    g_min_track_height = frame.bottom - frame.top;
  }

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    // 0.3.9 第二期：限制最小窗口尺寸，避免拖太小把布局挤坏
    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (g_min_track_width > 0) {
        info->ptMinTrackSize.x = g_min_track_width;
      }
      if (g_min_track_height > 0) {
        info->ptMinTrackSize.y = g_min_track_height;
      }
      return 0;
    }

    // 0.3.9 第二期：关闭时保存窗口位置 / 大小。
    // 必须在 WM_DESTROY **之前**存（那时 HWND 还有效）；存完交回
    // DefWindowProc 走正常销毁流程。
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      return DefWindowProc(hwnd, message, wparam, lparam);

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // 自绘标题栏（0.4.0 第三期）：最大化状态变了要通知 Dart 换按钮图标。
      // SIZE_MAXIMIZED / SIZE_RESTORED 都会走到这里。
      if (g_maximized_callback) {
        g_maximized_callback(IsZoomed(hwnd) != 0);
      }
      return 0;
    }

    // 自绘标题栏（0.4.0 第三期）：无边框窗口的**边缘缩放**。
    // 判定逻辑抽到 HitTestBorder，子窗口那边也用同一套。
    case WM_NCHITTEST:
      return HitTestBorder(hwnd, lparam);

    case WM_NCCALCSIZE:
      // 无边框：客户区铺满整个窗口，不留任何非客户区。
      if (wparam == TRUE) return 0;
      break;

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  // 子类化 Flutter 视图子窗口：让边缘缩放（WM_NCHITTEST）也在子窗口生效，
  // 否则无边框窗口拖边框纹丝不动、也无缩放光标。
  SubclassFlutterView(content);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
