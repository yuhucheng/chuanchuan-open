#include "device_preferences.h"

#include <windows.h>
#include <objbase.h>

#include <optional>
#include <utility>
#include <vector>

namespace share_hub {
namespace {
constexpr wchar_t kIdValue[] = L"discoveryID";
constexpr wchar_t kNameValue[] = L"deviceName";
constexpr char kDefaultName[] = "我的 Windows";

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

std::optional<std::string> ToUtf8(const std::wstring& text) {
  if (text.empty()) return std::string{};
  if (text.size() > 4096 || text.find(L'\0') != std::wstring::npos) return std::nullopt;
  const int length = static_cast<int>(text.size());
  const int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), length, nullptr, 0, nullptr, nullptr);
  if (needed == 0) return std::nullopt;
  std::string result(static_cast<size_t>(needed), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), length,
                         result.data(), needed, nullptr, nullptr) != needed) return std::nullopt;
  return result;
}

std::optional<std::wstring> ToWide(const std::string& text) {
  if (text.empty()) return std::wstring{};
  if (text.size() > 4096 || text.find('\0') != std::string::npos) return std::nullopt;
  const int length = static_cast<int>(text.size());
  const int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       text.data(), length, nullptr, 0);
  if (needed == 0) return std::nullopt;
  std::wstring result(static_cast<size_t>(needed), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), length,
                        result.data(), needed) != needed) return std::nullopt;
  return result;
}

enum class ReadStatus { kValue, kAbsentOrInvalid, kError };

ReadStatus ReadString(HKEY key, const wchar_t* name, std::string* value) {
  DWORD type = 0, bytes = 0;
  auto status = RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND) return ReadStatus::kAbsentOrInvalid;
  if (status != ERROR_SUCCESS) return ReadStatus::kError;
  // Preferences are tiny. Reject corrupt types/lengths without allocating an
  // unbounded registry value or accepting unterminated/embedded-NUL strings.
  if (type != REG_SZ || bytes < sizeof(wchar_t) || bytes > 4096 ||
      bytes % sizeof(wchar_t) != 0) return ReadStatus::kAbsentOrInvalid;
  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t));
  status = RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<BYTE*>(buffer.data()), &bytes);
  if (status != ERROR_SUCCESS) return ReadStatus::kError;
  if (type != REG_SZ || bytes < sizeof(wchar_t) ||
      bytes % sizeof(wchar_t) != 0) return ReadStatus::kAbsentOrInvalid;
  const size_t count = bytes / sizeof(wchar_t);
  if (buffer[count - 1] != L'\0') return ReadStatus::kAbsentOrInvalid;
  const auto decoded = ToUtf8(std::wstring(buffer.data(), count - 1));
  if (!decoded) return ReadStatus::kAbsentOrInvalid;
  *value = *decoded;
  return ReadStatus::kValue;
}

bool WriteString(HKEY key, const wchar_t* name, const std::string& value) {
  const auto wide = ToWide(value);
  if (!wide) return false;
  return RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(wide->c_str()),
      static_cast<DWORD>((wide->size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

std::optional<std::string> NewUuid() {
  GUID id{};
  wchar_t text[39]{};
  if (FAILED(CoCreateGuid(&id)) || StringFromGUID2(id, text, 39) != 39) return std::nullopt;
  const auto utf8 = ToUtf8(std::wstring(text + 1, 36));
  return utf8 ? NormalizeUuid(*utf8) : std::nullopt;
}
}  // namespace

DevicePreferences::DevicePreferences(std::wstring registry_key)
    : registry_key_(std::move(registry_key)) {}

bool DevicePreferences::Load() {
  error_.clear();
  RegistryKey key;
  if (!OpenKey(registry_key_, &key)) {
    error_ = "Unable to access the local device settings.";
    return false;
  }
  std::string saved_id, saved_name;
  const auto id_status = ReadString(key.value, kIdValue, &saved_id);
  const auto name_status = ReadString(key.value, kNameValue, &saved_name);
  if (id_status == ReadStatus::kError || name_status == ReadStatus::kError) {
    error_ = "Unable to read the local device settings.";
    return false;
  }
  auto id = NormalizeUuid(saved_id);
  if (!id) id = NewUuid();
  if (!id) {
    error_ = "Unable to create a local discovery identifier.";
    return false;
  }
  const auto name = NormalizeName(saved_name).value_or(kDefaultName);
  // Publish memory only after necessary repairs/defaults are persisted. If a
  // later write fails, a future Load can reuse any successfully repaired UUID.
  if ((saved_id != *id && !WriteString(key.value, kIdValue, *id)) ||
      (saved_name != name && !WriteString(key.value, kNameValue, name))) {
    error_ = "Unable to save the local device settings.";
    return false;
  }
  device_ = Device{*id, name, "windows"};
  loaded_ = true;
  return true;
}

bool DevicePreferences::SetName(const std::string& value) {
  error_.clear();
  if (!loaded_) {
    error_ = "Load the local device before changing its name.";
    return false;
  }
  const auto name = NormalizeName(value);
  if (!name) {
    error_ = "Device name must contain 1 to 128 UTF-8 bytes without control characters.";
    return false;
  }
  RegistryKey key;
  if (!OpenKey(registry_key_, &key) || !WriteString(key.value, kNameValue, *name)) {
    error_ = "Unable to save the local device name.";
    return false;
  }
  device_.name = *name;
  return true;
}
}  // namespace share_hub
