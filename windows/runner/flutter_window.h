#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <string>
#include <vector>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <shellapi.h>

#include "win32_window.h"
#include "tray_icon_policy.h"

namespace share_hub { class PlatformBridge; }

// One tray entry. The menu and the "window.state" observation are built from the
// same list, so a recorded acceptance state can never disagree with the menu the
// user gets. "separator_before" mirrors a menu separator, which has no item.
struct TrayItem {
  std::wstring title;
  bool enabled;
  bool checked;
  int command;
  bool separator_before;
};

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void InstallTray();
  void RemoveTray();
  void RefreshTrayIcon();
  bool UpdateTrayIcon(bool installing);
  void ShowMainWindow();
  void RequestQuit();
  void TrayMenu();
  void CloseToBackground();
  // The tray menu is built from this list, so the menu and the observed state
  // cannot drift apart.
  std::vector<TrayItem> TrayItems() const;
  flutter::EncodableValue WindowState();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_;
  NOTIFYICONDATAW tray_{};
  // LoadImage without LR_SHARED gives this window ownership of the handle.
  HICON tray_icon_ = nullptr;
  int tray_icon_resource_ = 0, tray_icon_width_ = 0, tray_icon_height_ = 0;
  share_hub::TrayIconUpdateGate tray_updates_;
  bool tray_requested_ = false;
  bool desktop_ready_ = false, tray_installed_ = false, quit_pending_ = false;
  bool allow_connections_ = false, connection_supported_ = false;
  bool exit_approved_ = false;
  UINT taskbar_created_ = 0;
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<share_hub::PlatformBridge> platform_bridge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
