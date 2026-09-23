#include "control_text_input.h"

#include <cstdint>
#include <limits>
#include <vector>

namespace share_hub {
namespace {

bool ValidText(std::wstring_view text) {
  if (text.empty() || text.size() > 8192) return false;
  for (size_t index = 0; index < text.size(); ++index) {
    const uint16_t unit = static_cast<uint16_t>(text[index]);
    if (unit == 0) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.size()) return false;
      const uint16_t following = static_cast<uint16_t>(text[index]);
      if (following < 0xdc00 || following > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

INPUT UnicodeEvent(wchar_t unit, bool up) {
  INPUT event{};
  event.type = INPUT_KEYBOARD;
  event.ki.wScan = static_cast<WORD>(unit);
  event.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
  return event;
}

}  // namespace

ControlInjectionResult ControlTextInput::Submit(std::wstring_view text) {
  if (pending_release_) return ControlInjectionResult::unknown;
  if (!sender_ || !ValidText(text) ||
      text.size() > std::numeric_limits<UINT>::max() / 2) {
    return ControlInjectionResult::rejected;
  }
  std::vector<INPUT> events;
  events.reserve(text.size() * 2);
  for (const wchar_t unit : text) {
    events.push_back(UnicodeEvent(unit, false));
    events.push_back(UnicodeEvent(unit, true));
  }
  const UINT count = static_cast<UINT>(events.size());
  const UINT inserted = sender_(count, events.data(), sizeof(INPUT));
  if (inserted == count) return ControlInjectionResult::accepted;
  if (inserted == 0) return ControlInjectionResult::rejected;
  if (inserted < count && inserted % 2 == 1) {
    // The last accepted event pressed VK_PACKET without its matching release.
    // Attempt to release it, but the already committed prefix cannot be undone.
    pending_release_ = text[(inserted - 1) / 2];
    ReleasePending();
  }
  return ControlInjectionResult::unknown;
}

ControlInjectionResult ControlTextInput::ReleasePending() {
  if (!pending_release_) return ControlInjectionResult::accepted;
  if (!sender_) return ControlInjectionResult::rejected;
  INPUT release = UnicodeEvent(*pending_release_, true);
  const UINT inserted = sender_(1, &release, sizeof(INPUT));
  if (inserted == 1) {
    pending_release_.reset();
    return ControlInjectionResult::accepted;
  }
  return inserted == 0 ? ControlInjectionResult::rejected
                       : ControlInjectionResult::unknown;
}

}  // namespace share_hub
