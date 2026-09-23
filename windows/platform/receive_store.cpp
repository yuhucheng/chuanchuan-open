#include "receive_store.h"
#include "connection_security.h"
#include <windows.h>
#include <winternl.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <optional>
#include <utility>

namespace share_hub {
ReceiveException::ReceiveException(const std::string& code) : std::runtime_error(code), code_(code) {}
namespace {
[[noreturn]] void Fail(const char* code) { throw ReceiveException(code); }
constexpr wchar_t kDirectorySetting[] = L"ReceiveDirectoryV1";
struct SettingsKey {
  HKEY value = nullptr;
  ~SettingsKey() { if (value) RegCloseKey(value); }
};
std::optional<std::string> ReadDirectorySetting(const std::wstring& path) {
  SettingsKey key;
  const auto opened = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_QUERY_VALUE, &key.value);
  if (opened == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (opened != ERROR_SUCCESS) Fail("settings_unavailable");
  DWORD type = 0, size = 0;
  const auto queried = RegQueryValueExW(key.value, kDirectorySetting, nullptr, &type, nullptr, &size);
  if (queried == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (queried != ERROR_SUCCESS || type != REG_BINARY || size < 74 || size > 131072) Fail("settings_unavailable");
  std::string record(size, '\0');
  const auto expected = size;
  if (RegQueryValueExW(key.value, kDirectorySetting, nullptr, &type,
      reinterpret_cast<BYTE*>(record.data()), &size) != ERROR_SUCCESS ||
      type != REG_BINARY || size != expected) Fail("settings_unavailable");
  if (record.substr(0, 6) != "SHRD1\n" || record[70] != '\n' ||
      record.find('\0') != std::string::npos ||
      !std::all_of(record.begin() + 6, record.begin() + 70, [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      })) Fail("settings_unavailable");
  return record;
}
void SaveDirectorySetting(const std::wstring& path, const std::string& record) {
  SettingsKey key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key.value, nullptr) != ERROR_SUCCESS ||
      RegSetValueExW(key.value, kDirectorySetting, 0, REG_BINARY,
        reinterpret_cast<const BYTE*>(record.data()), static_cast<DWORD>(record.size())) != ERROR_SUCCESS) {
    Fail("settings_unavailable");
  }
}
[[noreturn]] void OsFailure(DWORD error) {
  if (error == ERROR_DISK_FULL || error == ERROR_HANDLE_DISK_FULL) Fail("disk_full");
  if (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD) Fail("permission_denied");
  if (error == ERROR_NOT_SUPPORTED || error == ERROR_INVALID_FUNCTION) Fail("unsupported_storage");
  Fail("io_failure");
}
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE h = INVALID_HANDLE_VALUE) : value(h) {}
  ~Handle() { Close(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(other.value) { other.value = INVALID_HANDLE_VALUE; }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) { Close(); value = other.value; other.value = INVALID_HANDLE_VALUE; }
    return *this;
  }
  void Close() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); value = INVALID_HANDLE_VALUE; }
  bool valid() const { return value != INVALID_HANDLE_VALUE && value != nullptr; }
};
std::string Hex(const uint8_t* bytes, size_t count) {
  std::string result; result.reserve(count * 2);
  for (size_t i = 0; i < count; ++i) { result += "0123456789abcdef"[bytes[i] >> 4]; result += "0123456789abcdef"[bytes[i] & 15]; }
  return result;
}
std::string RandomToken() {
  std::array<UCHAR, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) Fail("io_failure");
  return Hex(bytes.data(), bytes.size());
}
std::wstring Wide(const std::string& text, const char* failure = "invalid_name", size_t maximum_bytes = 32767) {
  if (text.empty() || text.size() > maximum_bytes) Fail(failure);
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (count <= 0) Fail(failure);
  std::wstring result(static_cast<size_t>(count), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), count) != count) Fail(failure);
  return result;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (count <= 0) Fail("invalid_name");
  std::string result(static_cast<size_t>(count), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), count, nullptr, nullptr) != count) Fail("invalid_name");
  return result;
}
bool SafeLeaf(const std::wstring& name) {
  if (name.empty() || name.back() == L'.' || name.back() == L' ') return false;
  for (const auto c : name) if (c < 32 || c == 127 || std::wstring(L"<>:\"/\\|?*").find(c) != std::wstring::npos) return false;
  auto stem = name.substr(0, name.find(L'.'));
  for (auto& c : stem) if (c >= L'a' && c <= L'z') c = static_cast<wchar_t>(c - L'a' + L'A');
  while (!stem.empty() && stem.back() == L' ') stem.pop_back();
  if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL" || stem == L"CONIN$" || stem == L"CONOUT$") return false;
  if (stem.size() == 4 && (stem.substr(0, 3) == L"COM" || stem.substr(0, 3) == L"LPT")) {
    const auto c = stem[3];
    if ((c >= L'1' && c <= L'9') || c == 0x00b9 || c == 0x00b2 || c == 0x00b3) return false;
  }
  return true;
}
std::wstring FileName(const std::string& name) {
  auto wide = Wide(name);
  if (name.size() > 255 || !SafeLeaf(wide)) Fail("invalid_name");
  const int count = NormalizeString(NormalizationC, wide.data(), static_cast<int>(wide.size()), nullptr, 0);
  if (count <= 0) Fail("invalid_name");
  std::wstring normalized(static_cast<size_t>(count), L'\0');
  const int actual = NormalizeString(NormalizationC, wide.data(), static_cast<int>(wide.size()), normalized.data(), count);
  if (actual <= 0) Fail("invalid_name");
  normalized.resize(static_cast<size_t>(actual));
  if (normalized.size() > 255 || Utf8(normalized).size() > 255 || !SafeLeaf(normalized)) Fail("invalid_name");
  return normalized;
}
std::wstring Numbered(const std::wstring& name, unsigned n) {
  if (!n) return name;
  const auto dot = name.find_last_of(L'.');
  const auto split = dot == std::wstring::npos || dot == 0 ? name.size() : dot;
  auto stem = name.substr(0, split); auto extension = name.substr(split);
  const auto suffix = L" (" + std::to_wstring(n) + L")";
  auto trim = [](std::wstring& text) {
    const auto last = text.back(); text.pop_back();
    if (last >= 0xdc00 && last <= 0xdfff && !text.empty()) text.pop_back();
  };
  for (;;) {
    auto candidate = stem + suffix + extension;
    if (candidate.size() <= 255 && Utf8(candidate).size() <= 255) return candidate;
    // Keep at least one stem scalar; trim an unusually long extension if needed.
    const size_t first_scalar = !stem.empty() && stem[0] >= 0xd800 && stem[0] <= 0xdbff ? 2 : 1;
    if (stem.size() > first_scalar) trim(stem); else if (!extension.empty()) trim(extension); else Fail("invalid_name");
  }
}
void ValidateDigest(const std::string& hash) {
  if (hash.size() != 64 || !std::all_of(hash.begin(), hash.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); })) Fail("integrity_mismatch");
}
class Hash {
 public:
  Hash() {
    if (BCryptOpenAlgorithmProvider(&provider_, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) Fail("io_failure");
    if (BCryptCreateHash(provider_, &hash_, nullptr, 0, nullptr, 0, 0) != 0) {
      BCryptCloseAlgorithmProvider(provider_, 0); provider_ = nullptr; Fail("io_failure");
    }
  }
  ~Hash() { if (hash_) BCryptDestroyHash(hash_); if (provider_) BCryptCloseAlgorithmProvider(provider_, 0); }
  Hash(const Hash&) = delete;
  Hash& operator=(const Hash&) = delete;
  void Add(const uint8_t* bytes, DWORD count) {
    if (BCryptHashData(hash_, const_cast<PUCHAR>(bytes), count, 0) != 0) Fail("io_failure");
  }
  std::string Digest() const {
    BCRYPT_HASH_HANDLE copy = nullptr;
    if (BCryptDuplicateHash(hash_, &copy, nullptr, 0, 0) != 0) Fail("io_failure");
    std::array<UCHAR, 32> digest{};
    const auto status = BCryptFinishHash(copy, digest.data(), static_cast<ULONG>(digest.size()), 0);
    BCryptDestroyHash(copy);
    if (status != 0) Fail("io_failure");
    return Hex(digest.data(), digest.size());
  }
 private:
  BCRYPT_ALG_HANDLE provider_ = nullptr;
  BCRYPT_HASH_HANDLE hash_ = nullptr;
};
struct NativeApi {
  using Create = NTSTATUS(NTAPI*)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
      PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
  using Rename = NTSTATUS(NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, FILE_INFORMATION_CLASS);
  using Error = ULONG(NTAPI*)(NTSTATUS);
  Create create = nullptr; Rename rename = nullptr; Error error = nullptr;
  NativeApi() {
    const auto dll = GetModuleHandleW(L"ntdll.dll");
    create = reinterpret_cast<Create>(GetProcAddress(dll, "NtCreateFile"));
    rename = reinterpret_cast<Rename>(GetProcAddress(dll, "NtSetInformationFile"));
    error = reinterpret_cast<Error>(GetProcAddress(dll, "RtlNtStatusToDosError"));
    if (!create || !rename || !error) Fail("unsupported_storage");
  }
  Handle Open(HANDLE parent, const std::wstring& leaf, ACCESS_MASK access, ULONG disposition,
              ULONG options, ULONG sharing, PSECURITY_DESCRIPTOR security = nullptr) const {
    UNICODE_STRING name{};
    name.Buffer = const_cast<PWSTR>(leaf.data());
    name.Length = static_cast<USHORT>(leaf.size() * sizeof(wchar_t)); name.MaximumLength = name.Length;
    OBJECT_ATTRIBUTES attrs{}; attrs.Length = sizeof(attrs); attrs.RootDirectory = parent;
    attrs.ObjectName = &name; attrs.Attributes = OBJ_CASE_INSENSITIVE; attrs.SecurityDescriptor = security;
    HANDLE file = INVALID_HANDLE_VALUE; IO_STATUS_BLOCK io{};
    const auto status = create(&file, access, &attrs, &io, nullptr, FILE_ATTRIBUTE_NORMAL,
      sharing, disposition, options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, nullptr, 0);
    if (status < 0) OsFailure(error(status));
    return Handle(file);
  }
  DWORD Publish(HANDLE file, const std::wstring& leaf) const {
    const auto size = sizeof(FILE_RENAME_INFO) + leaf.size() * sizeof(wchar_t);
    std::vector<uint8_t> buffer(size, 0);
    auto* info = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
    info->ReplaceIfExists = FALSE; info->RootDirectory = nullptr;
    info->FileNameLength = static_cast<DWORD>(leaf.size() * sizeof(wchar_t));
    std::memcpy(info->FileName, leaf.data(), info->FileNameLength);
    IO_STATUS_BLOCK io{};
    const auto status = rename(file, &io, info, static_cast<ULONG>(size), static_cast<FILE_INFORMATION_CLASS>(10));
    return status < 0 ? error(status) : ERROR_SUCCESS;
  }
};
struct Identity {
  FILE_ID_INFO file{};
  LONGLONG created = 0;
  bool operator==(const Identity& other) const {
    return created == other.created && file.VolumeSerialNumber == other.file.VolumeSerialNumber &&
      std::memcmp(file.FileId.Identifier, other.file.FileId.Identifier, sizeof(file.FileId.Identifier)) == 0;
  }
  std::string Opaque() const {
    return Hex(reinterpret_cast<const uint8_t*>(&file.VolumeSerialNumber), sizeof(file.VolumeSerialNumber)) +
      Hex(file.FileId.Identifier, sizeof(file.FileId.Identifier)) +
      Hex(reinterpret_cast<const uint8_t*>(&created), sizeof(created));
  }
};
struct Snapshot { Identity identity; int64_t size; };
Snapshot Inspect(HANDLE file, bool directory, const char* failure) {
  FILE_ATTRIBUTE_TAG_INFO attrs{}; FILE_STANDARD_INFO standard{}; FILE_BASIC_INFO basic{};
  Snapshot result{};
  if (GetFileType(file) != FILE_TYPE_DISK ||
      !GetFileInformationByHandleEx(file, FileAttributeTagInfo, &attrs, sizeof(attrs)) ||
      !GetFileInformationByHandleEx(file, FileStandardInfo, &standard, sizeof(standard)) ||
      !GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic)) ||
      !GetFileInformationByHandleEx(file, FileIdInfo, &result.identity.file, sizeof(result.identity.file))) Fail(failure);
  if ((attrs.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      ((attrs.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory || standard.DeletePending ||
      (!directory && (standard.NumberOfLinks != 1 || standard.EndOfFile.QuadPart < 0))) Fail(failure);
  result.identity.created = basic.CreationTime.QuadPart;
  result.size = standard.EndOfFile.QuadPart;
  return result;
}
struct SecurityDescriptor {
  PSECURITY_DESCRIPTOR value = nullptr;
  SecurityDescriptor() {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) OsFailure(GetLastError());
    Handle token(raw); DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size) OsFailure(GetLastError());
    std::vector<uint8_t> data(size);
    if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size)) OsFailure(GetLastError());
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &text)) OsFailure(GetLastError());
    const std::wstring sid(text); LocalFree(text);
    const auto descriptor = L"O:" + sid + L"D:P(A;;FA;;;SY)(A;;FA;;;" + sid + L")";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(), SDDL_REVISION_1, &value, nullptr)) OsFailure(GetLastError());
  }
  ~SecurityDescriptor() { if (value) LocalFree(value); }
};
enum State : uint64_t { active = 0, paused = 1, cancelled = 2, publishing = 3, committed = 4 };
constexpr uint64_t kStateMask = 7;
constexpr uint64_t kIoUnit = 8;
State GetState(const std::atomic<uint64_t>& gate) { return static_cast<State>(gate.load() & kStateMask); }
const char* StateName(State state) {
  switch (state) {
    case active: return "active";
    case paused: return "paused";
    case publishing: return "committing";
    case committed: return "committed";
    default: return "cancelled";
  }
}
State Stop(std::atomic<uint64_t>& gate, ReceiveStopMode mode) {
  auto observed = gate.load();
  for (;;) {
    const auto state = static_cast<State>(observed & kStateMask);
    if (state == cancelled || state == publishing || state == committed ||
        (state == paused && mode == ReceiveStopMode::pause)) return state;
    const auto next = (observed & ~kStateMask) | (mode == ReceiveStopMode::pause ? paused : cancelled);
    if (gate.compare_exchange_weak(observed, next)) return static_cast<State>(next & kStateMask);
  }
}
void SetState(std::atomic<uint64_t>& gate, State state) {
  auto observed = gate.load();
  while (!gate.compare_exchange_weak(observed, (observed & ~kStateMask) | state)) {}
}
void Admit(std::atomic<uint64_t>& gate) {
  auto observed = gate.load();
  for (;;) {
    const auto state = static_cast<State>(observed & kStateMask);
    if (state != active) Fail(state == paused ? "paused" : "cancelled");
    if (gate.compare_exchange_weak(observed, observed + kIoUnit)) return;
  }
}
void WinPublish(std::atomic<uint64_t>& gate) {
  uint64_t expected = active;
  if (!gate.compare_exchange_strong(expected, publishing)) Fail((expected & kStateMask) == paused ? "paused" : "cancelled");
}
}  // namespace

struct ReceiveStore::Impl {
  struct Entry;
  struct Directory {
    struct Ancestor { Handle handle; Identity identity; };
    std::vector<Ancestor> ancestors;
    std::wstring path;
    std::string token;
    std::string label;
    HANDLE handle() const { return ancestors.back().handle.value; }
    uint64_t volume() const { return ancestors.back().identity.file.VolumeSerialNumber; }
    void Verify() const {
      for (const auto& ancestor : ancestors)
        if (!(Inspect(ancestor.handle.value, true, "directory_changed").identity == ancestor.identity)) Fail("directory_changed");
    }
  };
  struct Scope {
    std::string token; std::string key; uint64_t deadline = 0;
    std::atomic<uint64_t> gate{active};
    std::mutex clock_mutex; uint64_t last_clock = 0;
    bool host = true; bool used = false; size_t references = 0;  // Registry lock.
    std::weak_ptr<Entry> entry;  // Registry lock; also gates in-progress resume.
  };
  struct Entry {
    std::mutex mutex;
    std::atomic<uint64_t> gate{active};
    std::shared_ptr<Directory> directory;
    std::shared_ptr<Scope> scope;  // atomic_load/store for stop-independent access.
    Handle file; Identity identity; bool identity_recorded = false;
    std::wstring name; std::string digest;
    int64_t size = 0; int64_t offset = 0;
    Hash prefix;
    ReceiveCheckpoint checkpoint{0, {}, {}};
    ReceiveReceipt receipt;
    bool reserved = false;  // Entry serialization (begin not yet exposed).
    uint64_t unwritten = 0;  // Entry serialization, capacity lock for accounting.
    bool exposed = false;   // Entry serialization.
  };
  ReceiveStoreOptions options;
  NativeApi native;
  std::mutex registry;
  std::mutex directory_settings;
  bool closed = false;
  std::map<std::string, std::shared_ptr<Directory>> directories;
  std::map<std::string, std::shared_ptr<Scope>> scopes;
  std::map<std::string, std::shared_ptr<Entry>> entries;
  // Disk queries may block. This mutex never participates in synchronous stop;
  // serializing the free-space snapshot with accounting avoids stale admission.
  std::mutex capacity;
  std::map<uint64_t, uint64_t> reserved;
  uint64_t total_reserved = 0;

  explicit Impl(ReceiveStoreOptions o) : options(std::move(o)) {
    if (!options.clock) options.clock = ConnectionSecurity::ContinuousMicros;
  }
  std::shared_ptr<Entry> Lookup(const std::string& token) {
    std::lock_guard<std::mutex> lock(registry);
    const auto it = entries.find(token); if (it == entries.end()) Fail("invalid_token");
    return it->second;
  }
  std::shared_ptr<Scope> FindScope(const std::string& token) {
    std::lock_guard<std::mutex> lock(registry);
    const auto it = scopes.find(token); if (it == scopes.end() || !it->second->host) Fail("stale_scope");
    return it->second;
  }
  void Time(Scope& scope) {
    std::lock_guard<std::mutex> lock(scope.clock_mutex);
    uint64_t now = 0;
    if (!options.clock(&now) || !now || now < scope.last_clock) {
      Stop(scope.gate, ReceiveStopMode::cancel); Fail("clock_unavailable");
    }
    scope.last_clock = now;
    if (now >= scope.deadline) { Stop(scope.gate, ReceiveStopMode::cancel); Fail("expired"); }
  }
  struct Permit {
    std::atomic<uint64_t>* entry = nullptr;
    std::atomic<uint64_t>* scope = nullptr;
    Permit(Impl& owner, Entry& e, Scope& s) {
      owner.Time(s);
      Admit(e.gate); entry = &e.gate;
      try { Admit(s.gate); scope = &s.gate; }
      catch (...) { entry->fetch_sub(kIoUnit); entry = nullptr; throw; }
    }
    ~Permit() { if (scope) scope->fetch_sub(kIoUnit); if (entry) entry->fetch_sub(kIoUnit); }
  };
  ReceiveIoDirective Hook(ReceiveIo op, Entry& entry, size_t count = 0) {
    auto result = options.io ? options.io(op, reinterpret_cast<uintptr_t>(entry.file.value), count) : ReceiveIoDirective{};
    if (result.error) OsFailure(result.error);
    return result;
  }
  std::shared_ptr<Scope> BoundScope(Entry& entry, const std::string& token) {
    if (GetState(entry.gate) == cancelled) Fail("cancelled");
    const auto scope = std::atomic_load(&entry.scope);
    if (scope->token != token) Fail("stale_scope");
    return scope;
  }
  void Terminal(Entry& entry) {
    if (GetState(entry.gate) != committed) {
      SetState(entry.gate, cancelled);
      Stop(std::atomic_load(&entry.scope)->gate, ReceiveStopMode::cancel);
    }
  }
  void OnFailure(Entry& entry, const ReceiveException& error) {
    if (error.code() != "paused" && error.code() != "stale_scope") Terminal(entry);
  }
  void CheckFile(Entry& entry, int64_t length) {
    const auto current = Inspect(entry.file.value, false, "source_changed");
    if (!(current.identity == entry.identity) || current.size != length) Fail("source_changed");
  }
  void Unreserve(Entry& entry) {
    if (!entry.reserved) return;
    std::lock_guard<std::mutex> lock(capacity);
    reserved[entry.directory->volume()] -= entry.unwritten;
    total_reserved -= static_cast<uint64_t>(entry.size);
    entry.reserved = false; entry.unwritten = 0;
  }
  void AccountWrite(Entry& entry, DWORD actual) {
    std::lock_guard<std::mutex> lock(capacity);
    reserved[entry.directory->volume()] -= actual; entry.unwritten -= actual;
  }
  void DropScopeReference(const std::shared_ptr<Scope>& scope) {
    // Registry lock held by caller.
    if (scope->references) --scope->references;
    if (!scope->references) scope->entry.reset();
    if (!scope->host && !scope->references) scopes.erase(scope->token);
  }
  std::shared_ptr<Directory> OpenDirectory(std::wstring path, bool create_leaf) {
    if (path.size() < 3 || path.size() > 32767 || path[1] != L':' || path[2] != L'\\' ||
        !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z'))) Fail("unsupported_storage");
    while (path.size() > 3 && path.back() == L'\\') path.pop_back();
    const auto root = path.substr(0, 3);
    const auto drive = GetDriveTypeW(root.c_str());
    if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE) Fail("unsupported_storage");
    std::vector<std::wstring> parts;
    for (size_t start = 3; start < path.size();) {
      auto end = path.find(L'\\', start); if (end == std::wstring::npos) end = path.size();
      auto part = path.substr(start, end - start);
      if (!SafeLeaf(part) || part.size() > 255) Fail("invalid_name");
      Utf8(part); parts.push_back(std::move(part)); start = end + 1;
      if (parts.size() > 64) Fail("resource_limit");
    }
    auto directory = std::make_shared<Directory>(); directory->path = path;
    constexpr ACCESS_MASK access = FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_TRAVERSE | SYNCHRONIZE;
    Handle handle(CreateFileW(root.c_str(), access, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                             FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!handle.valid()) OsFailure(GetLastError());
    const auto identity = Inspect(handle.value, true, "directory_changed").identity;
    std::array<wchar_t, 64> type{};
    if (!GetVolumeInformationByHandleW(handle.value, nullptr, 0, nullptr, nullptr, nullptr, type.data(), static_cast<DWORD>(type.size())) ||
        std::wstring(type.data()) != L"NTFS") Fail("unsupported_storage");
    directory->ancestors.push_back({std::move(handle), identity});
    for (size_t i = 0; i < parts.size(); ++i) {
      auto child = native.Open(directory->handle(), parts[i], access,
        create_leaf && i + 1 == parts.size() ? FILE_OPEN_IF : FILE_OPEN,
        FILE_DIRECTORY_FILE, FILE_SHARE_READ);
      const auto child_id = Inspect(child.value, true, "directory_changed").identity;
      if (child_id.file.VolumeSerialNumber != identity.file.VolumeSerialNumber) Fail("unsupported_storage");
      directory->ancestors.push_back({std::move(child), child_id});
    }
    directory->Verify(); directory->token = RandomToken();
    directory->label = Utf8(parts.empty() ? root : parts.back());
    return directory;
  }
  ReceiveDirectory RegisterDirectory(std::shared_ptr<Directory> directory) {
    std::lock_guard<std::mutex> lock(registry);
    if (closed) Fail("cancelled");
    if (directories.size() >= ReceiveStore::kMaximumDirectories) Fail("resource_limit");
    directories.emplace(directory->token, directory);
    return {directory->token, directory->label};
  }
  std::string WholeHash(Entry& entry, Scope& scope, int64_t length) {
    { Permit permit(*this, entry, scope); entry.directory->Verify(); CheckFile(entry, length); }
    { Permit permit(*this, entry, scope); LARGE_INTEGER zero{};
      if (!SetFilePointerEx(entry.file.value, zero, nullptr, FILE_BEGIN)) OsFailure(GetLastError()); }
    Hash hash;
    std::array<uint8_t, ReceiveStore::kHashBlock> buffer{};
    int64_t offset = 0;
    while (offset < length) {
      const auto request = static_cast<size_t>(std::min<int64_t>(static_cast<int64_t>(buffer.size()), length - offset));
      const auto action = Hook(ReceiveIo::read, entry, request);
      Permit permit(*this, entry, scope);
      const auto count = static_cast<DWORD>(std::min(request, action.maximum_bytes));
      DWORD read = 0;
      if (!ReadFile(entry.file.value, buffer.data(), count, &read, nullptr)) OsFailure(GetLastError());
      if (!read || read > count) Fail("io_failure");
      hash.Add(buffer.data(), read); offset += read;
    }
    { Permit permit(*this, entry, scope); CheckFile(entry, length); entry.directory->Verify(); }
    return hash.Digest();
  }
  void Cleanup(Entry& entry) {
    if (GetState(entry.gate) == committed) return;
    if (!entry.file.valid()) { Unreserve(entry); return; }
    try {
      const auto snapshot = Inspect(entry.file.value, false, "cleanup_failed");
      // Only the exclusive FILE_CREATE handle can reach this recovery path.
      // An initial metadata-query failure must not orphan our known object;
      // validate it from that retained handle, never reopen or infer a path.
      if (!entry.identity_recorded) {
        entry.identity = snapshot.identity; entry.identity_recorded = true;
      }
      if (!(snapshot.identity == entry.identity)) Fail("cleanup_failed");
      Hook(ReceiveIo::cleanup, entry);
      FILE_DISPOSITION_INFO disposition{}; disposition.DeleteFile = TRUE;
      if (!SetFileInformationByHandle(entry.file.value, FileDispositionInfo, &disposition, sizeof(disposition))) Fail("cleanup_failed");
      entry.file.Close(); Unreserve(entry);
    } catch (...) { Fail("cleanup_failed"); }
  }
};

ReceiveStore::ReceiveStore(ReceiveStoreOptions options) : impl_(std::make_unique<Impl>(std::move(options))) {}
ReceiveStore::~ReceiveStore() {
  Shutdown();
  // The owner has joined its workers. Failed cleanup retains files, never guesses
  // paths; cross-process orphan journals are outside this process-local store.
  try { RetryPendingCleanup(); } catch (...) {}
}
ReceiveDirectory ReceiveStore::DirectoryDefault() {
  PWSTR path = nullptr;
  const auto result = SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT, nullptr, &path);
  if (FAILED(result) || !path) Fail("permission_denied");
  std::wstring native(path); CoTaskMemFree(path);
  native += L"\\串串";
  return impl_->RegisterDirectory(impl_->OpenDirectory(std::move(native), true));
}
ReceiveDirectory ReceiveStore::DirectoryFromPicker(const std::wstring& path) {
  std::lock_guard<std::mutex> lock(impl_->directory_settings);
  auto directory = impl_->OpenDirectory(path, false);
  const auto result = impl_->RegisterDirectory(directory);
  try {
    if (!impl_->options.directory_settings_key.empty()) {
      const auto record = "SHRD1\n" + directory->ancestors.back().identity.Opaque() +
        "\n" + Utf8(directory->path);
      SaveDirectorySetting(impl_->options.directory_settings_key, record);
    }
    return result;
  } catch (...) { DirectoryRelease(result.token); throw; }
}
ReceiveDirectory ReceiveStore::DirectoryConfigured() {
  std::lock_guard<std::mutex> lock(impl_->directory_settings);
  if (!impl_->options.directory_settings_key.empty()) {
    const auto record = ReadDirectorySetting(impl_->options.directory_settings_key);
    if (record) {
      auto directory = impl_->OpenDirectory(Wide(record->substr(71), "settings_unavailable", 131072), false);
      if (directory->ancestors.back().identity.Opaque() != record->substr(6, 64)) Fail("directory_changed");
      return impl_->RegisterDirectory(directory);
    }
  }
  return DirectoryDefault();
}
void ReceiveStore::DirectoryRelease(const std::string& token) {
  std::shared_ptr<Impl::Directory> released;
  { std::lock_guard<std::mutex> lock(impl_->registry);
    const auto it = impl_->directories.find(token);
    if (it == impl_->directories.end()) return;
    released = std::move(it->second); impl_->directories.erase(it);
  }
  // Any final CloseHandle runs outside the registry used by synchronous stop.
}
std::string ReceiveStore::ScopeOpen(const std::string& key, int64_t deadline) {
  if (key.empty() || key.size() > 256 || key.find('\0') != std::string::npos) Fail("stale_scope");
  Wide(key, "stale_scope");
  if (deadline <= 0) Fail("expired");
  auto scope = std::make_shared<Impl::Scope>(); scope->token = RandomToken(); scope->key = key;
  scope->deadline = static_cast<uint64_t>(deadline); impl_->Time(*scope);
  std::lock_guard<std::mutex> lock(impl_->registry);
  if (impl_->closed) Fail("cancelled");
  if (impl_->scopes.size() >= kMaximumScopes) Fail("resource_limit");
  impl_->scopes.emplace(scope->token, scope); return scope->token;
}
std::string ReceiveStore::ScopeStop(const std::string& token, ReceiveStopMode mode) {
  std::lock_guard<std::mutex> lock(impl_->registry);
  const auto it = impl_->scopes.find(token);
  if (it == impl_->scopes.end() || !it->second->host) Fail("stale_scope");
  const auto state = Stop(it->second->gate, mode);
  if (state == cancelled) {
    if (const auto entry = it->second->entry.lock()) Stop(entry->gate, ReceiveStopMode::cancel);
  }
  return StateName(state);
}
void ReceiveStore::ScopeClose(const std::string& token) {
  std::lock_guard<std::mutex> lock(impl_->registry);
  const auto it = impl_->scopes.find(token); if (it == impl_->scopes.end()) return;
  const auto state = Stop(it->second->gate, ReceiveStopMode::cancel); it->second->host = false;
  if (state == cancelled) {
    if (const auto entry = it->second->entry.lock()) Stop(entry->gate, ReceiveStopMode::cancel);
  }
  if (!it->second->references) impl_->scopes.erase(it);
}
std::string ReceiveStore::Begin(const std::string& directory_token, const std::string& scope_token,
                              const std::string& name, int64_t size, const std::string& digest) {
  // Retry only objects this store created; failed cleanup remains resource-bound.
  try { RetryPendingCleanup(); }
  catch (const ReceiveException& error) { if (error.code() != "cleanup_failed") throw; }
  auto filename = FileName(name);
  if (size < 0) Fail("invalid_range");
  ValidateDigest(digest);
  const auto scope = impl_->FindScope(scope_token); impl_->Time(*scope);
  if (GetState(scope->gate) != active) Fail(GetState(scope->gate) == paused ? "paused" : "cancelled");
  std::shared_ptr<Impl::Directory> directory;
  { std::lock_guard<std::mutex> lock(impl_->registry);
    const auto it = impl_->directories.find(directory_token); if (it == impl_->directories.end()) Fail("invalid_token");
    directory = it->second; }
  directory->Verify();
  auto entry = std::make_shared<Impl::Entry>(); entry->directory = directory; entry->scope = scope;
  entry->name = std::move(filename); entry->size = size; entry->digest = digest;
  const auto token = RandomToken();
  std::lock_guard<std::mutex> entry_lock(entry->mutex);
  { std::lock_guard<std::mutex> budget(impl_->capacity);
    uint64_t free_bytes = 0;
    if (impl_->options.free_bytes) {
      if (!impl_->options.free_bytes(directory->volume(), &free_bytes)) Fail("io_failure");
    } else {
      ULARGE_INTEGER free{};
      if (!GetDiskFreeSpaceExW(directory->path.c_str(), &free, nullptr, nullptr)) OsFailure(GetLastError());
      free_bytes = free.QuadPart;
    }
    std::lock_guard<std::mutex> lock(impl_->registry);
    if (impl_->closed) Fail("cancelled");
    if (impl_->entries.size() >= kMaximumEntries) Fail("resource_limit");
    if (scope->used || !scope->host) Fail("stale_scope");
    const auto bytes = static_cast<uint64_t>(size);
    const auto on_volume = impl_->reserved[directory->volume()];
    if (bytes > impl_->options.maximum_reserved_bytes - std::min(impl_->total_reserved, impl_->options.maximum_reserved_bytes)) Fail("resource_limit");
    if (on_volume > free_bytes || bytes > free_bytes - on_volume) Fail("disk_full");
    impl_->entries.emplace(token, entry);
    impl_->reserved[directory->volume()] += bytes; impl_->total_reserved += bytes;
    entry->reserved = true; entry->unwritten = bytes;
    scope->used = true; ++scope->references; scope->entry = entry;
  }
  try {
    Impl::Permit permit(*impl_, *entry, *scope);
    directory->Verify(); SecurityDescriptor acl;
    const auto random = RandomToken();
    const std::wstring leaf = L".chuanchuan-receive-" + std::wstring(random.begin(), random.end()) + L".part";
    entry->file = impl_->native.Open(directory->handle(), leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, FILE_CREATE, FILE_NON_DIRECTORY_FILE, 0, acl.value);
    impl_->Hook(ReceiveIo::after_create, *entry);
    const auto snapshot = Inspect(entry->file.value, false, "source_changed");
    entry->identity = snapshot.identity;
    entry->identity_recorded = true;
    if (snapshot.size != 0 || snapshot.identity.file.VolumeSerialNumber != directory->volume()) Fail("source_changed");
    FILE_BASIC_INFO attributes{}; attributes.FileAttributes = FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY;
    if (!SetFileInformationByHandle(entry->file.value, FileBasicInfo, &attributes, sizeof(attributes))) OsFailure(GetLastError());
    entry->checkpoint = {0, entry->prefix.Digest(), entry->identity.Opaque()};
    entry->exposed = true;
    return token;
  } catch (...) {
    impl_->Terminal(*entry);
    try { impl_->Cleanup(*entry); } catch (...) {}
    if (!entry->file.valid()) {
      std::lock_guard<std::mutex> lock(impl_->registry); impl_->entries.erase(token); impl_->DropScopeReference(scope);
    }
    throw;
  }
}
int64_t ReceiveStore::Append(const std::string& token, const std::string& scope_token,
                            int64_t offset, const std::vector<uint8_t>& bytes) {
  const auto entry = impl_->Lookup(token); std::lock_guard<std::mutex> lock(entry->mutex);
  const auto scope = impl_->BoundScope(*entry, scope_token);
  try {
    { Impl::Permit permit(*impl_, *entry, *scope); }
    if (offset != entry->offset || offset < 0 || bytes.empty() || bytes.size() > kMaximumChunk ||
        offset > entry->size || bytes.size() > static_cast<uint64_t>(entry->size - offset)) Fail("invalid_range");
    { Impl::Permit permit(*impl_, *entry, *scope);
      entry->directory->Verify(); impl_->CheckFile(*entry, entry->offset);
      LARGE_INTEGER position{}; position.QuadPart = entry->offset;
      if (!SetFilePointerEx(entry->file.value, position, nullptr, FILE_BEGIN)) OsFailure(GetLastError()); }
    size_t written = 0;
    while (written < bytes.size()) {
      const auto action = impl_->Hook(ReceiveIo::write, *entry, bytes.size() - written);
      Impl::Permit permit(*impl_, *entry, *scope);
      const auto count = static_cast<DWORD>(std::min(bytes.size() - written, action.maximum_bytes));
      DWORD actual = 0;
      if (!WriteFile(entry->file.value, bytes.data() + written, count, &actual, nullptr)) OsFailure(GetLastError());
      if (!actual || actual > count) Fail("io_failure");
      impl_->AccountWrite(*entry, actual);
      entry->prefix.Add(bytes.data() + written, actual); written += actual; entry->offset += actual;
      entry->checkpoint = {entry->offset, entry->prefix.Digest(), entry->identity.Opaque()};
    }
    return entry->offset;
  } catch (const ReceiveException& e) { impl_->OnFailure(*entry, e); throw; }
  catch (...) { impl_->Terminal(*entry); throw; }
}
ReceiveCheckpoint ReceiveStore::Checkpoint(const std::string& token) {
  const auto entry = impl_->Lookup(token); std::lock_guard<std::mutex> lock(entry->mutex);
  return entry->checkpoint;
}
void ReceiveStore::Resume(const std::string& token, const std::string& scope_token,
                         const ReceiveCheckpoint& expected) {
  const auto entry = impl_->Lookup(token); std::lock_guard<std::mutex> lock(entry->mutex);
  if (GetState(entry->gate) != active) Fail("cancelled");
  const auto old = std::atomic_load(&entry->scope);
  std::shared_ptr<Impl::Scope> fresh;
  bool retained = false;
  try {
    if (GetState(old->gate) != paused) Fail("stale_scope");
    fresh = impl_->FindScope(scope_token);
    if (fresh == old || fresh->key != old->key || fresh->deadline != old->deadline) Fail("stale_scope");
    { std::scoped_lock guards(old->clock_mutex, fresh->clock_mutex);
      // A fresh scope does not reset the observed monotonic-clock floor.
      fresh->last_clock = std::max(fresh->last_clock, old->last_clock); }
    impl_->Time(*fresh);
    { std::lock_guard<std::mutex> guard(impl_->registry);
      if (impl_->closed) Fail("cancelled");
      if (fresh->used || !fresh->host || GetState(fresh->gate) != active) Fail("stale_scope");
      fresh->used = true; ++fresh->references; fresh->entry = entry; retained = true; }
    if (expected.offset != entry->checkpoint.offset || expected.sha256 != entry->checkpoint.sha256 ||
        expected.identity != entry->checkpoint.identity) Fail("integrity_mismatch");
    const auto digest = impl_->WholeHash(*entry, *fresh, entry->offset);
    if (digest != expected.sha256) Fail("integrity_mismatch");
    { Impl::Permit permit(*impl_, *entry, *fresh);
      std::lock_guard<std::mutex> guard(impl_->registry);
      if (GetState(old->gate) != paused || GetState(entry->gate) == cancelled) Fail("cancelled");
      std::atomic_store(&entry->scope, fresh); impl_->DropScopeReference(old); }
  } catch (...) {
    impl_->Terminal(*entry);
    if (retained) {
      Stop(fresh->gate, ReceiveStopMode::cancel);
      std::lock_guard<std::mutex> guard(impl_->registry); impl_->DropScopeReference(fresh);
    }
    throw;
  }
}
ReceiveReceipt ReceiveStore::Commit(const std::string& token, const std::string& scope_token) {
  const auto entry = impl_->Lookup(token); std::lock_guard<std::mutex> lock(entry->mutex);
  const auto scope = impl_->BoundScope(*entry, scope_token);
  if (GetState(entry->gate) == committed) return entry->receipt;
  bool publication = false;
  try {
    if (entry->offset != entry->size) Fail("invalid_range");
    const auto hash = impl_->WholeHash(*entry, *scope, entry->size);
    if (hash != entry->digest) Fail("integrity_mismatch");
    impl_->Hook(ReceiveIo::flush, *entry);
    { Impl::Permit permit(*impl_, *entry, *scope);
      if (!FlushFileBuffers(entry->file.value)) OsFailure(GetLastError()); }
    { Impl::Permit permit(*impl_, *entry, *scope);
      FILE_BASIC_INFO attrs{}; attrs.FileAttributes = FILE_ATTRIBUTE_NORMAL;
      if (!SetFileInformationByHandle(entry->file.value, FileBasicInfo, &attrs, sizeof(attrs))) OsFailure(GetLastError()); }
    impl_->Hook(ReceiveIo::before_publish, *entry);
    { Impl::Permit permit(*impl_, *entry, *scope);
      entry->directory->Verify(); impl_->CheckFile(*entry, entry->size); }
    impl_->Time(*scope);
    WinPublish(scope->gate);
    try { WinPublish(entry->gate); }
    catch (...) { SetState(scope->gate, cancelled); throw; }
    publication = true;
    impl_->Hook(ReceiveIo::publishing, *entry);
    // Publication won. Stop now reports committing, never cancelled. Every
    // collision rechecks the original deadline before another syscall.
    for (unsigned n = 0; n < 1000; ++n) {
      impl_->Time(*scope);
      entry->directory->Verify(); impl_->CheckFile(*entry, entry->size);
      const auto candidate = Numbered(entry->name, n);
      // Allocate receipt before rename; no throwing allocation follows success.
      ReceiveReceipt receipt{Utf8(candidate), entry->size, entry->digest};
      const auto error = impl_->native.Publish(entry->file.value, candidate);
      if (error == ERROR_SUCCESS) {
        entry->receipt = std::move(receipt);
        SetState(entry->gate, committed); SetState(scope->gate, committed);
        entry->file.Close(); impl_->Unreserve(*entry);
        return entry->receipt;
      }
      if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS) OsFailure(error);
    }
    Fail("name_exhausted");
  } catch (const ReceiveException& error) {
    if (GetState(entry->gate) == committed) throw;
    if (publication) { SetState(entry->gate, cancelled); SetState(scope->gate, cancelled); }
    else impl_->OnFailure(*entry, error);
    throw;
  } catch (...) {
    if (GetState(entry->gate) == committed) throw;
    if (publication) { SetState(entry->gate, cancelled); SetState(scope->gate, cancelled); }
    else impl_->Terminal(*entry);
    throw;
  }
}
void ReceiveStore::Abort(const std::string& token) {
  std::shared_ptr<Impl::Entry> entry;
  { std::lock_guard<std::mutex> lock(impl_->registry);
    const auto it = impl_->entries.find(token); if (it == impl_->entries.end()) return; entry = it->second; }
  const auto state = Stop(entry->gate, ReceiveStopMode::cancel);
  if (state != publishing && state != committed) Stop(std::atomic_load(&entry->scope)->gate, ReceiveStopMode::cancel);
}
void ReceiveStore::RetryCleanup(const std::string& token) {
  const auto entry = impl_->Lookup(token); std::lock_guard<std::mutex> lock(entry->mutex);
  const auto state = GetState(entry->gate);
  if (state == committed) return;
  const auto scope_state = GetState(std::atomic_load(&entry->scope)->gate);
  if (state != cancelled && scope_state != cancelled) Fail("invalid_range");
  impl_->Terminal(*entry); impl_->Cleanup(*entry);
}
void ReceiveStore::RetryPendingCleanup() {
  std::vector<std::pair<std::string, std::shared_ptr<Impl::Entry>>> pending;
  { std::lock_guard<std::mutex> lock(impl_->registry);
    for (const auto& pair : impl_->entries) {
      const auto state = GetState(pair.second->gate);
      if (state == cancelled || (state == active && GetState(std::atomic_load(&pair.second->scope)->gate) == cancelled))
        pending.push_back(pair);
    }
  }
  bool failed = false;
  for (const auto& pair : pending) {
    auto& entry = *pair.second;
    std::lock_guard<std::mutex> lock(entry.mutex);
    try {
      if (GetState(entry.gate) == committed || GetState(entry.gate) == publishing) continue;
      impl_->Terminal(entry); impl_->Cleanup(entry);
      if (!entry.exposed) {
        std::lock_guard<std::mutex> guard(impl_->registry);
        if (impl_->entries.erase(pair.first)) impl_->DropScopeReference(std::atomic_load(&entry.scope));
      }
    } catch (const ReceiveException&) { failed = true; }
  }
  if (failed) Fail("cleanup_failed");
}
void ReceiveStore::Release(const std::string& token) {
  std::shared_ptr<Impl::Entry> entry;
  { std::lock_guard<std::mutex> lock(impl_->registry);
    const auto it = impl_->entries.find(token); if (it == impl_->entries.end()) return; entry = it->second; }
  std::lock_guard<std::mutex> lock(entry->mutex);
  const auto state = GetState(entry->gate);
  if (state != committed && (state != cancelled || entry->file.valid())) Fail("invalid_range");
  std::lock_guard<std::mutex> guard(impl_->registry);
  if (impl_->entries.erase(token)) impl_->DropScopeReference(std::atomic_load(&entry->scope));
}
void ReceiveStore::Shutdown() {
  std::lock_guard<std::mutex> lock(impl_->registry);
  impl_->closed = true;
  for (auto& pair : impl_->entries) Stop(pair.second->gate, ReceiveStopMode::cancel);
  for (auto& pair : impl_->scopes) Stop(pair.second->gate, ReceiveStopMode::cancel);
  // Retain directories until worker release/destruction; Shutdown is gate-only.
}
}  // namespace share_hub
