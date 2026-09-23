#include "control_pointer_bridge.h"

#include "control_display_geometry.h"

#include <flutter/encodable_value.h>

#include <cmath>
#include <limits>
#include <optional>
#include <string>

namespace share_hub {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

const Value* Field(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : &found->second;
}

std::optional<int64_t> Integer(const Value* value) {
  if (!value) return std::nullopt;
  if (const auto* wide = std::get_if<int64_t>(value)) return *wide;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  return std::nullopt;
}

std::optional<double> Double(const Value* value) {
  if (!value) return std::nullopt;
  const auto* number = std::get_if<double>(value);
  if (!number || !std::isfinite(*number)) return std::nullopt;
  return *number;
}

std::optional<ControlPointerButton> Button(const Value* value) {
  if (!value) return std::nullopt;
  const auto* name = std::get_if<std::string>(value);
  if (!name) return std::nullopt;
  if (*name == "primary") return ControlPointerButton::primary;
  if (*name == "secondary") return ControlPointerButton::secondary;
  if (*name == "middle") return ControlPointerButton::middle;
  if (*name == "back") return ControlPointerButton::back;
  if (*name == "forward") return ControlPointerButton::forward;
  return std::nullopt;
}

std::optional<std::wstring> Utf16Text(const Value* value) {
  if (!value) return std::nullopt;
  const auto* utf8 = std::get_if<std::string>(value);
  if (!utf8 || utf8->empty() || utf8->size() > 8192) return std::nullopt;
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        utf8->data(),
                                        static_cast<int>(utf8->size()),
                                        nullptr, 0);
  if (length < 1) return std::nullopt;
  std::wstring converted(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(),
                          static_cast<int>(utf8->size()),
                          converted.data(), length) != length) {
    return std::nullopt;
  }
  return converted;
}

void Finish(ControlInjectionResult status,
            const std::unique_ptr<flutter::MethodResult<Value>>& result) {
  switch (status) {
    case ControlInjectionResult::accepted: result->Success(Value(true)); return;
    case ControlInjectionResult::rejected: result->Success(Value(false)); return;
    case ControlInjectionResult::unknown:
      result->Error("input_result_unknown", "Native input result is partial.");
      return;
  }
}

}  // namespace

bool ControlPointerBridge::Handle(
    const flutter::MethodCall<Value>& call,
    const std::unique_ptr<flutter::MethodResult<Value>>& result) {
  const std::string& method = call.method_name();
  if (method != "control.pointer.open" &&
      method != "control.pointer.execute" &&
      method != "control.pointer.current" &&
      method != "control.pointer.releaseButton" &&
      method != "control.input.key" &&
      method != "control.input.releaseKey" &&
      method != "control.input.text" &&
      method != "control.input.releaseText" &&
      method != "control.pointer.close") {
    return false;
  }
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args) { result->Error("invalid_arguments", "Argument map required."); return true; }
  if (method == "control.pointer.open") {
    const auto* id_value = Field(*args, "sourceId");
    const auto* id = id_value ? std::get_if<std::string>(id_value) : nullptr;
    if (args->size() != 1 || !id) {
      result->Error("invalid_arguments", "Local screen source required.");
      return true;
    }
    if (input_) { result->Error("busy", "Control input already bound."); return true; }
    const auto geometry = ResolveControlScreenGeometry(*id);
    if (!geometry) {
      result->Error("source_unavailable", "Screen source is no longer current.");
      return true;
    }
    if (next_lease_ == std::numeric_limits<int64_t>::max()) {
      result->Error("resource_limit", "Input lease exhausted."); return true;
    }
    lease_ = next_lease_++;
    input_ = std::make_unique<ControlPointerInput>(*geometry, sender_);
    result->Success(Value(Map{
        {Value("lease"), Value(lease_)},
        {Value("sourceId"), Value(*id)},
        {Value("left"), Value(static_cast<int64_t>(geometry->left))},
        {Value("top"), Value(static_cast<int64_t>(geometry->top))},
        {Value("width"), Value(static_cast<int64_t>(geometry->width))},
        {Value("height"), Value(static_cast<int64_t>(geometry->height))},
        {Value("rotation"), Value(static_cast<int64_t>(geometry->rotation))}}));
    return true;
  }

  const auto lease = Integer(Field(*args, "lease"));
  if (!lease || *lease < 1) {
    result->Error("invalid_arguments", "Input lease required."); return true;
  }
  if (!input_ || *lease != lease_) {
    result->Error("stale_operation", "Control input lease retired.");
    return true;
  }
  if (method == "control.pointer.close") {
    if (args->size() != 1) {
      result->Error("invalid_arguments", "Unexpected close fields."); return true;
    }
    if (!pressed_.empty() || !pressed_keys_.empty() ||
        text_.has_pending_release()) {
      result->Error("input_releasing", "Held input must be released first.");
      return true;
    }
    input_.reset();
    lease_ = 0;
    result->Success();
    return true;
  }
  if (method == "control.pointer.current") {
    if (args->size() != 1) {
      result->Error("invalid_arguments", "Unexpected current fields.");
      return true;
    }
    result->Success(Value(input_->Current()));
    return true;
  }
  if (method == "control.input.releaseText") {
    if (args->size() != 1) {
      result->Error("invalid_arguments", "Unexpected text release fields.");
      return true;
    }
    Finish(text_.ReleasePending(), result);
    return true;
  }
  if (method == "control.pointer.releaseButton") {
    const auto button = Button(Field(*args, "button"));
    if (args->size() != 2 || !button) {
      result->Error("invalid_arguments", "Button required."); return true;
    }
    const auto status = input_->ReleaseButton(*button);
    if (status == ControlInjectionResult::accepted) pressed_.erase(*button);
    Finish(status, result);
    return true;
  }
  if (method == "control.input.releaseKey") {
    const auto usage = Integer(Field(*args, "usage"));
    if (args->size() != 2 || !usage || *usage < 0 || *usage > 0xffff) {
      result->Error("invalid_arguments", "HID usage required."); return true;
    }
    if (!pressed_keys_.count(static_cast<uint16_t>(*usage))) {
      result->Success(Value(true)); return true;
    }
    const auto status = input_->ReleaseKey(static_cast<uint16_t>(*usage));
    if (status == ControlInjectionResult::accepted) {
      pressed_keys_.erase(static_cast<uint16_t>(*usage));
    }
    Finish(status, result);
    return true;
  }
  if (method == "control.input.key") {
    const auto usage = Integer(Field(*args, "usage"));
    const auto* action_value = Field(*args, "action");
    const auto* action = action_value
        ? std::get_if<std::string>(action_value) : nullptr;
    if (args->size() != 3 || !usage || *usage < 0 || *usage > 0xffff ||
        !action || (*action != "down" && *action != "up" &&
                    *action != "repeat") ||
        !((*usage >= 0x04 && *usage <= 0x65) ||
          (*usage >= 0x67 && *usage <= 0x73) ||
          (*usage >= 0xe0 && *usage <= 0xe7))) {
      result->Error("invalid_arguments", "Valid keyboard usage required.");
      return true;
    }
    const auto key = static_cast<uint16_t>(*usage);
    const bool held = pressed_keys_.count(key) != 0;
    if ((*action == "down" && held) ||
        (*action != "down" && !held) ||
        (*action == "down" && pressed_keys_.size() >= 32)) {
      result->Success(Value(false)); return true;
    }
    const auto status = input_->Key(key, *action != "up");
    if (status == ControlInjectionResult::accepted) {
      if (*action == "down") pressed_keys_.insert(key);
      if (*action == "up") pressed_keys_.erase(key);
    }
    Finish(status, result);
    return true;
  }
  if (method == "control.input.text") {
    const auto value = Utf16Text(Field(*args, "text"));
    if (args->size() != 2 || !value) {
      result->Error("invalid_arguments", "Valid UTF-8 text required.");
      return true;
    }
    if (!input_->Current()) {
      result->Success(Value(false));
      return true;
    }
    Finish(text_.Submit(*value), result);
    return true;
  }
  const auto* kind_value = Field(*args, "kind");
  const auto* kind = kind_value ? std::get_if<std::string>(kind_value) : nullptr;
  const auto x = Double(Field(*args, "x"));
  const auto y = Double(Field(*args, "y"));
  if (!kind || !x || !y || *x < 0 || *x > 1 || *y < 0 || *y > 1) {
    result->Error("invalid_arguments", "Finite pointer coordinates required.");
    return true;
  }
  if (*kind == "move" && args->size() == 4) {
    Finish(input_->Move(*x, *y), result);
    return true;
  }
  if (*kind == "button" && args->size() == 6) {
    const auto button = Button(Field(*args, "button"));
    const auto* down_value = Field(*args, "down");
    const auto* down = down_value ? std::get_if<bool>(down_value) : nullptr;
    if (button && down) {
      const auto status = input_->Button(*x, *y, *button, *down);
      if (status == ControlInjectionResult::accepted) {
        if (*down) pressed_.insert(*button);
        else pressed_.erase(*button);
      }
      Finish(status, result);
      return true;
    }
  }
  if (*kind == "wheel" && args->size() == 6) {
    const auto delta_x = Double(Field(*args, "deltaX"));
    const auto delta_y = Double(Field(*args, "deltaY"));
    if (delta_x && delta_y && std::abs(*delta_x) <= 120 &&
        std::abs(*delta_y) <= 120 && (*delta_x != 0 || *delta_y != 0)) {
      Finish(input_->Wheel(*x, *y, *delta_x, *delta_y), result);
      return true;
    }
  }
  result->Error("invalid_arguments", "Invalid pointer event.");
  return true;
}

void ControlPointerBridge::Close() {
  text_.ReleasePending();
  if (input_) {
    for (const auto button : pressed_) input_->ReleaseButton(button);
    for (const auto usage : pressed_keys_) input_->ReleaseKey(usage);
  }
  pressed_.clear();
  pressed_keys_.clear();
  input_.reset();
  lease_ = 0;
}

}  // namespace share_hub
