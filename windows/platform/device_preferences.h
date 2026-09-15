#ifndef SHARE_HUB_DEVICE_PREFERENCES_H_
#define SHARE_HUB_DEVICE_PREFERENCES_H_

#include <string>

#include "discovery_model.h"

namespace share_hub {
// Discovery identity and display name only; this is not an activation token or
// a cryptographic device identity. All methods run on the platform thread.
class DevicePreferences {
 public:
  explicit DevicePreferences(
      std::wstring registry_key = L"Software\\ShareHub\\Client");
  bool Load();
  bool SetName(const std::string& name);
  const Device& device() const { return device_; }
  const std::string& error() const { return error_; }

 private:
  std::wstring registry_key_;
  Device device_;
  std::string error_;
  bool loaded_ = false;
};
}  // namespace share_hub

#endif  // SHARE_HUB_DEVICE_PREFERENCES_H_
