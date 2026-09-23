#ifndef SHARE_HUB_CONTROL_CLIPBOARD_BRIDGE_H_
#define SHARE_HUB_CONTROL_CLIPBOARD_BRIDGE_H_

#include "control_clipboard_store.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

#include <memory>
#include <utility>

namespace share_hub {

class ControlClipboardBridge {
 public:
  explicit ControlClipboardBridge(HWND owner,
      ControlClipboardStoreOptions options = {})
      : store_(owner, std::move(options)) {}
  bool Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
      const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void Close() { store_.Shutdown(); }

 private:
  ControlClipboardStore store_;
};

}  // namespace share_hub
#endif
