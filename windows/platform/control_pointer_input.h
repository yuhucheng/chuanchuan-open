#ifndef SHARE_HUB_CONTROL_POINTER_INPUT_H_
#define SHARE_HUB_CONTROL_POINTER_INPUT_H_

#include "control_display_geometry.h"

#include <windows.h>

#include <optional>

namespace share_hub {

enum class ControlPointerButton { primary, secondary, middle, back, forward };
enum class ControlInjectionResult { accepted, rejected, unknown };

// Native pointer executor for one locally selected screen. Admission and the
// held-button ledger belong to the authenticated SDK owner; this class checks
// the pinned OS source again immediately before each injected event.
class ControlPointerInput {
 public:
  using Sender = UINT (*)(UINT count, INPUT* events, int size);

  explicit ControlPointerInput(ControlScreenGeometry source,
                               Sender sender = &SendInput);

  bool Current() const;
  ControlInjectionResult Move(double x, double y);
  ControlInjectionResult Button(double x, double y,
                                ControlPointerButton button, bool down);
  ControlInjectionResult Wheel(double x, double y, double delta_x,
                               double delta_y);
  ControlInjectionResult Key(uint16_t usage, bool down);
  // Releases are intentionally allowed after a source change or revocation.
  ControlInjectionResult ReleaseButton(ControlPointerButton button);
  ControlInjectionResult ReleaseKey(uint16_t usage);

 private:
  std::optional<INPUT> MoveEvent(double x, double y) const;
  ControlInjectionResult Submit(INPUT* events, UINT count) const;

  ControlScreenGeometry source_;
  Sender sender_;
  double wheel_remainder_x_ = 0;
  double wheel_remainder_y_ = 0;
};

}  // namespace share_hub

#endif
