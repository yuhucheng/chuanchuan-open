#include "control_text_input.h"

#include <windows.h>

#include <deque>
#include <iostream>
#include <string>
#include <vector>

using share_hub::ControlInjectionResult;
using share_hub::ControlTextInput;

namespace {
int checks = 0;
int failures = 0;
UINT accepted = 0;
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
  return accepted == UINT_MAX ? count : accepted;
}
}  // namespace

int main() {
  ControlTextInput text(&Capture);
  const std::wstring value = L"\ufeff\u4E2D\u6587\nA\U0001F600";
  accepted = UINT_MAX;
  Check(text.Submit(value) == ControlInjectionResult::accepted,
        "Chinese multiline and supplementary text accepted");
  Check(sent.size() == value.size() * 2,
        "every UTF-16 unit has one down and one up");
  for (size_t index = 0; index < value.size() &&
                         2 * index + 1 < sent.size(); ++index) {
    const auto& down = sent[2 * index];
    const auto& up = sent[2 * index + 1];
    Check(down.type == INPUT_KEYBOARD && down.ki.wVk == 0 &&
              down.ki.wScan == value[index] &&
              down.ki.dwFlags == KEYEVENTF_UNICODE,
          "text down is original Unicode unit");
    Check(up.type == INPUT_KEYBOARD && up.ki.wVk == 0 &&
              up.ki.wScan == value[index] &&
              up.ki.dwFlags == (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP),
          "text up is original Unicode unit");
  }
  Check(value.size() == 7, "supplementary character remains surrogate pair");
  Check(sent.size() > 6 && sent[0].ki.wScan == 0xfeff &&
            sent[2].ki.wScan == 0x4e2d && sent[6].ki.wScan == L'\n',
        "leading BOM, Chinese and LF units preserved");

  const size_t before = sent.size();
  Check(text.Submit(L"") == ControlInjectionResult::rejected,
        "empty text rejected");
  Check(text.Submit(std::wstring(1, wchar_t{0xd800})) ==
            ControlInjectionResult::rejected,
        "unpaired surrogate rejected");
  Check(text.Submit(std::wstring(1, wchar_t{0})) ==
            ControlInjectionResult::rejected,
        "NUL cannot claim text delivery");
  Check(sent.size() == before, "invalid text emits no input");

  accepted = 0;
  Check(text.Submit(L"A") == ControlInjectionResult::rejected,
        "zero inserted events have no effect");
  accepted = 1;
  Check(text.Submit(L"A") == ControlInjectionResult::unknown,
        "partial UTF-16 pair has unknown outcome");
  Check(sent.size() == 1 &&
            sent[0].ki.dwFlags == (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP),
        "partial down attempts matching key release");
  accepted = 2;
  Check(text.Submit(L"AB") == ControlInjectionResult::unknown,
        "partial committed text never reports success");

  scripted = {1, 0};
  Check(text.Submit(L"B") == ControlInjectionResult::unknown,
        "failed key-up cleanup retains unknown result");
  sent.clear();
  Check(text.Submit(L"C") == ControlInjectionResult::unknown,
        "pending VK_PACKET prevents later text");
  Check(sent.empty(), "pending release emits no new text");
  accepted = 0;
  Check(text.ReleasePending() == ControlInjectionResult::rejected,
        "failed pending release remains retryable");
  accepted = 1;
  Check(text.ReleasePending() == ControlInjectionResult::accepted,
        "pending Unicode key-up succeeds on retry");
  Check(sent.size() == 1 &&
            sent[0].ki.dwFlags == (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP) &&
            sent[0].ki.wScan == L'B',
        "retry releases only the recorded Unicode unit");

  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
