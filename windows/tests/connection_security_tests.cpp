#include <windows.h>
#include <objbase.h>

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

#include "connection_security.h"

namespace {
#define CHECK(condition)                                                            \
  do {                                                                              \
    if (!(condition)) {                                                             \
      std::cerr << "Connection security check failed at line " << __LINE__ << "\n"; \
      return false;                                                                 \
    }                                                                               \
  } while (false)

class TemporaryKey {
 public:
  TemporaryKey() {
    GUID id{};
    wchar_t text[39]{};
    if (FAILED(CoCreateGuid(&id)) || StringFromGUID2(id, text, 39) != 39) return;
    path = L"Software\\ShareHub\\Tests\\connection-" + std::wstring(text);
    valid = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                           KEY_ALL_ACCESS, nullptr, &key, nullptr) == ERROR_SUCCESS;
  }
  ~TemporaryKey() {
    if (key) RegCloseKey(key);
    if (valid) RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str());
  }
  std::wstring path;
  HKEY key = nullptr;
  bool valid = false;
};

bool CheckClockIsMonotonic() {
  uint64_t first = 0, second = 0;
  CHECK(share_hub::ConnectionSecurity::ContinuousMicros(&first));
  CHECK(share_hub::ConnectionSecurity::ContinuousMicros(&second));
  CHECK(first != 0);
  CHECK(second >= first);
  return true;
}

bool CheckIdentityPersistsProtected() {
  TemporaryKey key;
  CHECK(key.valid);
  share_hub::ConnectionSecurity security(key.path);
  std::vector<uint8_t> first;
  CHECK(security.LoadIdentitySeed(&first));
  CHECK(first.size() == 32);
  // A second host instance must read back the same protected seed rather than
  // mint a new identity, otherwise saved peers could never reconnect.
  share_hub::ConnectionSecurity again(key.path);
  std::vector<uint8_t> second;
  CHECK(again.LoadIdentitySeed(&second));
  CHECK(second == first);
  // The stored value is DPAPI-protected, never the raw seed bytes.
  DWORD type = 0, bytes = 0;
  CHECK(RegQueryValueExW(key.key, L"connectionIdentity", nullptr, &type, nullptr,
                         &bytes) == ERROR_SUCCESS);
  CHECK(type == REG_BINARY);
  std::vector<uint8_t> stored(bytes);
  CHECK(RegQueryValueExW(key.key, L"connectionIdentity", nullptr, &type,
                         stored.data(), &bytes) == ERROR_SUCCESS);
  stored.resize(bytes);
  CHECK(stored.size() != first.size() || stored != first);
  return true;
}
}  // namespace

int main() {
  if (!CheckClockIsMonotonic()) return 1;
  if (!CheckIdentityPersistsProtected()) return 1;
  std::cout << "connection_security_tests passed\n";
  return 0;
}
