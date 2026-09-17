#ifndef SHARE_HUB_PLATFORM_BRIDGE_H_
#define SHARE_HUB_PLATFORM_BRIDGE_H_
#include <winsock2.h>
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <memory>
#include <string>

namespace share_hub {
class PlatformBridge {
 public:
  PlatformBridge(flutter::BinaryMessenger* messenger, HWND window,
                 std::wstring registry_key = L"Software\\ShareHub\\Client");
  ~PlatformBridge();
  bool HandleMessage(UINT message, WPARAM wparam);
  void Close();
  void CancelFilePicker();
 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};
}
#endif
