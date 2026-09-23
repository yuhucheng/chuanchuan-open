#ifndef SHARE_HUB_SOURCE_BRIDGE_H_
#define SHARE_HUB_SOURCE_BRIDGE_H_
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <functional>
#include <map>
#include <memory>

#include "selected_file_store.h"
namespace share_hub {
class SourceBridge {
 public:
  static constexpr UINT kMessage = WM_APP + 0x236;
  static constexpr size_t kMaximumPending = 64;
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  explicit SourceBridge(HWND window, SelectedFileStoreOptions options = {});
  ~SourceBridge();
  bool Handle(const flutter::MethodCall<Value>& call,
              std::unique_ptr<Result>& result);
  void AcceptPickedFiles(std::vector<std::wstring> paths,
                         std::unique_ptr<Result> result);
  void Pump();
  void Close();
  void WaitForWorkers();

 private:
  struct Shared;
  std::shared_ptr<Shared> shared_;
  std::map<uint64_t, std::unique_ptr<Result>> pending_;
  uint64_t next_ = 0;
  bool closed_ = false;
  using Check = std::function<void(SelectedFileStore&, const Value&)>;
  void Queue(std::function<Value(SelectedFileStore&)> work,
             std::unique_ptr<Result> result, bool guarded,
             std::vector<std::string> keys = {}, Check check = {});
  void RequestCleanup();
};
}  // namespace share_hub
#endif
