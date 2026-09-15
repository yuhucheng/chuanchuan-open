#ifndef SHARE_HUB_NATIVE_DISCOVERY_H_
#define SHARE_HUB_NATIVE_DISCOVERY_H_
#include <winsock2.h>
#include <windows.h>
#include <functional>
#include <memory>
#include "discovery_model.h"

namespace share_hub {
// Public methods and on_change run on the constructing/window thread.
// OS callbacks enqueue owned values; they never call Flutter or hold this.
class NativeDiscovery {
 public:
  static constexpr UINT kMessage = WM_APP + 0x234;
  explicit NativeDiscovery(HWND target = nullptr);
  ~NativeDiscovery();
  NativeDiscovery(const NativeDiscovery&) = delete;
  NativeDiscovery& operator=(const NativeDiscovery&) = delete;
  bool Start(const std::string& id, const std::string& name);
  void Stop();
  void Pump();
  void Tick();
  void Close();
  const DiscoverySnapshot& snapshot() const;
  bool cleanup_pending() const;
  std::function<void(const DiscoverySnapshot&)> on_change;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  void Emit();
};
}  // namespace share_hub
#endif
