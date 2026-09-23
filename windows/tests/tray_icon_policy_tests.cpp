#include <iostream>

#include "tray_icon_policy.h"

namespace {
using share_hub::ChooseTrayIconVariant;
using share_hub::TrayIconPixels;
using share_hub::TrayIconVariant;

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                         \
      std::cerr << "Tray policy check failed at line " << __LINE__ << "\n";     \
      return false;                                                            \
    }                                                                          \
  } while (false)

bool CheckAppearance() {
  // Ordinary taskbar mode wins over the window palette (apps may use a
  // different mode). A missing Windows mode keeps the legacy dark taskbar.
  CHECK(ChooseTrayIconVariant(false, true, 0x000000) == TrayIconVariant::ink);
  CHECK(ChooseTrayIconVariant(false, false, 0xffffff) == TrayIconVariant::white);
  CHECK(ChooseTrayIconVariant(false, std::nullopt, 0xffffff) == TrayIconVariant::white);

  // High contrast ignores light/dark mode. Black, white, and colored contrast
  // themes must choose the asset with better contrast against system colors.
  CHECK(ChooseTrayIconVariant(true, true, 0x000000) == TrayIconVariant::white);
  CHECK(ChooseTrayIconVariant(true, false, 0xffffff) == TrayIconVariant::ink);
  CHECK(ChooseTrayIconVariant(true, true, 0x202020) == TrayIconVariant::white);
  CHECK(ChooseTrayIconVariant(true, false, 0xffeeaa) == TrayIconVariant::ink);
  CHECK(ChooseTrayIconVariant(true, true, 0x008000) == TrayIconVariant::white);
  CHECK(ChooseTrayIconVariant(true, false, 0x808080) == TrayIconVariant::ink);
  return true;
}

bool CheckScaling() {
  CHECK(TrayIconPixels(0, 0) == 16);
  CHECK(TrayIconPixels(0, 96) == 16);
  CHECK(TrayIconPixels(0, 120) == 20);
  CHECK(TrayIconPixels(0, 144) == 24);
  CHECK(TrayIconPixels(0, 192) == 32);
  CHECK(TrayIconPixels(0, 240) == 40);
  CHECK(TrayIconPixels(0, 288) == 48);
  CHECK(TrayIconPixels(0, 384) == 64);
  CHECK(TrayIconPixels(0, 432) == 72);
  CHECK(TrayIconPixels(0, 168) == 28);
  // Honor a valid OS metric even when it differs from 16 px at this DPI.
  CHECK(TrayIconPixels(24, 96) == 24);
  CHECK(TrayIconPixels(20, 192) == 20);
  CHECK(TrayIconPixels(-1, 144) == 24);
  return true;
}

bool CheckReentrantUpdates() {
  share_hub::TrayIconUpdateGate gate;
  const auto first = gate.Begin();
  CHECK(first.has_value());
  CHECK(gate.IsCurrent(*first));
  // Theme notifications received during a Shell call do not recursively load
  // or replace an icon. Multiple notifications result in one deferred refresh.
  CHECK(!gate.Begin().has_value());
  CHECK(!gate.Begin().has_value());
  CHECK(gate.End());
  const auto refresh = gate.Begin();
  CHECK(refresh.has_value());
  CHECK(gate.IsCurrent(*refresh));
  CHECK(!gate.End());

  const auto interrupted = gate.Begin();
  CHECK(interrupted.has_value());
  // Taskbar recreation or teardown invalidates the outer operation. Even a
  // late successful Shell return may no longer publish the old handle.
  gate.Invalidate();
  CHECK(!gate.IsCurrent(*interrupted));
  CHECK(!gate.Begin().has_value());
  CHECK(gate.End());
  const auto rebuilt = gate.Begin();
  CHECK(rebuilt.has_value());
  CHECK(gate.IsCurrent(*rebuilt));
  CHECK(!gate.IsCurrent(*interrupted));
  CHECK(!gate.End());
  return true;
}
}  // namespace

int main() {
  if (!CheckAppearance() || !CheckScaling() || !CheckReentrantUpdates()) return 1;
  std::cout << "Tray appearance, DPI, and reentrant update checks passed\n";
  return 0;
}
