#include <windows.h>
#include <objbase.h>

#include <iostream>
#include <string>
#include <vector>

#include "device_preferences.h"

namespace {
#define CHECK(condition)                                                        \
  do {                                                                          \
    if (!(condition)) {                                                          \
      std::cerr << "Preference check failed at line " << __LINE__ << "\n";       \
      return false;                                                             \
    }                                                                           \
  } while (false)

class TemporaryKey {
 public:
  TemporaryKey() {
    GUID id{};
    wchar_t text[39]{};
    if (FAILED(CoCreateGuid(&id)) || StringFromGUID2(id, text, 39) != 39) return;
    path = L"Software\\ShareHub\\Tests\\preferences-" + std::wstring(text);
    valid = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                           KEY_ALL_ACCESS, nullptr, &key, nullptr) == ERROR_SUCCESS;
  }
  ~TemporaryKey() {
    RestoreAccess();
    if (key) RegCloseKey(key);
    if (valid) RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str());
  }
  bool DenyAccess() {
    DWORD length = 0;
    if (RegGetKeySecurity(key, DACL_SECURITY_INFORMATION, nullptr, &length) !=
        ERROR_INSUFFICIENT_BUFFER) return false;
    security.resize(length);
    if (RegGetKeySecurity(key, DACL_SECURITY_INFORMATION,
                          reinterpret_cast<PSECURITY_DESCRIPTOR>(security.data()),
                          &length) != ERROR_SUCCESS) return false;
    ACL acl{};
    SECURITY_DESCRIPTOR descriptor{};
    if (!InitializeAcl(&acl, sizeof(acl), ACL_REVISION) ||
        !InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) ||
        !SetSecurityDescriptorDacl(&descriptor, TRUE, &acl, FALSE)) return false;
    return RegSetKeySecurity(key, DACL_SECURITY_INFORMATION, &descriptor) == ERROR_SUCCESS;
  }
  bool RestoreAccess() {
    if (security.empty()) return true;
    const auto status = RegSetKeySecurity(
        key, DACL_SECURITY_INFORMATION,
        reinterpret_cast<PSECURITY_DESCRIPTOR>(security.data()));
    if (status == ERROR_SUCCESS) security.clear();
    return status == ERROR_SUCCESS;
  }
  std::wstring path;
  HKEY key = nullptr;
  bool valid = false;
 private:
  std::vector<BYTE> security;
};

bool WriteString(HKEY key, const wchar_t* name, const std::wstring& value) {
  return RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

bool CheckPreferences() {
  TemporaryKey temporary;
  CHECK(temporary.valid);
  share_hub::DevicePreferences first(temporary.path);
  CHECK(first.Load());
  CHECK(first.error().empty());
  CHECK(share_hub::NormalizeUuid(first.device().id) == first.device().id);
  CHECK(first.device().name == "我的 Windows");
  CHECK(first.device().platform == "windows");
  const auto stable_id = first.device().id;
  share_hub::DevicePreferences second(temporary.path);
  CHECK(second.Load());
  CHECK(second.device().id == stable_id);
  CHECK(first.SetName("　 我的工作电脑 \t"));
  CHECK(first.device().name == "我的工作电脑");
  CHECK(second.Load());
  CHECK(second.device().name == first.device().name);
  CHECK(second.device().id == stable_id);

  for (const std::string& invalid : std::vector<std::string>{
           "", " \t\n", "bad\nname", std::string(129, 'a'),
           std::string("bad\0name", 8), std::string("\xFF", 1)}) {
    CHECK(!first.SetName(invalid));
    CHECK(!first.error().empty());
    CHECK(first.device().name == "我的工作电脑");
    CHECK(second.Load());
    CHECK(second.device().name == "我的工作电脑");
  }
  CHECK(first.SetName(std::string(128, 'x')));
  CHECK(first.error().empty());
  CHECK(first.SetName("我的工作电脑"));

  CHECK(WriteString(temporary.key, L"discoveryID", L"corrupt-uuid"));
  CHECK(second.Load());
  CHECK(second.device().id != stable_id);
  CHECK(share_hub::NormalizeUuid(second.device().id) == second.device().id);
  const auto repaired_id = second.device().id;
  CHECK(first.Load());
  CHECK(first.device().id == repaired_id);
  CHECK(first.device().name == "我的工作电脑");

  // A real empty DACL denies fresh registry opens without affecting the held
  // test handle. It is restored before inspecting storage or deleting the key.
  CHECK(temporary.DenyAccess());
  CHECK(!first.SetName("Must not be saved"));
  CHECK(!first.error().empty());
  CHECK(first.device().name == "我的工作电脑");
  share_hub::DevicePreferences denied(temporary.path);
  CHECK(!denied.Load());
  CHECK(!denied.error().empty());
  CHECK(denied.device().id.empty());
  CHECK(!first.Load());
  CHECK(first.device().id == repaired_id);
  CHECK(first.device().name == "我的工作电脑");
  CHECK(temporary.RestoreAccess());
  CHECK(second.Load());
  CHECK(second.device().name == "我的工作电脑");
  CHECK(second.device().id == repaired_id);

  // A wrong registry value type is corrupt data, not a valid identity.
  const DWORD wrong_type = 42;
  CHECK(RegSetValueExW(temporary.key, L"discoveryID", 0, REG_DWORD,
                      reinterpret_cast<const BYTE*>(&wrong_type), sizeof(wrong_type)) == ERROR_SUCCESS);
  CHECK(WriteString(temporary.key, L"deviceName", L"bad\nname"));
  CHECK(first.Load());
  CHECK(first.device().id != repaired_id);
  CHECK(first.device().name == "我的 Windows");
  CHECK(second.Load());
  CHECK(second.device().id == first.device().id);
  CHECK(second.device().name == first.device().name);

  share_hub::DevicePreferences not_loaded(temporary.path);
  CHECK(!not_loaded.SetName("Must load first"));
  share_hub::DevicePreferences empty_key(L"");
  CHECK(!empty_key.Load());
  std::cout << "Device preference persistence, validation, repair and access failures passed.\n";
  return true;
}
}  // namespace

int main() { return CheckPreferences() ? 0 : 1; }
