#ifndef SHARE_HUB_CONTROL_DISPLAY_GEOMETRY_H_
#define SHARE_HUB_CONTROL_DISPLAY_GEOMETRY_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace share_hub {

// Local OS mapping snapshot for one pinned WebRTC screen source id. Never
// deserialize these identity fields from a peer control message.
struct ControlScreenGeometry {
  uint32_t source_index = 0;
  std::wstring device_name;
  std::wstring monitor_id;
  int32_t left = 0;
  int32_t top = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t rotation = 0;
};

std::optional<ControlScreenGeometry> ResolveControlScreenGeometry(
    std::string_view source_id);
bool CurrentControlScreenGeometry(const ControlScreenGeometry& expected);

}  // namespace share_hub

#endif
