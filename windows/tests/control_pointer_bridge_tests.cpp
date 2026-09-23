#include "control_pointer_bridge.h"
#include "control_display_geometry.h"

#include <flutter/method_result_functions.h>
#include <windows.h>

#include <deque>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
int checks = 0;
int failures = 0;
UINT accepted = 3;
std::vector<INPUT> sent;
std::deque<UINT> scripted;

void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) { std::cerr << "FAIL: " << label << '\n'; ++failures; }
}

UINT Capture(UINT count, INPUT* events, int size) {
  if (size != sizeof(INPUT)) return 0;
  sent.assign(events, events + count);
  if (!scripted.empty()) {
    const UINT next = scripted.front();
    scripted.pop_front();
    return next < count ? next : count;
  }
  return count < accepted ? count : accepted;
}

struct Answer {
  Value value;
  std::string error;
  bool done = false;
};

Answer Call(share_hub::ControlPointerBridge* bridge,
            const std::string& name, Map args) {
  Answer answer;
  auto result = std::make_unique<flutter::MethodResultFunctions<Value>>(
      [&answer](const Value* value) {
        answer.done = true;
        if (value) answer.value = *value;
      },
      [&answer](const std::string& code, const std::string&, const Value*) {
        answer.done = true; answer.error = code;
      },
      [&answer] { answer.done = true; answer.error = "not_implemented"; });
  std::unique_ptr<flutter::MethodResult<Value>> base = std::move(result);
  flutter::MethodCall<Value> call(name,
                                 std::make_unique<Value>(std::move(args)));
  Check(bridge->Handle(call, base), "recognized pointer method");
  Check(answer.done, "pointer result completed synchronously");
  return answer;
}

Map OpenArgs(const std::string& id) {
  return {{Value("sourceId"), Value(id)}};
}
Map LeaseArgs(int64_t lease) {
  return {{Value("lease"), Value(lease)}};
}
}  // namespace

int main() {
  Check(SetProcessDpiAwarenessContext(
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0,
        "test uses production DPI awareness");
  std::string source;
  for (DWORD index = 0; index < 256; ++index) {
    source = std::to_string(index);
    if (share_hub::ResolveControlScreenGeometry(source)) break;
    source.clear();
  }
  if (source.empty()) {
    std::cout << "No attached desktop display; binding tests skipped\n";
    return failures == 0 ? 0 : 1;
  }
  share_hub::ControlPointerBridge bridge(&Capture);
  Check(Call(&bridge, "control.pointer.open", OpenArgs("00")).error ==
            "source_unavailable", "noncanonical source refused");
  const auto opened = Call(&bridge, "control.pointer.open", OpenArgs(source));
  Check(opened.error.empty(), "local screen binding opened");
  const auto* value = std::get_if<Map>(&opened.value);
  if (!value) return 1;
  const int64_t lease = std::get<int64_t>(value->at(Value("lease")));
  Check(lease > 0 && std::get<std::string>(value->at(Value("sourceId"))) == source,
        "native lease and exact source returned");
  Check(std::get<bool>(Call(&bridge, "control.pointer.current",
                            LeaseArgs(lease)).value),
        "current native source verified before readiness");
  Check(Call(&bridge, "control.pointer.open", OpenArgs(source)).error ==
            "busy", "second simultaneous binding refused");

  auto move = LeaseArgs(lease);
  move[Value("kind")] = Value("move");
  move[Value("x")] = Value(0.5);
  move[Value("y")] = Value(0.5);
  sent.clear();
  Check(std::get<bool>(Call(&bridge, "control.pointer.execute", move).value),
        "valid move entered fake input stream");
  Check(sent.size() == 1, "one move event emitted");
  auto text = LeaseArgs(lease);
  text[Value("text")] = Value(u8"\ufeff中文\nA");
  accepted = UINT_MAX;
  const auto committed = Call(&bridge, "control.input.text", text);
  Check(committed.done && committed.error.empty() &&
            std::get_if<bool>(&committed.value) &&
            std::get<bool>(committed.value),
        "authenticated lease can submit committed Unicode text");
  Check(sent.size() == 10 && sent[0].ki.wScan == 0xfeff &&
            sent[2].ki.wScan == 0x4e2d && sent[6].ki.wScan == L'\n',
        "bridge converts UTF-8 without losing BOM, Chinese or LF");
  auto malformed_text = LeaseArgs(lease);
  malformed_text[Value("text")] = Value(std::string("\xc0\xaf", 2));
  sent.clear();
  Check(Call(&bridge, "control.input.text", malformed_text).error ==
            "invalid_arguments", "noncanonical UTF-8 rejected");
  malformed_text[Value("text")] = Value(std::string(8193, 'x'));
  Check(Call(&bridge, "control.input.text", malformed_text).error ==
            "invalid_arguments", "text over 8192 UTF-8 bytes rejected");
  Check(sent.empty(), "malformed text never reaches native sender");
  scripted = {1, 0};
  Check(Call(&bridge, "control.input.text", text).error ==
            "input_result_unknown", "partial Unicode result is unknown");
  Check(Call(&bridge, "control.pointer.close", LeaseArgs(lease)).error ==
            "input_releasing", "pending Unicode release blocks lease close");
  accepted = 0;
  const auto failed_text_release = Call(&bridge, "control.input.releaseText",
                                        LeaseArgs(lease));
  Check(failed_text_release.done && failed_text_release.error.empty() &&
            std::get_if<bool>(&failed_text_release.value) &&
            !std::get<bool>(failed_text_release.value),
        "failed Unicode cleanup is reported");
  accepted = 1;
  const auto retried_text_release = Call(&bridge, "control.input.releaseText",
                                         LeaseArgs(lease));
  Check(retried_text_release.done && retried_text_release.error.empty() &&
            std::get_if<bool>(&retried_text_release.value) &&
            std::get<bool>(retried_text_release.value),
        "pending Unicode key-up is retryable");
  accepted = 3;
  move[Value("x")] = Value(std::numeric_limits<double>::quiet_NaN());
  sent.clear();
  Check(Call(&bridge, "control.pointer.execute", move).error ==
            "invalid_arguments", "NaN rejected before native input");
  Check(sent.empty(), "NaN caused no input");

  auto key = LeaseArgs(lease);
  key[Value("usage")] = Value(4);
  key[Value("action")] = Value("down");
  Check(std::get<bool>(Call(&bridge, "control.input.key", key).value),
        "HID keyboard A down accepted");
  Check(sent.size() == 1 && sent[0].type == INPUT_KEYBOARD &&
            sent[0].ki.wScan == 0x1e && sent[0].ki.wVk == 0 &&
            sent[0].ki.dwFlags == KEYEVENTF_SCANCODE,
        "HID usage maps to physical scan code");
  sent.clear();
  Check(!std::get<bool>(Call(&bridge, "control.input.key", key).value),
        "duplicate held key down rejected");
  Check(sent.empty(), "duplicate down has no native effect");
  key[Value("action")] = Value("repeat");
  Check(std::get<bool>(Call(&bridge, "control.input.key", key).value),
        "repeat only accepted for held key");
  Check(Call(&bridge, "control.pointer.close", LeaseArgs(lease)).error ==
            "input_releasing", "held key blocks lease retirement");
  auto key_release = LeaseArgs(lease);
  key_release[Value("usage")] = Value(4);
  accepted = 0;
  Check(!std::get<bool>(Call(&bridge, "control.input.releaseKey",
                            key_release).value),
        "failed key release retains native held ledger");
  accepted = 3;
  Check(std::get<bool>(Call(&bridge, "control.input.releaseKey",
                            key_release).value),
        "held key release retries successfully");
  Check(sent.size() == 1 && sent[0].ki.wScan == 0x1e &&
            (sent[0].ki.dwFlags & KEYEVENTF_KEYUP) != 0,
        "key cleanup emits physical scan code up");
  key[Value("usage")] = Value(0xe4);
  key[Value("action")] = Value("down");
  Check(std::get<bool>(Call(&bridge, "control.input.key", key).value),
        "right control accepted");
  Check(sent[0].ki.wScan == 0x1d &&
            (sent[0].ki.dwFlags & KEYEVENTF_EXTENDEDKEY) != 0,
        "right control keeps E0 extended flag");
  key_release[Value("usage")] = Value(0xe4);
  Check(std::get<bool>(Call(&bridge, "control.input.releaseKey",
                            key_release).value),
        "right control released");
  sent.clear();
  key[Value("usage")] = Value(0x66);
  Check(Call(&bridge, "control.input.key", key).error == "invalid_arguments",
        "power HID usage rejected");
  key[Value("usage")] = Value(0x48);
  Check(!std::get<bool>(Call(&bridge, "control.input.key", key).value),
        "unsupported E1 Pause reports no native effect");
  Check(sent.empty(), "invalid or unsupported key never injected");

  auto button = LeaseArgs(lease);
  button[Value("kind")] = Value("button");
  button[Value("x")] = Value(0.5);
  button[Value("y")] = Value(0.5);
  button[Value("button")] = Value("primary");
  button[Value("down")] = Value(true);
  accepted = 1;
  Check(Call(&bridge, "control.pointer.execute", button).error ==
            "input_result_unknown", "partial native batch is unknown");
  accepted = 0;
  Check(std::get<bool>(Call(&bridge, "control.pointer.execute", button).value)
            == false, "zero accepted events return false");
  accepted = 3;

  Check(std::get<bool>(Call(&bridge, "control.pointer.execute", button).value),
        "button down accepted");
  Check(Call(&bridge, "control.pointer.close", LeaseArgs(lease)).error ==
            "input_releasing", "held button blocks lease retirement");
  auto held_release = LeaseArgs(lease);
  held_release[Value("button")] = Value("primary");
  accepted = 0;
  Check(!std::get<bool>(Call(&bridge, "control.pointer.releaseButton",
                            held_release).value),
        "failed native button release reported");
  Check(Call(&bridge, "control.pointer.close", LeaseArgs(lease)).error ==
            "input_releasing", "failed release retains native held ledger");
  accepted = 3;
  Check(std::get<bool>(
            Call(&bridge, "control.pointer.releaseButton", held_release).value),
        "held button explicitly released");

  Check(Call(&bridge, "control.pointer.close", LeaseArgs(lease)).error.empty(),
        "binding closed");
  const auto newer = Call(&bridge, "control.pointer.open", OpenArgs(source));
  const auto new_lease = std::get<int64_t>(
      std::get<Map>(newer.value).at(Value("lease")));
  Check(new_lease != lease, "new owner has a distinct lease");
  Check(Call(&bridge, "control.pointer.execute", move).error ==
            "stale_operation", "old queued event rejected");
  Check(Call(&bridge, "control.input.text", text).error ==
            "stale_operation", "old text cannot reach new owner");
  key[Value("usage")] = Value(4);
  Check(Call(&bridge, "control.input.key", key).error ==
            "stale_operation", "old key cannot reach new owner");
  key_release[Value("usage")] = Value(4);
  Check(Call(&bridge, "control.input.releaseKey", key_release).error ==
            "stale_operation", "old key cleanup cannot affect new owner");
  Check(Call(&bridge, "control.pointer.current", LeaseArgs(lease)).error ==
            "stale_operation", "old readiness check rejected");
  auto release = LeaseArgs(lease);
  release[Value("button")] = Value("primary");
  Check(Call(&bridge, "control.pointer.releaseButton", release).error ==
            "stale_operation", "old cleanup cannot affect new owner");
  release[Value("lease")] = Value(new_lease);
  Check(std::get<bool>(
            Call(&bridge, "control.pointer.releaseButton", release).value),
        "current owner can release button");
  bridge.Close();
  Check(Call(&bridge, "control.pointer.close", LeaseArgs(new_lease)).error ==
            "stale_operation", "host close retires lease");

  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
