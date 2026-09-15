#include "flutter_window.h"

#include <optional>
#include <cstring>

#include "flutter/generated_plugin_registrant.h"
#include "../platform/platform_bridge.h"

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
  platform_bridge_ = std::make_unique<share_hub::PlatformBridge>(
      flutter_controller_->engine()->messenger(), GetHandle(),
      L"Software\\ShareHub\\Client");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  platform_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (platform_bridge_ && platform_bridge_->HandleMessage(message, wparam)) return 0;
  if (message == WM_GETMINMAXINFO) {
    const auto dpi = FlutterDesktopGetDpiForMonitor(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
    RECT minimum{0, 0, MulDiv(860, dpi, 96), MulDiv(640, dpi, 96)};
    const auto style = static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE));
    const auto extended = static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE));
    using AdjustForDpi = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD, UINT);
    AdjustForDpi adjust = nullptr;
    auto address = GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi");
    static_assert(sizeof(adjust) == sizeof(address));
    std::memcpy(&adjust, &address, sizeof(adjust));
    if (adjust) adjust(&minimum, style, FALSE, extended, dpi);
    else AdjustWindowRectEx(&minimum, style, FALSE, extended);
    auto* sizes = reinterpret_cast<MINMAXINFO*>(lparam);
    sizes->ptMinTrackSize.x = minimum.right - minimum.left;
    sizes->ptMinTrackSize.y = minimum.bottom - minimum.top;
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
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
