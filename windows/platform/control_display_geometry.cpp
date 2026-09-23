#include "control_display_geometry.h"

#include <windows.h>

namespace share_hub {
namespace {

std::optional<uint32_t> ParseSourceIndex(std::string_view id) {
  if (id.empty() || id.size() > 4 || (id.size() > 1 && id.front() == '0')) {
    return std::nullopt;
  }
  uint32_t index = 0;
  for (const char digit : id) {
    if (digit < '0' || digit > '9') return std::nullopt;
    index = index * 10 + static_cast<uint32_t>(digit - '0');
  }
  // The capture backend enumerates display adapters by a DWORD index. An
  // unexpectedly large id cannot be a practical attached desktop source.
  if (index >= 256) return std::nullopt;
  return index;
}

std::optional<uint32_t> Rotation(DWORD orientation) {
  switch (orientation) {
    case DMDO_DEFAULT: return 0;
    case DMDO_90: return 90;
    case DMDO_180: return 180;
    case DMDO_270: return 270;
    default: return std::nullopt;
  }
}

}  // namespace

std::optional<ControlScreenGeometry> ResolveControlScreenGeometry(
    std::string_view source_id) {
  const auto index = ParseSourceIndex(source_id);
  if (!index) return std::nullopt;
  DISPLAY_DEVICEW adapter{};
  adapter.cb = sizeof(adapter);
  if (!EnumDisplayDevicesW(nullptr, *index, &adapter, 0) ||
      !(adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) ||
      adapter.DeviceName[0] == L'\0') {
    return std::nullopt;
  }

  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  if (!EnumDisplaySettingsExW(adapter.DeviceName, ENUM_CURRENT_SETTINGS, &mode,
                              0) ||
      !(mode.dmFields & DM_POSITION) ||
      !(mode.dmFields & DM_PELSWIDTH) ||
      !(mode.dmFields & DM_PELSHEIGHT) ||
      !(mode.dmFields & DM_DISPLAYORIENTATION) ||
      mode.dmPelsWidth == 0 || mode.dmPelsWidth > 65535 ||
      mode.dmPelsHeight == 0 || mode.dmPelsHeight > 65535) {
    return std::nullopt;
  }
  const auto rotation = Rotation(mode.dmDisplayOrientation);
  if (!rotation) return std::nullopt;

  DISPLAY_DEVICEW monitor{};
  monitor.cb = sizeof(monitor);
  const bool has_monitor =
      EnumDisplayDevicesW(adapter.DeviceName, 0, &monitor, 0) != 0;
  ControlScreenGeometry result;
  result.source_index = *index;
  result.device_name = adapter.DeviceName;
  if (has_monitor) result.monitor_id = monitor.DeviceID;
  result.left = mode.dmPosition.x;
  result.top = mode.dmPosition.y;
  result.width = mode.dmPelsWidth;
  result.height = mode.dmPelsHeight;
  result.rotation = *rotation;
  return result;
}

bool CurrentControlScreenGeometry(const ControlScreenGeometry& expected) {
  const auto current = ResolveControlScreenGeometry(
      std::to_string(expected.source_index));
  return current && current->device_name == expected.device_name &&
         current->monitor_id == expected.monitor_id &&
         current->left == expected.left && current->top == expected.top &&
         current->width == expected.width &&
         current->height == expected.height &&
         current->rotation == expected.rotation;
}

}  // namespace share_hub
