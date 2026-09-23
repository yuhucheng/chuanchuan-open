#include "control_pointer_input.h"

#include <windows.h>

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

using share_hub::ControlInjectionResult;
using share_hub::ControlPointerButton;
using share_hub::ControlPointerInput;
using share_hub::ResolveControlScreenGeometry;

namespace {
int failures = 0;
int checks = 0;
std::vector<INPUT> submitted;
UINT accepted_count = 3;

void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) { std::cerr << "FAIL: " << label << '\n'; ++failures; }
}

UINT Capture(UINT count, INPUT* events, int size) {
  if (size != sizeof(INPUT)) return 0;
  submitted.assign(events, events + count);
  return count < accepted_count ? count : accepted_count;
}

void CheckPointer(double x, double y, LONG expected_x, LONG expected_y,
                  ControlPointerInput* input) {
  submitted.clear();
  accepted_count = 3;
  Check(input->Move(x, y) == ControlInjectionResult::accepted,
        "move accepted");
  Check(submitted.size() == 1 &&
            submitted[0].mi.dwFlags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                                        MOUSEEVENTF_VIRTUALDESK),
        "absolute virtual desktop movement");
  if (!submitted.empty()) {
    Check(submitted[0].mi.dx == expected_x &&
              submitted[0].mi.dy == expected_y,
          "image corner mapped to virtual desktop");
  }
}
}  // namespace

int main() {
  Check(SetProcessDpiAwarenessContext(
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0,
        "test uses production per-monitor DPI awareness");
  std::optional<share_hub::ControlScreenGeometry> source;
  for (DWORD index = 0; index < 256; ++index) {
    source = ResolveControlScreenGeometry(std::to_string(index));
    if (source) break;
  }
  if (!source) {
    std::cout << "No attached desktop display; live source tests skipped\n";
    return 0;
  }
  ControlPointerInput input(*source, &Capture);
  const LONG vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const LONG vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const LONG vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const LONG vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  auto scale = [](int64_t pixel, int64_t origin, int64_t extent) {
    return static_cast<LONG>(extent == 1 ? 0 :
        ((pixel - origin) * 65535 + (extent - 1) / 2) / (extent - 1));
  };
  CheckPointer(0, 0, scale(source->left, vx, vw),
               scale(source->top, vy, vh), &input);
  CheckPointer(1, 1, scale(int64_t(source->left) + source->width - 1, vx, vw),
               scale(int64_t(source->top) + source->height - 1, vy, vh),
               &input);
  const size_t before = submitted.size();
  Check(input.Move(std::nan(""), 0) == ControlInjectionResult::rejected,
        "NaN rejected");
  Check(input.Move(-0.01, 0) == ControlInjectionResult::rejected,
        "out of range rejected");
  Check(submitted.size() == before, "invalid position causes no injection");

  submitted.clear();
  Check(input.Button(0.5, 0.5, ControlPointerButton::back, true) ==
            ControlInjectionResult::accepted,
        "back button accepted");
  Check(submitted.size() == 2 &&
            submitted[1].mi.dwFlags == MOUSEEVENTF_XDOWN &&
            submitted[1].mi.mouseData == XBUTTON1,
        "button follows movement with correct X flag");
  accepted_count = 1;
  Check(input.Button(0.5, 0.5, ControlPointerButton::primary, true) ==
            ControlInjectionResult::unknown,
        "partial injection result is unknown");
  accepted_count = 0;
  Check(input.Button(0.5, 0.5, ControlPointerButton::primary, true) ==
            ControlInjectionResult::rejected,
        "zero accepted events are rejected");
  accepted_count = 3;
  Check(input.ReleaseButton(ControlPointerButton::forward) ==
            ControlInjectionResult::accepted,
        "release succeeds without source movement");
  Check(submitted.size() == 1 &&
            submitted[0].mi.dwFlags == MOUSEEVENTF_XUP &&
            submitted[0].mi.mouseData == XBUTTON2,
        "release addresses only the selected button");

  Check(input.Wheel(0.5, 0.5, 120, -120) ==
            ControlInjectionResult::accepted,
        "two-axis wheel accepted");
  Check(submitted.size() == 3 &&
            submitted[1].mi.dwFlags == MOUSEEVENTF_WHEEL &&
            static_cast<int32_t>(submitted[1].mi.mouseData) == -120 &&
            submitted[2].mi.dwFlags == MOUSEEVENTF_HWHEEL &&
            submitted[2].mi.mouseData == 120,
        "wheel units and axes preserved");
  Check(input.Wheel(0.5, 0.5, 0, 0.5) ==
            ControlInjectionResult::accepted,
        "fractional wheel remainder retained");
  Check(submitted.size() == 1, "sub-unit wheel emits no false scroll");
  Check(input.Wheel(0.5, 0.5, 0, 0.5) ==
            ControlInjectionResult::accepted,
        "second fraction completes one unit");
  Check(submitted.size() == 2 &&
            submitted[1].mi.dwFlags == MOUSEEVENTF_WHEEL &&
            submitted[1].mi.mouseData == 1,
        "fractional wheel emits exactly one accumulated unit");

  auto stale = *source;
  ++stale.left;
  ControlPointerInput stale_input(stale, &Capture);
  submitted.clear();
  Check(stale_input.Move(0.5, 0.5) == ControlInjectionResult::rejected,
        "stale source rejected");
  Check(submitted.empty(), "stale source causes no injection");
  Check(stale_input.ReleaseButton(ControlPointerButton::primary) ==
            ControlInjectionResult::accepted,
        "stale source does not block held button cleanup");

  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
