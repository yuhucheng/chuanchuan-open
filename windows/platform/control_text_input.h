#ifndef SHARE_HUB_CONTROL_TEXT_INPUT_H_
#define SHARE_HUB_CONTROL_TEXT_INPUT_H_

#include "control_pointer_input.h"

#include <string_view>
#include <optional>

namespace share_hub {

// Committed text only. Physical shortcuts use a separate HID key path.
class ControlTextInput {
 public:
  using Sender = ControlPointerInput::Sender;
  explicit ControlTextInput(Sender sender = &SendInput) : sender_(sender) {}
  ControlInjectionResult Submit(std::wstring_view text);
  ControlInjectionResult ReleasePending();
  bool has_pending_release() const { return pending_release_.has_value(); }

 private:
  Sender sender_;
  std::optional<wchar_t> pending_release_;
};

}  // namespace share_hub

#endif
