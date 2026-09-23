#include "control_clipboard_bridge.h"

#include <windows.h>

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
std::optional<std::wstring> WideText(const Value* value) {
  const auto* utf8 = value ? std::get_if<std::string>(value) : nullptr;
  if (!utf8 || utf8->size() > 32768) return std::nullopt;
  if (utf8->empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      utf8->data(), static_cast<int>(utf8->size()), nullptr, 0);
  if (length < 1) return std::nullopt;
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      utf8->data(), static_cast<int>(utf8->size()), result.data(), length) != length) {
    return std::nullopt;
  }
  return result;
}
std::optional<std::string> Utf8Text(const std::wstring& text) {
  if (text.empty()) return std::string();
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (length < 1 || length > 32768) return std::nullopt;
  std::string result(static_cast<size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), result.data(), length,
      nullptr, nullptr) != length) {
    return std::nullopt;
  }
  return result;
}
bool Fields(const Map& map, std::initializer_list<const char*> names) {
  if (map.size() != names.size()) return false;
  for (const char* name : names) if (!Field(map, name)) return false;
  return true;
}
}  // namespace

bool ControlClipboardBridge::Handle(const flutter::MethodCall<Value>& call,
    const std::unique_ptr<flutter::MethodResult<Value>>& result) {
  const auto& method = call.method_name();
  if (method != "control.clipboard.open" &&
      method != "control.clipboard.read" &&
      method != "control.clipboard.write" &&
      method != "control.clipboard.close") return false;
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args) { result->Error("invalid_arguments", "Argument map required."); return true; }
  const auto lease = Integer(Field(*args, "lease"));
  const auto epoch = Integer(Field(*args, "epoch"));
  const auto controller = Integer(Field(*args, "controllerRevision"));
  const auto target = Integer(Field(*args, "targetRevision"));
  try {
    if (method == "control.clipboard.open") {
      const auto deadline = Integer(Field(*args, "deadlineMicros"));
      if (!Fields(*args, {"deadlineMicros", "epoch", "controllerRevision",
                           "targetRevision"}) ||
          !deadline || *deadline < 1 || !epoch || !controller || !target) {
        result->Error("invalid_arguments", "Exact clipboard scope required.");
        return true;
      }
      result->Success(Value(store_.Open(static_cast<uint64_t>(*deadline),
          *epoch, *controller, *target)));
      return true;
    }
    if (method == "control.clipboard.close") {
      if (!Fields(*args, {"lease"}) || !lease) {
        result->Error("invalid_arguments", "Clipboard lease required."); return true;
      }
      store_.Close(*lease);
      result->Success(); return true;
    }
    if (!lease || !epoch || !controller || !target) {
      result->Error("invalid_arguments", "Exact clipboard scope required.");
      return true;
    }
    if (method == "control.clipboard.read") {
      if (!Fields(*args, {"lease", "epoch", "controllerRevision",
                           "targetRevision"})) {
        result->Error("invalid_arguments", "Unexpected clipboard fields.");
        return true;
      }
      const auto snapshot = store_.Read(*lease, *epoch, *controller, *target);
      std::optional<std::string> text;
      if (snapshot.text) text = Utf8Text(*snapshot.text);
      if (snapshot.text && !text) {
        result->Error("clipboard_unavailable", "Plain text unavailable.");
        return true;
      }
      result->Success(Value(Map{
          {Value("sequence"), Value(static_cast<int64_t>(snapshot.sequence))},
          {Value("text"), text ? Value(*text) : Value()},
      }));
      return true;
    }
    const auto expected = Integer(Field(*args, "expectedSequence"));
    const auto text = WideText(Field(*args, "text"));
    if (!Fields(*args, {"lease", "epoch", "controllerRevision",
                         "targetRevision", "expectedSequence", "text"}) ||
        !expected || *expected < 1 ||
        *expected > std::numeric_limits<uint32_t>::max() || !text) {
      result->Error("invalid_arguments", "Valid plain text and sequence required.");
      return true;
    }
    const auto written = store_.Write(*lease, *epoch, *controller, *target,
        static_cast<uint32_t>(*expected), *text);
    const char* status = written.status == ControlClipboardWriteStatus::written
        ? "written" : written.status == ControlClipboardWriteStatus::conflict
        ? "conflict" : written.status == ControlClipboardWriteStatus::rejected
        ? "rejected" : "unknown";
    result->Success(Value(Map{
        {Value("status"), Value(status)},
        {Value("sequence"), written.status == ControlClipboardWriteStatus::written
            ? Value(static_cast<int64_t>(written.sequence)) : Value()},
    }));
  } catch (const ControlClipboardException& error) {
    result->Error(error.code(), "Clipboard scope unavailable.");
  }
  return true;
}
}  // namespace share_hub
