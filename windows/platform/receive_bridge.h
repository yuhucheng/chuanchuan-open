#ifndef SHARE_HUB_RECEIVE_BRIDGE_H_
#define SHARE_HUB_RECEIVE_BRIDGE_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <functional>
#include <map>
#include <memory>
#include "receive_store.h"

namespace share_hub {
// Called on the platform thread. Disk work owns no Flutter result/messenger;
// only Pump delivers completions. Close gates storage without joining disk I/O.
class ReceiveBridge {
 public:
  static constexpr UINT kMessage = WM_APP + 0x235;
  static constexpr size_t kMaximumPending = 64;
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  explicit ReceiveBridge(HWND window, ReceiveStoreOptions options = {});
  ~ReceiveBridge();
  bool Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result>& result);
  void AcceptPickedDirectory(std::wstring path, std::unique_ptr<Result> result);
  void Pump();
  void Close();
  // For native harness teardown only; product close never waits on disk I/O.
  void WaitForWorkers();
 private:
  struct Shared;
  std::shared_ptr<Shared> shared_;
  std::map<uint64_t, std::unique_ptr<Result>> pending_;
  uint64_t next_ = 0;
  bool closed_ = false;
  void Queue(std::function<Value(ReceiveStore&)> work, std::unique_ptr<Result> result,
             std::vector<std::string> keys = {});
  void RequestCleanup();
};
}  // namespace share_hub
#endif
