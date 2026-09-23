#ifndef RUNNER_TRAY_ICON_POLICY_H_
#define RUNNER_TRAY_ICON_POLICY_H_

#include <cmath>
#include <cstdint>
#include <optional>

namespace share_hub {

enum class TrayIconVariant { ink, white };

// Shell calls can synchronously dispatch window messages. Serialize updates,
// coalesce refreshes, and invalidate in-flight work when the taskbar or owner
// disappears. This gate does not own Win32 handles.
class TrayIconUpdateGate {
 public:
  std::optional<std::uint64_t> Begin() {
    if (updating_) {
      pending_ = true;
      return std::nullopt;
    }
    updating_ = true;
    return generation_;
  }
  bool IsCurrent(std::uint64_t generation) const {
    return generation == generation_;
  }
  void Invalidate() {
    ++generation_;
    if (updating_) pending_ = true;
  }
  bool End() {
    updating_ = false;
    const auto pending = pending_;
    pending_ = false;
    return pending;
  }

 private:
  std::uint64_t generation_ = 0;
  bool updating_ = false, pending_ = false;
};

// Colors of assets/brand/logo-mono-{ink,white}.svg, encoded as RRGGBB.
inline double TrayColorLuminance(std::uint32_t rgb) {
  const auto linear = [](std::uint32_t channel) {
    const auto value = channel / 255.0;
    return value <= 0.04045 ? value / 12.92
                            : std::pow((value + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linear((rgb >> 16) & 0xff) +
         0.7152 * linear((rgb >> 8) & 0xff) +
         0.0722 * linear(rgb & 0xff);
}

inline TrayIconVariant ChooseTrayIconVariant(
    bool high_contrast, std::optional<bool> system_uses_light_theme,
    std::uint32_t system_background) {
  if (!high_contrast) {
    // Older Windows versions without this setting use a dark taskbar.
    return system_uses_light_theme.value_or(false) ? TrayIconVariant::ink
                                                  : TrayIconVariant::white;
  }
  const auto background = TrayColorLuminance(system_background);
  const auto contrast = [background](std::uint32_t rgb) {
    const auto foreground = TrayColorLuminance(rgb);
    return foreground > background ? (foreground + 0.05) / (background + 0.05)
                                   : (background + 0.05) / (foreground + 0.05);
  };
  return contrast(0x12161a) >= contrast(0xf5f7f7) ? TrayIconVariant::ink
                                               : TrayIconVariant::white;
}

inline int TrayIconPixels(int system_metric, unsigned int dpi) {
  if (system_metric > 0) return system_metric;
  // Only a fallback when GetSystemMetricsForDpi is unavailable or fails. Do
  // not clamp to our largest ICO frame: LoadImage can scale to the actual DPI.
  const auto effective_dpi = dpi == 0 ? 96u : dpi;
  return static_cast<int>((16ull * effective_dpi + 48) / 96);
}

}  // namespace share_hub

#endif  // RUNNER_TRAY_ICON_POLICY_H_
