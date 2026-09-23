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
constexpr UINT kRefreshTrayIcon = WM_APP + 74;
constexpr UINT kOpen = 2101, kAllow = 2102, kStopControl = 2103, kQuit = 2104;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

int TrayIconResource() {
  HIGHCONTRASTW contrast{};
  contrast.cbSize = sizeof(contrast);
  const bool high_contrast =
      SystemParametersInfoW(SPI_GETHIGHCONTRAST, contrast.cbSize, &contrast, 0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
  // lpszDefaultScheme is borrowed; Windows owns this pointer.
  DWORD light = 0, bytes = sizeof(light);
  std::optional<bool> system_light;
  if (RegGetValueW(HKEY_CURRENT_USER,
                  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                  L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light,
                  &bytes) == ERROR_SUCCESS && light <= 1) {
    system_light = light == 1;
  }
  const auto color = GetSysColor(COLOR_WINDOW);
  const auto rgb = (static_cast<std::uint32_t>(GetRValue(color)) << 16) |
                   (static_cast<std::uint32_t>(GetGValue(color)) << 8) |
                   GetBValue(color);
  return share_hub::ChooseTrayIconVariant(high_contrast, system_light, rgb) ==
                 share_hub::TrayIconVariant::ink
             ? IDI_TRAY_INK
             : IDI_TRAY_WHITE;
}

UINT TrayDpi(HWND window, bool installed) {
  RECT bounds{};
  if (installed) {
    NOTIFYICONIDENTIFIER identifier{};
    identifier.cbSize = sizeof(identifier);
    identifier.hWnd = window;
    identifier.uID = 1;
    if (SUCCEEDED(Shell_NotifyIconGetRect(&identifier, &bounds))) {
      return FlutterDesktopGetDpiForMonitor(
          MonitorFromRect(&bounds, MONITOR_DEFAULTTOPRIMARY));
    }
  }
  // The notification area can be on a different screen from the app window.
  APPBARDATA taskbar{};
  taskbar.cbSize = sizeof(taskbar);
  const auto monitor = SHAppBarMessage(ABM_GETTASKBARPOS, &taskbar)
                           ? MonitorFromRect(&taskbar.rc, MONITOR_DEFAULTTOPRIMARY)
                           : MonitorFromPoint(POINT{}, MONITOR_DEFAULTTOPRIMARY);
  return FlutterDesktopGetDpiForMonitor(monitor);
}

int TrayMetric(int metric, UINT dpi) {
  using MetricsForDpi = int(WINAPI*)(int, UINT);
  static const auto metrics_for_dpi = []() {
    MetricsForDpi function = nullptr;
    const auto address =
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetSystemMetricsForDpi");
    static_assert(sizeof(function) == sizeof(address));
    std::memcpy(&function, &address, sizeof(function));
    return function;
  }();
  return share_hub::TrayIconPixels(metrics_for_dpi ? metrics_for_dpi(metric, dpi) : 0,
                                   dpi);
}

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
}

#include "flutter/generated_plugin_registrant.h"
#include "../platform/platform_bridge.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { RemoveTray(); }

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
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  desktop_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.sharehub.client/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (call.method_name() == "initialize") {
      connection_supported_ = BooleanField(call.arguments(), "connectionSupported");
      tray_requested_ = true;
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
  RemoveTray();
  desktop_.reset();
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
    tray_updates_.Invalidate();
    tray_installed_ = false;
    if (tray_requested_ && !exit_approved_) {
      InstallTray();
      if (!tray_installed_) ShowMainWindow();
    }
    return 0;
  }
  if (message == kRefreshTrayIcon) {
    if (tray_requested_ && !exit_approved_) {
      if (tray_installed_) RefreshTrayIcon();
      else InstallTray();
      if (!tray_installed_) ShowMainWindow();
    }
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
  if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE ||
      message == WM_SYSCOLORCHANGE || message == WM_DPICHANGED ||
      message == WM_DISPLAYCHANGE) {
    if (tray_installed_) RefreshTrayIcon();
    else if (tray_requested_ && !exit_approved_) InstallTray();
    // Flutter and Win32Window must still receive these messages, particularly
    // WM_DPICHANGED's suggested window bounds and theme notifications.
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
  if (tray_installed_ || !GetHandle() || exit_approved_) return;
  if (UpdateTrayIcon(true)) {
    // Once present, prefer the icon's own monitor over the taskbar fallback.
    RefreshTrayIcon();
  }
}

void FlutterWindow::RemoveTray() {
  const auto installed = tray_installed_;
  const auto icon = tray_icon_;
  auto previous = tray_;
  // Publish teardown before calling the shell: it may dispatch window messages.
  tray_updates_.Invalidate();
  tray_requested_ = false;
  tray_installed_ = false;
  desktop_ready_ = false;
  tray_icon_ = nullptr;
  tray_ = {};
  tray_icon_resource_ = tray_icon_width_ = tray_icon_height_ = 0;
  if (installed) Shell_NotifyIconW(NIM_DELETE, &previous);
  if (icon) DestroyIcon(icon);
}

void FlutterWindow::RefreshTrayIcon() {
  if (tray_installed_ && !exit_approved_) UpdateTrayIcon(false);
}

bool FlutterWindow::UpdateTrayIcon(bool installing) {
  const auto generation = tray_updates_.Begin();
  if (!generation) return false;
  const auto window = GetHandle();
  const std::weak_ptr<int> alive = alive_;
  const auto current = [&]() {
    return !alive.expired() && window == GetHandle() && !exit_approved_ &&
           tray_requested_ && tray_updates_.IsCurrent(*generation);
  };
  const bool updated = [&]() {
    const auto resource = TrayIconResource();
    const auto reported_dpi = TrayDpi(window, !installing);
    const auto dpi = reported_dpi == 0 ? 96u : reported_dpi;
    const auto width = TrayMetric(SM_CXSMICON, dpi);
    const auto height = TrayMetric(SM_CYSMICON, dpi);
    if (!current()) return false;
    if (!installing && resource == tray_icon_resource_ &&
        width == tray_icon_width_ && height == tray_icon_height_) return true;

    // Each replacement owns a distinct handle, including non-standard DPI sizes.
    const auto icon = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(resource), IMAGE_ICON, width,
        height, LR_DEFAULTCOLOR));
    if (!icon) return false;
    NOTIFYICONDATAW next{};
    next.cbSize = sizeof(next);
    next.hWnd = window;
    next.uID = 1;
    next.uFlags = NIF_ICON;
    next.hIcon = icon;
    if (installing) {
      next.uFlags |= NIF_MESSAGE | NIF_TIP;
      next.uCallbackMessage = kTrayCallback;
      wcscpy_s(next.szTip, L"串串 · 后台连接与会话");
    }
    if (!current()) {
      DestroyIcon(icon);
      return false;
    }
    const bool notified =
        Shell_NotifyIconW(installing ? NIM_ADD : NIM_MODIFY, &next) != FALSE;
    if (!current()) {
      // No nested update can install a replacement while the gate is held.
      // Remove a late shell result after taskbar recreation or owner teardown.
      if (notified) Shell_NotifyIconW(NIM_DELETE, &next);
      DestroyIcon(icon);
      return false;
    }
    if (!notified) {
      DestroyIcon(icon);
      return false;  // Preserve the previous entry and its icon on failure.
    }
    const auto previous = tray_icon_;
    tray_icon_ = icon;
    tray_icon_resource_ = resource;
    tray_icon_width_ = width;
    tray_icon_height_ = height;
    if (installing) tray_ = next;
    else tray_.hIcon = icon;
    tray_installed_ = true;
    if (previous) DestroyIcon(previous);
    return true;
  }();
  if (tray_updates_.End() && !alive.expired() && GetHandle() &&
      tray_requested_ && !exit_approved_) {
    PostMessageW(GetHandle(), kRefreshTrayIcon, 0, 0);
  }
  return updated;
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
    {L"停止控制（当前无远控会话）", !quit_pending_, false, kStopControl, false},
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
      {Value("trayIconVariant"), Value(!tray_installed_ ? "none" :
          tray_icon_resource_ == IDI_TRAY_INK ? "ink" : "white")},
      {Value("trayIconWidth"), Value(tray_installed_ ? tray_icon_width_ : 0)},
      {Value("trayIconHeight"), Value(tray_installed_ ? tray_icon_height_ : 0)},
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
