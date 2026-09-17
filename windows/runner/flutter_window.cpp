#include "flutter_window.h"

#include <optional>
#include <cstring>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "resource.h"

namespace {
constexpr UINT kTrayCallback = WM_APP + 72;
constexpr UINT kExitApproved = WM_APP + 73;
constexpr UINT kOpen = 2101, kAllow = 2102, kStopControl = 2103, kQuit = 2104;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
bool BooleanField(const Value* value, const char* key) {
  const auto* map = value ? std::get_if<Map>(value) : nullptr;
  if (!map) return false;
  const auto found = map->find(Value(key));
  return found != map->end() && std::get_if<bool>(&found->second) && std::get<bool>(found->second);
}
}

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
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  desktop_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.sharehub.client/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (call.method_name() == "initialize") {
      connection_supported_ = BooleanField(call.arguments(), "connectionSupported");
      InstallTray();
      if (!tray_installed_) { result->Error("tray_unavailable", "Cannot create taskbar entry"); return; }
      desktop_ready_ = true;
      DWORD allowed = 0, size = sizeof(allowed);
      RegGetValueW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", L"AllowConnections",
          RRF_RT_REG_DWORD, nullptr, &allowed, &size);
      result->Success(Value(Map{{Value("allowConnections"), Value(allowed == 1)}}));
    } else if (call.method_name() == "state") {
      allow_connections_ = BooleanField(call.arguments(), "allowConnections");
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", 0, nullptr, 0,
          KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save admission preference"); return;
      }
      const DWORD allowed = allow_connections_ ? 1 : 0;
      const auto saved = RegSetValueExW(key, L"AllowConnections", 0, REG_DWORD,
          reinterpret_cast<const BYTE*>(&allowed), sizeof(allowed));
      RegCloseKey(key);
      if (saved != ERROR_SUCCESS) { result->Error("preferences_failed", "Cannot save admission preference"); return; }
      result->Success();
    } else if (call.method_name() == "appearance.read") {
      DWORD theme = 0, size = sizeof(theme);
      RegGetValueW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", L"Appearance", RRF_RT_REG_DWORD, nullptr, &theme, &size);
      result->Success(Value(theme == 1 ? "light" : theme == 2 ? "dark" : "system"));
    } else if (call.method_name() == "appearance.write") {
      const auto* theme = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!theme || (*theme != "system" && *theme != "light" && *theme != "dark")) { result->Error("invalid_theme", "Invalid theme"); return; }
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) { result->Error("preferences_failed", "Cannot save theme"); return; }
      const DWORD value = *theme == "light" ? 1 : *theme == "dark" ? 2 : 0;
      const auto saved = RegSetValueExW(key, L"Appearance", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
      RegCloseKey(key);
      if (saved != ERROR_SUCCESS) { result->Error("preferences_failed", "Cannot save theme"); return; }
      result->Success();
    } else if (call.method_name() == "exit") {
      result->Success(); RequestQuit();
    } else if (call.method_name() == "prepareExit") {
      platform_bridge_->CancelFilePicker(); result->Success();
    } else { result->NotImplemented(); }
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
  alive_.reset();
  if (tray_installed_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_installed_ = false;
  desktop_.reset();
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
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    tray_installed_ = false;
    InstallTray();
    if (!tray_installed_) ShowMainWindow();
    return 0;
  }
  if (message == kExitApproved) { DestroyWindow(hwnd); return 0; }
  if (message == kTrayCallback) {
    if (LOWORD(lparam) == WM_LBUTTONDBLCLK) ShowMainWindow();
    if (LOWORD(lparam) == WM_RBUTTONUP || LOWORD(lparam) == WM_CONTEXTMENU) TrayMenu();
    return 0;
  }
  if (message == WM_CLOSE && desktop_ready_) {
    if (tray_installed_ && !quit_pending_) ShowWindow(hwnd, SW_HIDE);
    else if (!quit_pending_) RequestQuit();
    return 0;
  }
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

void FlutterWindow::InstallTray() {
  if (tray_installed_) return;
  tray_ = {};
  tray_.cbSize = sizeof(tray_); tray_.hWnd = GetHandle(); tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = kTrayCallback;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"串串 · 后台连接与会话");
  tray_installed_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
}
void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}
void FlutterWindow::TrayMenu() {
  const auto menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kOpen, L"打开主窗口");
  AppendMenuW(menu, MF_STRING | (allow_connections_ ? MF_CHECKED : MF_UNCHECKED) |
      (connection_supported_ && !quit_pending_ ? MF_ENABLED : MF_GRAYED), kAllow,
      connection_supported_ ? L"允许连接" : L"允许连接（当前平台不可用）");
  AppendMenuW(menu, MF_STRING, kStopControl, L"停止控制（当前无远控会话）");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (quit_pending_ ? MF_GRAYED : MF_ENABLED), kQuit, L"退出串串");
  POINT point{}; GetCursorPos(&point); SetForegroundWindow(GetHandle());
  const auto selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu); PostMessage(GetHandle(), WM_NULL, 0, 0);
  if (selected == kOpen) ShowMainWindow();
  if (selected == kQuit) RequestQuit();
  if (desktop_ready_ && !quit_pending_) {
    if (selected == kAllow) desktop_->InvokeMethod("toggleAllow", nullptr);
    if (selected == kStopControl) desktop_->InvokeMethod("stopControl", nullptr);
  }
}
void FlutterWindow::RequestQuit() {
  if (quit_pending_ || !desktop_) return;
  quit_pending_ = true;
  const std::weak_ptr<int> alive = alive_;
  const auto window = GetHandle();
  desktop_->InvokeMethod("requestExit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<Value>>(
        [this, alive, window](const Value* result) {
          if (alive.expired()) return;
          quit_pending_ = false;
          if (result && std::get_if<bool>(result) && std::get<bool>(*result)) {
            PostMessage(window, kExitApproved, 0, 0);
          } else { ShowMainWindow(); }
        },
        [this, alive](const std::string&, const std::string&, const Value*) {
          if (!alive.expired()) { quit_pending_ = false; ShowMainWindow(); }
        },
        [this, alive]() {
          if (!alive.expired()) { quit_pending_ = false; ShowMainWindow(); }
        }));
}
