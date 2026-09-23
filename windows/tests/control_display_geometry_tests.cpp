#include "control_display_geometry.h"

#include <windows.h>

#include <iostream>
#include <string>

using share_hub::CurrentControlScreenGeometry;
using share_hub::ResolveControlScreenGeometry;

namespace {
int failures = 0;
int checks = 0;
void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) {
    std::cerr << "FAIL: " << label << '\n';
    ++failures;
  }
}
}  // namespace

int main() {
  for (const std::string& id : {"", "+0", "00", "-1", " 0", "0 ",
                                "1.0", "4294967296", "9999999999"}) {
    Check(!ResolveControlScreenGeometry(id), "noncanonical source id rejected");
  }

  unsigned attached = 0;
  for (DWORD index = 0; index < 256; ++index) {
    DISPLAY_DEVICEW adapter{};
    adapter.cb = sizeof(adapter);
    if (!EnumDisplayDevicesW(nullptr, index, &adapter, 0)) break;
    if (!(adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
    ++attached;
    const auto geometry = ResolveControlScreenGeometry(std::to_string(index));
    Check(geometry.has_value(), "attached WebRTC screen id resolves");
    if (!geometry) continue;
    Check(geometry->source_index == index, "source index retained");
    Check(geometry->width > 0 && geometry->height > 0,
          "current physical dimensions positive");
    Check(geometry->rotation == 0 || geometry->rotation == 90 ||
              geometry->rotation == 180 || geometry->rotation == 270,
          "rotation canonical");
    Check(CurrentControlScreenGeometry(*geometry), "unchanged source current");
    auto changed = *geometry;
    ++changed.left;
    Check(!CurrentControlScreenGeometry(changed), "moved display invalidates");
    changed = *geometry;
    ++changed.width;
    Check(!CurrentControlScreenGeometry(changed), "resized display invalidates");
    changed = *geometry;
    changed.device_name += L"-other";
    Check(!CurrentControlScreenGeometry(changed), "adapter swap invalidates");
    changed = *geometry;
    changed.monitor_id += L"-other";
    Check(!CurrentControlScreenGeometry(changed), "monitor swap invalidates");
  }
  if (attached == 0) {
    std::cout << "No attached desktop display; live geometry cases skipped\n";
  }
  Check(!ResolveControlScreenGeometry("9999"), "missing source rejected");
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
