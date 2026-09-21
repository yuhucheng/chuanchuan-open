#include "connection_security.h"

#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <utility>

namespace share_hub {
namespace {
constexpr wchar_t kSeedValue[] = L"connectionIdentity";
constexpr size_t kSeedLength = 32;

class RegistryKey {
 public:
  ~RegistryKey() { if (value) RegCloseKey(value); }
  HKEY value = nullptr;
};

bool OpenKey(const std::wstring& path, RegistryKey* key) {
  // Never interpret an empty path as HKCU itself, nor truncate at embedded NUL.
  if (path.empty() || path.find(L'\0') != std::wstring::npos) return false;
  return RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE | KEY_SET_VALUE,
                        nullptr, &key->value, nullptr) == ERROR_SUCCESS;
}

// Absent is not an error: the caller mints a new identity. A present-but-corrupt
// value is an error and must not be replaced silently, because that would change
// the device identity behind the user's back.
enum class ReadStatus { kValue, kAbsent, kError };

ReadStatus ReadProtected(HKEY key, std::vector<uint8_t>* blob) {
  DWORD type = 0, bytes = 0;
  auto status = RegQueryValueExW(key, kSeedValue, nullptr, &type, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND) return ReadStatus::kAbsent;
  if (status != ERROR_SUCCESS) return ReadStatus::kError;
  if (type != REG_BINARY || bytes == 0 || bytes > 4096) return ReadStatus::kError;
  blob->resize(bytes);
  status = RegQueryValueExW(key, kSeedValue, nullptr, &type, blob->data(), &bytes);
  if (status != ERROR_SUCCESS) return ReadStatus::kError;
  blob->resize(bytes);
  return ReadStatus::kValue;
}

bool Unprotect(const std::vector<uint8_t>& blob, std::vector<uint8_t>* seed) {
  std::vector<uint8_t> mutable_blob = blob;
  DATA_BLOB input{static_cast<DWORD>(mutable_blob.size()), mutable_blob.data()};
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return false;
  }
  seed->assign(output.pbData, output.pbData + output.cbData);
  LocalFree(output.pbData);
  return true;
}

bool ProtectAndStore(HKEY key, const std::vector<uint8_t>& seed) {
  std::vector<uint8_t> mutable_seed = seed;
  DATA_BLOB input{static_cast<DWORD>(mutable_seed.size()), mutable_seed.data()};
  DATA_BLOB output{};
  if (!CryptProtectData(&input, nullptr, nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return false;
  }
  const auto status = RegSetValueExW(key, kSeedValue, 0, REG_BINARY,
                                     output.pbData, output.cbData);
  LocalFree(output.pbData);
  return status == ERROR_SUCCESS;
}
}  // namespace

ConnectionSecurity::ConnectionSecurity(std::wstring registry_key)
    : registry_key_(std::move(registry_key)) {}

bool ConnectionSecurity::LoadIdentitySeed(std::vector<uint8_t>* seed) {
  error_.clear();
  RegistryKey key;
  if (!OpenKey(registry_key_, &key)) {
    error_ = "Unable to access protected identity storage.";
    return false;
  }
  std::vector<uint8_t> blob;
  const auto status = ReadProtected(key.value, &blob);
  if (status == ReadStatus::kError) {
    error_ = "Unable to read protected identity storage.";
    return false;
  }
  if (status == ReadStatus::kValue) {
    std::vector<uint8_t> restored;
    if (!Unprotect(blob, &restored) || restored.size() != kSeedLength) {
      error_ = "Stored identity could not be unlocked.";
      return false;
    }
    *seed = std::move(restored);
    return true;
  }
  std::vector<uint8_t> fresh(kSeedLength);
  if (BCryptGenRandom(nullptr, fresh.data(), static_cast<ULONG>(fresh.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    error_ = "Unable to generate a device identity.";
    return false;
  }
  if (!ProtectAndStore(key.value, fresh)) {
    error_ = "Unable to persist the device identity.";
    return false;
  }
  *seed = std::move(fresh);
  return true;
}

bool ConnectionSecurity::ContinuousMicros(uint64_t* micros) {
  // QueryInterruptTimePrecise returns 100ns ticks that include system sleep and
  // ignore wall-clock edits, matching the macOS mach_continuous_time contract.
  // It is resolved at runtime so the app still loads on older Windows, where it
  // falls back to GetTickCount64 (milliseconds, also sleep-inclusive).
  using Precise = ULONGLONG(WINAPI*)();
  static const auto precise = reinterpret_cast<Precise>(
      GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "QueryInterruptTimePrecise"));
  if (precise) {
    *micros = static_cast<uint64_t>(precise()) / 10;
    return *micros != 0;
  }
  *micros = static_cast<uint64_t>(GetTickCount64()) * 1000;
  return *micros != 0;
}
}  // namespace share_hub
