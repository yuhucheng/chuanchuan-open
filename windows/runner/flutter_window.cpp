#include "flutter_window.h"

#include <optional>
#include <cstring>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "exit_trace.h"
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
const std::string* StringField(const Value* value, const char* key) {
  const auto* map = value ? std::get_if<Map>(value) : nullptr;
  if (!map) return nullptr;
  const auto found = map->find(Value(key));
  return found != map->end() ? std::get_if<std::string>(&found->second) : nullptr;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
          static_cast<int>(text.size()), result.data(), size) <= 0) return {};
  return result;
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

  // Win32Window::Create() calls Destroy() (and thus OnDestroy) before the
  // window exists, which resets the lifetime token; mint it again so the
  // window actually owns a valid token until teardown.
  alive_ = std::make_shared<int>(0);

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
  platform_bridge_->ConfigureFileDrop(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  desktop_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.sharehub.client/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  control_display_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(),
      "dev.sharehub.client/control-display",
      &flutter::StandardMethodCodec::GetInstance());
  control_clipboard_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(),
      "dev.sharehub.client/control-clipboard",
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
      DWORD notice = 1; size = sizeof(notice);
      RegGetValueW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", L"ControlNoticeEnabled",
          RRF_RT_REG_DWORD, nullptr, &notice, &size);
      control_notice_enabled_ = notice != 0;
      result->Success(Value(Map{{Value("allowConnections"), Value(allowed == 1)},
                                 {Value("controlNoticeEnabled"), Value(control_notice_enabled_)}}));
    } else if (call.method_name() == "state") {
      allow_connections_ = BooleanField(call.arguments(), "allowConnections");
      control_active_ = BooleanField(call.arguments(), "controlActive");
      control_notice_enabled_ = BooleanField(call.arguments(), "controlNoticeEnabled");
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", 0, nullptr, 0,
          KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save admission preference"); return;
      }
      const DWORD allowed = allow_connections_ ? 1 : 0;
      const auto saved = RegSetValueExW(key, L"AllowConnections", 0, REG_DWORD,
          reinterpret_cast<const BYTE*>(&allowed), sizeof(allowed));
      const DWORD notice = control_notice_enabled_ ? 1 : 0;
      const auto saved_notice = RegSetValueExW(key, L"ControlNoticeEnabled", 0, REG_DWORD,
          reinterpret_cast<const BYTE*>(&notice), sizeof(notice));
      RegCloseKey(key);
      if (saved != ERROR_SUCCESS || saved_notice != ERROR_SUCCESS) { result->Error("preferences_failed", "Cannot save desktop preferences"); return; }
      wcscpy_s(tray_.szTip, control_active_ && control_notice_enabled_
          ? L"串串 · 正在被远程控制" : L"串串 · 后台连接与会话");
      if (tray_installed_) Shell_NotifyIconW(NIM_MODIFY, &tray_);
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
    } else if (call.method_name() == "controlClipboard.read") {
      DWORD enabled = 1, size = sizeof(enabled);
      const auto status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client",
          L"ControlClipboardSyncEnabled", RRF_RT_REG_DWORD, nullptr, &enabled, &size);
      if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) {
        result->Error("preferences_failed", "Cannot read clipboard preference"); return;
      }
      result->Success(Value(enabled != 0));
    } else if (call.method_name() == "controlClipboard.write") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("invalid_preference", "Expected boolean"); return; }
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", 0, nullptr, 0,
          KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save clipboard preference"); return;
      }
      const DWORD value = *enabled ? 1 : 0;
      const auto saved = RegSetValueExW(key, L"ControlClipboardSyncEnabled", 0,
          REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
      RegCloseKey(key);
      if (saved != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save clipboard preference"); return;
      }
      result->Success();
    } else if (call.method_name() == "auxiliary.read") {
      wchar_t stored[4096]{};
      DWORD bytes = sizeof(stored);
      const auto read = RegGetValueW(HKEY_CURRENT_USER,
          L"Software\\ShareHub\\Client", L"AuxiliaryRoute", RRF_RT_REG_SZ,
          nullptr, stored, &bytes);
      if (read == ERROR_FILE_NOT_FOUND) {
        result->Success(Value(Map{{Value("mode"), Value("official")},
                                   {Value("origin"), Value("")}}));
        return;
      }
      if (read != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot read auxiliary route"); return;
      }
      const std::wstring value(stored);
      const auto separator = value.find(L'\n');
      if (separator == std::wstring::npos) {
        result->Error("preferences_failed", "Invalid auxiliary route"); return;
      }
      result->Success(Value(Map{{Value("mode"), Value(Utf8(value.substr(0, separator)))},
                                 {Value("origin"), Value(Utf8(value.substr(separator + 1)))}}));
    } else if (call.method_name() == "auxiliary.write") {
      const auto* mode = StringField(call.arguments(), "mode");
      const auto* origin = StringField(call.arguments(), "origin");
      if (!mode || (*mode != "official" && *mode != "custom") ||
          !origin || origin->size() > 2048 || origin->find('\n') != std::string::npos ||
          origin->find('\0') != std::string::npos) {
        result->Error("invalid_route", "Invalid auxiliary route"); return;
      }
      const auto value = Wide(*mode + "\n" + *origin);
      if (value.empty()) {
        result->Error("invalid_route", "Invalid auxiliary route encoding"); return;
      }
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ShareHub\\Client", 0,
              nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save auxiliary route"); return;
      }
      const auto saved = RegSetValueExW(key, L"AuxiliaryRoute", 0, REG_SZ,
          reinterpret_cast<const BYTE*>(value.c_str()),
          static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
      RegCloseKey(key);
      if (saved != ERROR_SUCCESS) {
        result->Error("preferences_failed", "Cannot save auxiliary route"); return;
      }
      result->Success();
    } else if (call.method_name() == "exit") {
      result->Success(); RequestQuit();
    } else if (call.method_name() == "prepareExit") {
      platform_bridge_->CancelFilePicker(); result->Success();
    } else if (call.method_name() == "window.state") {
      result->Success(WindowState());
    } else if (call.method_name() == "window.action") {
      // Acceptance-only window control, mirroring macOS: the product UI never
      // calls this, but the background matrix (minimize / hide /
      // close-to-tray / reopen) cannot be driven by real clicks from the host.
      const auto* action = StringField(call.arguments(), "action");
      if (!action) { result->Error("invalid_action", "Missing window action"); return; }
      const auto window = GetHandle();
      if (*action == "minimize") ShowWindow(window, SW_MINIMIZE);
      else if (*action == "deminiaturize") ShowWindow(window, SW_RESTORE);
      else if (*action == "hide") ShowWindow(window, SW_HIDE);
      else if (*action == "unhide") ShowWindow(window, SW_SHOW);
      else if (*action == "close") CloseToBackground();
      else if (*action == "reopen") ShowMainWindow();
      // Drives the real quit path (tray "退出" -> requestExit -> cleanup ->
      // DestroyWindow), so a stuck quit can be exercised and logged without
      // needing a real click.
      else if (*action == "quit") RequestQuit();
      else { result->Error("invalid_action", "Unsupported window action"); return; }
      result->Success(WindowState());
    } else if (call.method_name() == "system.indicators") {
      // No Windows counterpart to the macOS screen-recording indicator. An empty
      // list is an unsupported observation, never "the system shows no indicator".
      result->Success(Value(flutter::EncodableList{}));
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
  TraceAppExit("OnDestroy enter");
  alive_.reset();
  if (tray_installed_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_installed_ = false;
  desktop_.reset();
  control_display_.reset();
  control_clipboard_.reset();
  TraceAppExit("OnDestroy: bridge+controller teardown begin");
  platform_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  TraceAppExit("OnDestroy: teardown done");

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
  if (message == kExitApproved) {
    exit_approved_ = true;
    TraceAppExit("kExitApproved received, calling DestroyWindow");
    DestroyWindow(hwnd);
    TraceAppExit("DestroyWindow returned");
    return 0;
  }
  if (message == kTrayCallback) {
    if (LOWORD(lparam) == WM_LBUTTONDBLCLK) ShowMainWindow();
    if (LOWORD(lparam) == WM_RBUTTONUP || LOWORD(lparam) == WM_CONTEXTMENU) TrayMenu();
    return 0;
  }
  if (message == WM_CLOSE) {
    if (desktop_ready_) { CloseToBackground(); return 0; }
  }
  if ((message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) &&
      control_display_) {
    control_display_->InvokeMethod("changed", nullptr);
  }
  if (message == WM_CLIPBOARDUPDATE && control_clipboard_) {
    control_clipboard_->InvokeMethod("changed", nullptr);
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
std::vector<TrayItem> FlutterWindow::TrayItems() const {
  return {
    {L"打开主窗口", true, false, kOpen, false},
    {connection_supported_ ? L"允许连接" : L"允许连接（当前平台不可用）",
     connection_supported_ && !quit_pending_, allow_connections_, kAllow, false},
    {control_active_ ? L"停止控制" : L"停止控制（当前无远控会话）",
     control_active_ && !quit_pending_, false, kStopControl, false},
    {L"退出串串", !quit_pending_, false, kQuit, true},
  };
}

flutter::EncodableValue FlutterWindow::WindowState() {
  const auto window = GetHandle();
  const bool iconic = IsIconic(window) != FALSE;
  const bool visible = IsWindowVisible(window) != FALSE;
  std::vector<Value> items;
  for (const auto& item : TrayItems()) {
    items.push_back(Value(Map{
        {Value("title"), Value(Utf8(item.title))},
        {Value("enabled"), Value(item.enabled)},
        {Value("checked"), Value(item.checked)},
    }));
  }
  return Value(Map{
      {Value("visible"), Value(visible)},
      {Value("miniaturized"), Value(iconic)},
      {Value("key"), Value(GetForegroundWindow() == window)},
      {Value("onscreen"), Value(visible && !iconic)},
      {Value("trayInstalled"), Value(tray_installed_)},
      {Value("trayButtonAvailable"), Value(tray_installed_)},
      {Value("trayItems"), Value(items)},
      {Value("desktopReady"), Value(desktop_ready_)},
      {Value("terminationApproved"), Value(exit_approved_)},
      {Value("quitPending"), Value(quit_pending_)},
  });
}

void FlutterWindow::CloseToBackground() {
  const auto window = GetHandle();
  if (tray_installed_ && !quit_pending_) ShowWindow(window, SW_HIDE);
  else if (!quit_pending_) RequestQuit();
}

void FlutterWindow::TrayMenu() {
  const auto menu = CreatePopupMenu();
  if (!menu) return;
  for (const auto& item : TrayItems()) {
    if (item.separator_before) AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu,
        MF_STRING | (item.enabled ? MF_ENABLED : MF_GRAYED) |
            (item.checked ? MF_CHECKED : MF_UNCHECKED),
        static_cast<UINT_PTR>(item.command), item.title.c_str());
  }
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
  TraceAppExit("RequestQuit enter");
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
            TraceAppExit("requestExit result=true, posting kExitApproved");
            PostMessage(window, kExitApproved, 0, 0);
          } else { TraceAppExit("requestExit result=false, showing main window"); ShowMainWindow(); }
        },
        [this, alive](const std::string&, const std::string&, const Value*) {
          if (!alive.expired()) { quit_pending_ = false; ShowMainWindow(); }
        },
        [this, alive]() {
          if (!alive.expired()) { quit_pending_ = false; ShowMainWindow(); }
        }));
}
