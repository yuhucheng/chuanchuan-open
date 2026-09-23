#include "control_clipboard_bridge.h"

#include <flutter/method_result_functions.h>

#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using namespace share_hub;

void Check(bool value, const char* why) {
  if (!value) throw std::runtime_error(why);
}
struct Answer { Value value; std::string error; bool done = false; };
Answer Call(ControlClipboardBridge& bridge, const std::string& method, Map args) {
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
  flutter::MethodCall<Value> call(method, std::make_unique<Value>(std::move(args)));
  Check(bridge.Handle(call, base) && answer.done, "handled synchronously");
  return answer;
}
Map Scope(int64_t lease) {
  return {{Value("lease"), Value(lease)}, {Value("epoch"), Value(int64_t{1})},
          {Value("controllerRevision"), Value(int64_t{2})},
          {Value("targetRevision"), Value(int64_t{3})}};
}
}  // namespace

int main() {
  try {
    uint64_t now = 10;
    ControlClipboardSnapshot os{7, std::wstring(L"\ufeff中文\nA")};
    int writes = 0;
    ControlClipboardStoreOptions options;
    options.clock = [&](uint64_t* time) { *time = now; return true; };
    options.read = [&] { return os; };
    options.write = [&](uint32_t expected, std::wstring_view text,
                        const std::function<bool()>& current) {
      Check(current(), "native current callback");
      if (expected != os.sequence) {
        return ControlClipboardWriteResult{ControlClipboardWriteStatus::conflict};
      }
      writes++;
      os.text = std::wstring(text);
      os.sequence++;
      return ControlClipboardWriteResult{ControlClipboardWriteStatus::written,
                                         os.sequence};
    };
    ControlClipboardBridge bridge(nullptr, options);
    const auto opened = Call(bridge, "control.clipboard.open", {
        {Value("deadlineMicros"), Value(int64_t{100})},
        {Value("epoch"), Value(int64_t{1})},
        {Value("controllerRevision"), Value(int64_t{2})},
        {Value("targetRevision"), Value(int64_t{3})}});
    Check(opened.error.empty(), "opened exact native scope");
    const auto lease = std::get<int64_t>(opened.value);
    const auto snapshot = Call(bridge, "control.clipboard.read", Scope(lease));
    Check(snapshot.error.empty(), "read exact scope");
    const auto& fields = std::get<Map>(snapshot.value);
    Check(std::get<int64_t>(fields.at(Value("sequence"))) == 7,
          "sequence round trip");
    Check(std::get<std::string>(fields.at(Value("text"))) == u8"\ufeff中文\nA",
          "UTF-8 BOM and multiline preserved");
    auto invalid = Scope(lease);
    invalid[Value("extra")] = Value(true);
    Check(Call(bridge, "control.clipboard.read", invalid).error ==
          "invalid_arguments", "extra fields rejected");
    auto stale = Scope(lease);
    stale[Value("targetRevision")] = Value(int64_t{4});
    Check(Call(bridge, "control.clipboard.read", stale).error ==
          "stale_scope", "settings revision bound");
    auto write = Scope(lease);
    write[Value("expectedSequence")] = Value(int64_t{6});
    write[Value("text")] = Value(std::string(u8"远端"));
    const auto conflict = Call(bridge, "control.clipboard.write", write);
    Check(std::get<std::string>(std::get<Map>(conflict.value).at(Value("status"))) ==
          "conflict" && writes == 0, "old observation cannot overwrite");
    write[Value("expectedSequence")] = Value(int64_t{7});
    const auto written = Call(bridge, "control.clipboard.write", write);
    Check(std::get<std::string>(std::get<Map>(written.value).at(Value("status"))) ==
          "written" && writes == 1, "exact write accepted");
    Check(Call(bridge, "control.clipboard.close", {
        {Value("lease"), Value(lease)}}).error.empty(), "lease closed");
    Check(Call(bridge, "control.clipboard.read", Scope(lease)).error ==
          "stale_scope", "old lease rejected");
    std::cout << "control clipboard bridge: passed\n";
  } catch (const std::exception& error) {
    std::cerr << "control clipboard bridge failed: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
