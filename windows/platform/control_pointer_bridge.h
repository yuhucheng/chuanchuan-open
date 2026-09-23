#ifndef SHARE_HUB_CONTROL_POINTER_BRIDGE_H_
#define SHARE_HUB_CONTROL_POINTER_BRIDGE_H_

#include "control_pointer_input.h"
#include "control_text_input.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

#include <cstdint>
#include <memory>
#include <set>

namespace share_hub {

// Process-local channel for the SDK's one authenticated target input owner.
// The channel does not itself grant remote authority. Each new binding gets a
// distinct lease so queued calls from a retired operation cannot hit its heir.
class ControlPointerBridge {
 public:
  explicit ControlPointerBridge(
      ControlPointerInput::Sender sender = &SendInput)
      : sender_(sender), text_(sender) {}
  bool Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void Close();

 private:
  int64_t next_lease_ = 1;
  int64_t lease_ = 0;
  ControlPointerInput::Sender sender_;
  ControlTextInput text_;
  std::unique_ptr<ControlPointerInput> input_;
  std::set<ControlPointerButton> pressed_;
  std::set<uint16_t> pressed_keys_;
};

}  // namespace share_hub

#endif
