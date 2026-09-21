#ifndef SHARE_HUB_CONNECTION_SECURITY_H_
#define SHARE_HUB_CONNECTION_SECURITY_H_

#include <cstdint>
#include <string>
#include <vector>

namespace share_hub {
// Windows side of the connection host primitive (macOS uses ConnectionSecurity
// in ShareHubPlatform). The Ed25519 identity seed is stored as user-scope
// DPAPI-protected data; the clock is monotonic and keeps advancing across
// system sleep. Both fail closed: a host that cannot read its protected seed or
// its clock MUST refuse to accept connections rather than fall back to an
// anonymous identity or wall-clock time. All methods run on the platform thread
// except ContinuousMicros, which is stateless.
class ConnectionSecurity {
 public:
  explicit ConnectionSecurity(
      std::wstring registry_key = L"Software\\ShareHub\\Client");

  // Loads the persisted 32-byte seed, generating and protecting it on first
  // use. Returns false and sets error() when protected storage is unavailable.
  // Never returns a seed that was not DPAPI-protected at rest.
  bool LoadIdentitySeed(std::vector<uint8_t>* seed);

  const std::string& error() const { return error_; }

  // Microseconds from a monotonic counter that includes system sleep and
  // ignores wall-clock changes. Returns false when no counter is available, so
  // callers can treat the clock as unusable instead of trusting zero.
  static bool ContinuousMicros(uint64_t* micros);

 private:
  std::wstring registry_key_;
  std::string error_;
};
}  // namespace share_hub

#endif  // SHARE_HUB_CONNECTION_SECURITY_H_
