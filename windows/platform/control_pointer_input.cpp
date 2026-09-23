#include "control_pointer_input.h"

#include <cmath>
#include <cstdint>
#include <utility>

namespace share_hub {
namespace {

std::optional<DWORD> ButtonFlag(ControlPointerButton button, bool down) {
  switch (button) {
    case ControlPointerButton::primary:
      return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
    case ControlPointerButton::secondary:
      return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
    case ControlPointerButton::middle:
      return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
    case ControlPointerButton::back:
    case ControlPointerButton::forward:
      return down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
  }
  return std::nullopt;
}

INPUT ButtonEvent(ControlPointerButton button, bool down) {
  INPUT event{};
  event.type = INPUT_MOUSE;
  event.mi.dwFlags = *ButtonFlag(button, down);
  if (button == ControlPointerButton::back ||
      button == ControlPointerButton::forward) {
    event.mi.mouseData = button == ControlPointerButton::back ? XBUTTON1 : XBUTTON2;
  }
  return event;
}

bool ValidUnit(double value) {
  return std::isfinite(value) && value >= 0 && value <= 1;
}

// HID keyboard page -> Windows Scan Code Set 1, as documented by Microsoft.
// A zero is intentionally unsupported: PrintScreen/Pause require special
// sequences; Non-US # aliases backslash; Power (0x66) is outside our contract.
// Source: https://learn.microsoft.com/windows/win32/inputdev/about-keyboard-input
constexpr uint16_t kUsageScanCodes[] = {
    // 0x04-0x0b
    0x001e, 0x0030, 0x002e, 0x0020, 0x0012, 0x0021, 0x0022, 0x0023,
    // 0x0c-0x13
    0x0017, 0x0024, 0x0025, 0x0026, 0x0032, 0x0031, 0x0018, 0x0019,
    // 0x14-0x1b
    0x0010, 0x0013, 0x001f, 0x0014, 0x0016, 0x002f, 0x0011, 0x002d,
    // 0x1c-0x23
    0x0015, 0x002c, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
    // 0x24-0x2b
    0x0008, 0x0009, 0x000a, 0x000b, 0x001c, 0x0001, 0x000e, 0x000f,
    // 0x2c-0x33 (0x32 aliases 0x31 and is not injectable independently)
    0x0039, 0x000c, 0x000d, 0x001a, 0x001b, 0x002b, 0x0000, 0x0027,
    // 0x34-0x3b
    0x0028, 0x0029, 0x0033, 0x0034, 0x0035, 0x003a, 0x003b, 0x003c,
    // 0x3c-0x43
    0x003d, 0x003e, 0x003f, 0x0040, 0x0041, 0x0042, 0x0043, 0x0044,
    // 0x44-0x4b (0x46 PrintScreen and 0x48 Pause need special sequences)
    0x0057, 0x0058, 0x0000, 0x0046, 0x0000, 0xe052, 0xe047, 0xe049,
    // 0x4c-0x53
    0xe053, 0xe04f, 0xe051, 0xe04d, 0xe04b, 0xe050, 0xe048, 0x0045,
    // 0x54-0x5b
    0xe035, 0x0037, 0x004a, 0x004e, 0xe01c, 0x004f, 0x0050, 0x0051,
    // 0x5c-0x63
    0x004b, 0x004c, 0x004d, 0x0047, 0x0048, 0x0049, 0x0052, 0x0053,
    // 0x64-0x6b (0x66 Power is never accepted)
    0x0056, 0xe05d, 0x0000, 0x0059, 0x0064, 0x0065, 0x0066, 0x0067,
    // 0x6c-0x73
    0x0068, 0x0069, 0x006a, 0x006b, 0x006c, 0x006d, 0x006e, 0x0076,
};
static_assert(sizeof(kUsageScanCodes) / sizeof(kUsageScanCodes[0]) == 0x70);

std::optional<INPUT> KeyEvent(uint16_t usage, bool down) {
  uint16_t scan = 0;
  if (usage >= 0x04 && usage <= 0x73) {
    scan = kUsageScanCodes[usage - 0x04];
  } else {
    switch (usage) {
      case 0xe0: scan = 0x001d; break;
      case 0xe1: scan = 0x002a; break;
      case 0xe2: scan = 0x0038; break;
      case 0xe3: scan = 0xe05b; break;
      case 0xe4: scan = 0xe01d; break;
      case 0xe5: scan = 0x0036; break;
      case 0xe6: scan = 0xe038; break;
      case 0xe7: scan = 0xe05c; break;
      default: return std::nullopt;
    }
  }
  if (scan == 0) return std::nullopt;
  INPUT event{};
  event.type = INPUT_KEYBOARD;
  event.ki.wScan = static_cast<WORD>(scan & 0xff);
  event.ki.dwFlags = KEYEVENTF_SCANCODE |
      ((scan & 0xff00) ? KEYEVENTF_EXTENDEDKEY : 0) |
      (down ? 0 : KEYEVENTF_KEYUP);
  return event;
}

std::optional<LONG> AbsoluteAxis(int64_t pixel, int64_t origin,
                                 int64_t extent) {
  if (extent < 1 || pixel < origin || pixel >= origin + extent) {
    return std::nullopt;
  }
  // SendInput's absolute range is the whole virtual desktop. The result is
  // rounded to the nearest representable position, including both endpoints.
  const int64_t value = extent == 1
      ? 0
      : ((pixel - origin) * 65535 + (extent - 1) / 2) / (extent - 1);
  return static_cast<LONG>(value);
}

}  // namespace

ControlPointerInput::ControlPointerInput(ControlScreenGeometry source,
                                         Sender sender)
    : source_(std::move(source)), sender_(sender) {}

bool ControlPointerInput::Current() const {
  return CurrentControlScreenGeometry(source_);
}

std::optional<INPUT> ControlPointerInput::MoveEvent(double x, double y) const {
  if (!ValidUnit(x) || !ValidUnit(y) || !Current()) {
    return std::nullopt;
  }
  const int64_t virtual_left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int64_t virtual_top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int64_t virtual_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int64_t virtual_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  const int64_t physical_x = static_cast<int64_t>(source_.left) +
      static_cast<int64_t>(std::llround(x * (source_.width - 1)));
  const int64_t physical_y = static_cast<int64_t>(source_.top) +
      static_cast<int64_t>(std::llround(y * (source_.height - 1)));
  const auto absolute_x = AbsoluteAxis(physical_x, virtual_left, virtual_width);
  const auto absolute_y = AbsoluteAxis(physical_y, virtual_top, virtual_height);
  if (!absolute_x || !absolute_y) return std::nullopt;
  INPUT event{};
  event.type = INPUT_MOUSE;
  event.mi.dx = *absolute_x;
  event.mi.dy = *absolute_y;
  event.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                     MOUSEEVENTF_VIRTUALDESK;
  return event;
}

ControlInjectionResult ControlPointerInput::Submit(INPUT* events,
                                                    UINT count) const {
  if (!sender_ || count == 0) return ControlInjectionResult::rejected;
  const UINT sent = sender_(count, events, sizeof(INPUT));
  if (sent == count) return ControlInjectionResult::accepted;
  // Zero accepted events have no effect; partial batches may have moved the
  // pointer or changed a button, so the SDK owner must stop and retain cleanup.
  return sent == 0 ? ControlInjectionResult::rejected
                   : ControlInjectionResult::unknown;
}

ControlInjectionResult ControlPointerInput::Move(double x, double y) {
  auto movement = MoveEvent(x, y);
  if (!movement) return ControlInjectionResult::rejected;
  return Submit(&*movement, 1);
}

ControlInjectionResult ControlPointerInput::Button(
    double x, double y, ControlPointerButton button, bool down) {
  if (!ButtonFlag(button, down)) return ControlInjectionResult::rejected;
  auto movement = MoveEvent(x, y);
  if (!movement) return ControlInjectionResult::rejected;
  INPUT events[2]{*movement, ButtonEvent(button, down)};
  return Submit(events, 2);
}

ControlInjectionResult ControlPointerInput::Wheel(
    double x, double y, double delta_x, double delta_y) {
  if (!std::isfinite(delta_x) || !std::isfinite(delta_y) ||
      std::abs(delta_x) > 120 || std::abs(delta_y) > 120 ||
      (delta_x == 0 && delta_y == 0)) {
    return ControlInjectionResult::rejected;
  }
  auto movement = MoveEvent(x, y);
  if (!movement) return ControlInjectionResult::rejected;
  INPUT events[3]{*movement, {}, {}};
  UINT count = 1;
  const double pending_y = wheel_remainder_y_ + delta_y;
  const double pending_x = wheel_remainder_x_ + delta_x;
  const auto units_y = static_cast<int32_t>(std::trunc(pending_y));
  const auto units_x = static_cast<int32_t>(std::trunc(pending_x));
  if (units_y != 0) {
    events[count].type = INPUT_MOUSE;
    events[count].mi.dwFlags = MOUSEEVENTF_WHEEL;
    events[count].mi.mouseData = static_cast<DWORD>(units_y);
    ++count;
  }
  if (units_x != 0) {
    events[count].type = INPUT_MOUSE;
    events[count].mi.dwFlags = MOUSEEVENTF_HWHEEL;
    events[count].mi.mouseData = static_cast<DWORD>(units_x);
    ++count;
  }
  const auto status = Submit(events, count);
  if (status == ControlInjectionResult::accepted) {
    wheel_remainder_x_ = pending_x - units_x;
    wheel_remainder_y_ = pending_y - units_y;
  }
  return status;
}

ControlInjectionResult ControlPointerInput::ReleaseButton(
    ControlPointerButton button) {
  if (!ButtonFlag(button, false)) return ControlInjectionResult::rejected;
  INPUT event = ButtonEvent(button, false);
  return Submit(&event, 1);
}

ControlInjectionResult ControlPointerInput::Key(uint16_t usage, bool down) {
  const auto event = KeyEvent(usage, down);
  if (!event || !Current()) return ControlInjectionResult::rejected;
  INPUT copy = *event;
  return Submit(&copy, 1);
}

ControlInjectionResult ControlPointerInput::ReleaseKey(uint16_t usage) {
  const auto event = KeyEvent(usage, false);
  if (!event) return ControlInjectionResult::rejected;
  INPUT copy = *event;
  return Submit(&copy, 1);
}

}  // namespace share_hub
