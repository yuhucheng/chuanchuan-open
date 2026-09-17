#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <shellapi.h>

#include "win32_window.h"

namespace share_hub { class PlatformBridge; }

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
  void ShowMainWindow();
  void RequestQuit();
  void TrayMenu();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_;
  NOTIFYICONDATAW tray_{};
  bool desktop_ready_ = false, tray_installed_ = false, quit_pending_ = false;
  bool allow_connections_ = false, connection_supported_ = false;
  UINT taskbar_created_ = 0;
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<share_hub::PlatformBridge> platform_bridge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
