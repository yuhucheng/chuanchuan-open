// Standalone API experiment. Do not wire this test fixture into the application.
#include <windows.h>
#include <winternl.h>
#include <bcrypt.h>
#include <sddl.h>
#include <aclapi.h>
#include <winioctl.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

extern "C" NTSYSAPI NTSTATUS NTAPI NtSetInformationFile(
    HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, FILE_INFORMATION_CLASS);

namespace {
namespace fs = std::filesystem;
void Check(bool ok, const char* why) {
  if (!ok) throw std::runtime_error(std::string(why) + " (Win32=" + std::to_string(GetLastError()) + ")");
}
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE h = INVALID_HANDLE_VALUE) : value(h) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(other.value) { other.value = INVALID_HANDLE_VALUE; }
  ~Handle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
  void Close() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); value = INVALID_HANDLE_VALUE; }
};
std::wstring RandomName() {
  std::array<UCHAR, 16> bytes{};
  Check(BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0, "CSPRNG");
  std::wstring result;
  for (auto b : bytes) { result += L"0123456789abcdef"[b >> 4]; result += L"0123456789abcdef"[b & 15]; }
  return result;
}
struct Fixture {
  fs::path root;
  std::set<fs::path> created;
  Fixture() {
    std::array<wchar_t, 32768> temp{};
    Check(GetTempPathW(static_cast<DWORD>(temp.size()), temp.data()) > 0, "GetTempPath");
    root = fs::path(temp.data()) / (L"receive-store-probe-" + RandomName());
    Check(CreateDirectoryW(root.c_str(), nullptr) != FALSE, "fixture directory");
    created.insert(root);
    static bool printed = false;
    if (!printed) {
      std::array<wchar_t, MAX_PATH> volume{}; std::array<wchar_t, 64> type{};
      Check(GetVolumePathNameW(root.c_str(), volume.data(), static_cast<DWORD>(volume.size())) &&
            GetVolumeInformationW(volume.data(), nullptr, 0, nullptr, nullptr, nullptr, type.data(), static_cast<DWORD>(type.size())), "filesystem identity");
      std::wcout << L"probe filesystem=" << type.data() << L'\n'; printed = true;
    }
  }
  void Track(const fs::path& p) {
    const auto relative = p.lexically_relative(root);
    Check(!relative.empty() && !relative.is_absolute() && *relative.begin() != L"..", "fixture path boundary");
    created.insert(p);
  }
  fs::path Dir(const wchar_t* name) {
    const auto path = root / name; Track(path);
    Check(CreateDirectoryW(path.c_str(), nullptr) != FALSE, "create fixture child"); return path;
  }
  ~Fixture() {
    // No recursive deletion: every path was explicitly registered under this root.
    std::vector<fs::path> paths(created.begin(), created.end());
    std::sort(paths.begin(), paths.end(), [](const auto& a, const auto& b) { return a.native().size() > b.native().size(); });
    for (const auto& p : paths) {
      SetFileAttributesW(p.c_str(), FILE_ATTRIBUTE_NORMAL);
      if (!DeleteFileW(p.c_str())) RemoveDirectoryW(p.c_str());
    }
  }
};
Handle OpenDirectory(const fs::path& path, DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE,
                     DWORD access = FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | FILE_TRAVERSE | SYNCHRONIZE) {
  Handle h(CreateFileW(path.c_str(), access, share, nullptr, OPEN_EXISTING,
                      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Check(h.value != INVALID_HANDLE_VALUE, "open directory");
  FILE_ATTRIBUTE_TAG_INFO info{};
  Check(GetFileInformationByHandleEx(h.value, FileAttributeTagInfo, &info, sizeof(info)) != FALSE, "directory attributes");
  Check((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
        (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0, "reject reparse directory");
  return h;
}
Handle RelativeOpen(HANDLE root, const std::wstring& name, ACCESS_MASK access, ULONG disposition,
                    ULONG options, ULONG sharing, DWORD* error = nullptr) {
  UNICODE_STRING text{};
  text.Buffer = const_cast<PWSTR>(name.data());
  text.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t)); text.MaximumLength = text.Length;
  OBJECT_ATTRIBUTES object{};
  object.Length = sizeof(object); object.RootDirectory = root; object.ObjectName = &text;
  object.Attributes = OBJ_CASE_INSENSITIVE;
  HANDLE result = INVALID_HANDLE_VALUE;
  IO_STATUS_BLOCK io{};
  const auto status = NtCreateFile(&result, access, &object, &io, nullptr, FILE_ATTRIBUTE_NORMAL,
                                  sharing, disposition, options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
                                  nullptr, 0);
  if (status < 0) {
    const auto code = RtlNtStatusToDosError(status); if (error) *error = code;
    SetLastError(code); return Handle();
  }
  if (error) *error = 0;
  return Handle(result);
}
Handle Temp(Fixture& fixture, const fs::path& directory, HANDLE directoryHandle,
            fs::path* path, const std::string& contents = "verified payload") {
  const auto name = L".receive-" + RandomName() + L".part";
  *path = directory / name; fixture.Track(*path);
  auto handle = RelativeOpen(directoryHandle, name, GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE,
                             FILE_CREATE, FILE_NON_DIRECTORY_FILE, FILE_SHARE_READ);
  Check(handle.value != INVALID_HANDLE_VALUE, "create temp relative to directory handle");
  DWORD written = 0;
  Check(WriteFile(handle.value, contents.data(), static_cast<DWORD>(contents.size()), &written, nullptr) && written == contents.size(), "write temporary contents");
  Check(FlushFileBuffers(handle.value) != FALSE, "flush temporary contents");
  return handle;
}
DWORD Rename(HANDLE source, HANDLE directory, const std::wstring& leaf, bool useWin32 = false) {
  static_assert(offsetof(FILE_RENAME_INFO, RootDirectory) == sizeof(void*));
  static_assert(offsetof(FILE_RENAME_INFO, FileNameLength) == sizeof(void*) * 2);
  const auto bytes = sizeof(FILE_RENAME_INFO) + leaf.size() * sizeof(wchar_t);
  std::vector<unsigned char> buffer(bytes, 0);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
  info->ReplaceIfExists = FALSE; info->RootDirectory = directory;
  info->FileNameLength = static_cast<DWORD>(leaf.size() * sizeof(wchar_t));
  std::memcpy(info->FileName, leaf.data(), info->FileNameLength);
  if (useWin32) {
    if (SetFileInformationByHandle(source, FileRenameInfo, info, static_cast<DWORD>(bytes))) return ERROR_SUCCESS;
    return GetLastError();
  }
  IO_STATUS_BLOCK io{};
  const auto status = NtSetInformationFile(source, &io, info, static_cast<ULONG>(bytes), static_cast<FILE_INFORMATION_CLASS>(10));
  return status >= 0 ? 0 : RtlNtStatusToDosError(status);
}
std::string Read(const fs::path& path) {
  Handle handle(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Check(handle.value != INVALID_HANDLE_VALUE, "read final file");
  LARGE_INTEGER length{}; Check(GetFileSizeEx(handle.value, &length) != FALSE, "read file length");
  std::string data(static_cast<size_t>(length.QuadPart), '\0'); DWORD count = 0;
  Check(ReadFile(handle.value, data.data(), static_cast<DWORD>(data.size()), &count, nullptr) && count == data.size(), "read file bytes");
  return data;
}
std::array<UCHAR, 32> Sha256(HANDLE file) {
  LARGE_INTEGER zero{}; Check(SetFilePointerEx(file, zero, nullptr, FILE_BEGIN) != FALSE, "rewind whole handle");
  BCRYPT_ALG_HANDLE provider = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
  Check(BCryptOpenAlgorithmProvider(&provider, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0, "SHA provider");
  Check(BCryptCreateHash(provider, &hash, nullptr, 0, nullptr, 0, 0) == 0, "SHA state");
  std::array<UCHAR, 262144> buffer{};
  while (true) {
    DWORD count = 0; Check(ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) != FALSE, "whole handle read");
    if (count == 0) break;
    Check(BCryptHashData(hash, buffer.data(), count, 0) == 0, "whole handle SHA update");
  }
  std::array<UCHAR, 32> digest{};
  Check(BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) == 0, "SHA finish");
  BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(provider, 0); return digest;
}
FILE_ID_INFO Identity(HANDLE file) {
  FILE_ID_INFO identity{};
  Check(GetFileInformationByHandleEx(file, FileIdInfo, &identity, sizeof(identity)) != FALSE, "stable native file identity");
  return identity;
}
bool SameIdentity(const FILE_ID_INFO& a, const FILE_ID_INFO& b) {
  return a.VolumeSerialNumber == b.VolumeSerialNumber &&
         std::memcmp(a.FileId.Identifier, b.FileId.Identifier, sizeof(a.FileId.Identifier)) == 0;
}
bool SafeLeaf(const std::wstring& name) {
  if (name.empty() || name.size() > 230 || name.back() == L'.' || name.back() == L' ') return false;
  for (size_t i = 0; i < name.size(); ++i) {
    const auto c = name[i];
    if (c < 32 || std::wstring(L"<>:\"/\\|?*").find(c) != std::wstring::npos) return false;
    if (c >= 0xd800 && c <= 0xdbff) { if (++i == name.size() || name[i] < 0xdc00 || name[i] > 0xdfff) return false; }
    else if (c >= 0xdc00 && c <= 0xdfff) return false;
  }
  auto stem = name.substr(0, name.find(L'.'));
  std::transform(stem.begin(), stem.end(), stem.begin(), [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
  while (!stem.empty() && stem.back() == L' ') stem.pop_back();
  if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL" || stem == L"CONIN$" || stem == L"CONOUT$") return false;
  if (stem.size() == 4 && (stem.substr(0, 3) == L"COM" || stem.substr(0, 3) == L"LPT")) {
    const auto c = stem[3]; if ((c >= L'0' && c <= L'9') || c == 0x00b9 || c == 0x00b2 || c == 0x00b3) return false;
  }
  return true;
}
std::wstring Numbered(const std::wstring& name, unsigned int n) {
  if (n == 0) return name;
  const auto dot = name.find_last_of(L'.');
  const auto split = dot == std::wstring::npos || dot == 0 ? name.size() : dot;
  return name.substr(0, split) + L" (" + std::to_wstring(n) + L")" + name.substr(split);
}
DWORD PublishNumbered(HANDLE file, HANDLE directory, const std::wstring& name, std::wstring* actual, unsigned int attempts = 1000) {
  if (!SafeLeaf(name)) return ERROR_INVALID_NAME;
  for (unsigned int n = 0; n < attempts; ++n) {
    auto candidate = Numbered(name, n); const auto code = Rename(file, directory, candidate);
    if (code == 0) { *actual = candidate; return 0; }
    if (code != ERROR_ALREADY_EXISTS && code != ERROR_FILE_EXISTS) return code;
  }
  return ERROR_FILE_EXISTS;
}
void RelativeRename() {
  Fixture f; auto directory = f.Dir(L"target"); auto decoy = f.Dir(L"decoy"); auto h = OpenDirectory(directory);
  auto staging = directory / L"owned-stage"; f.Track(staging);
  auto stage = RelativeOpen(h.value, L"owned-stage", FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | FILE_TRAVERSE | SYNCHRONIZE,
                             FILE_CREATE, FILE_DIRECTORY_FILE, FILE_SHARE_READ | FILE_SHARE_WRITE);
  Check(stage.value != INVALID_HANDLE_VALUE, "create same-filesystem stage relative to authorized directory");
  fs::path source; auto file = Temp(f, staging, stage.value, &source, "abc");
  const auto originalIdentity = Identity(file.value);
  const std::array<UCHAR, 32> abc = {0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
  Check(Sha256(file.value) == abc, "whole handle SHA-256 known vector");
  Check(FlushFileBuffers(file.value) != FALSE, "flush after validation");
  const auto oldCwd = fs::current_path(); fs::current_path(decoy);
  const auto win32 = Rename(file.value, h.value, L"win32.txt", true);
  std::cout << "Win32 RootDirectory relative rename error=" << win32 << '\n';
  if (win32 == 0) f.Track(directory / L"win32.txt");
  const auto error = Rename(file.value, h.value, L"final.txt"); fs::current_path(oldCwd);
  std::cout << "Nt RootDirectory relative rename error=" << error << '\n'; Check(error == 0, "native RootDirectory supported");
  f.Track(directory / L"final.txt");
  Check(SameIdentity(originalIdentity, Identity(file.value)), "rename retained verified source identity");
  Check(!fs::exists(source) && !fs::exists(decoy / L"final.txt"), "rename consumed source, ignored current directory");
  Check(Read(directory / L"final.txt") == "abc", "complete final payload");
}
void ExistingAndConcurrent(bool sourceParent = false) {
  Fixture f; auto directory = f.Dir(L"target"); auto h = OpenDirectory(directory, sourceParent ? FILE_SHARE_READ : FILE_SHARE_READ | FILE_SHARE_WRITE);
  const auto publishRoot = sourceParent ? nullptr : h.value;
  fs::path firstPath; auto first = Temp(f, directory, h.value, &firstPath, "existing");
  Check(Rename(first.value, publishRoot, L"report.txt") == 0, "seed destination"); f.Track(directory / L"report.txt"); first.Close();
  fs::path nextPath; auto next = Temp(f, directory, h.value, &nextPath, "incoming");
  const auto conflict = Rename(next.value, publishRoot, L"report.txt");
  std::cout << "existing destination rename error=" << conflict << '\n';
  Check(conflict == ERROR_ALREADY_EXISTS || conflict == ERROR_FILE_EXISTS, "existing destination conflict");
  Check(Read(directory / L"report.txt") == "existing" && fs::exists(nextPath), "collision preserves both payloads");
  std::wstring selected; Check(PublishNumbered(next.value, publishRoot, L"report.txt", &selected) == 0 && selected == L"report (1).txt", "bounded numbered publish"); f.Track(directory / selected);
  next.Close();
  // Handle is deliberately nonassignable: retain concurrent sources in a vector.
  std::vector<Handle> sources; std::vector<fs::path> paths;
  for (int i = 0; i < 12; ++i) { fs::path p; sources.push_back(Temp(f, directory, h.value, &p, std::to_string(i))); paths.push_back(p); }
  std::atomic<bool> start{false}; std::array<DWORD, 12> results{}; std::array<std::wstring, 12> names{}; std::vector<std::thread> workers;
  for (size_t i = 0; i < sources.size(); ++i) workers.emplace_back([&, i] { while (!start.load()) std::this_thread::yield(); results[i] = PublishNumbered(sources[i].value, publishRoot, L"same.txt", &names[i]); });
  start = true; for (auto& worker : workers) worker.join();
  std::set<std::wstring> unique;
  for (size_t i = 0; i < sources.size(); ++i) { Check(results[i] == 0, "concurrent rename succeeds with numbering"); f.Track(directory / names[i]); unique.insert(names[i]); Check(Read(directory / names[i]) == std::to_string(i), "each concurrent payload preserved"); }
  Check(unique.size() == sources.size(), "concurrent names unique");
  fs::path limitPath; auto limit = Temp(f, directory, h.value, &limitPath);
  Check(PublishNumbered(limit.value, publishRoot, L"same.txt", &selected, 1) == ERROR_FILE_EXISTS && fs::exists(limitPath), "bounded collision exhaustion");
  const auto caseConflict = Rename(limit.value, publishRoot, L"REPORT.TXT");
  std::cout << "case-fold collision error=" << caseConflict << '\n';
  Check(caseConflict == ERROR_ALREADY_EXISTS || caseConflict == ERROR_FILE_EXISTS, "case-fold collision preserves existing file");
  std::cout << "concurrent publishes=" << unique.size() << " distinct intact files\n";
}
void DirectoryBindingAndLocks() {
  Fixture f; const auto original = f.Dir(L"original"); const auto moved = f.root / L"moved";
  auto root = OpenDirectory(original, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
  const auto beforeMove = Identity(root.value);
  Check(MoveFileExW(original.c_str(), moved.c_str(), 0) != FALSE, "move directory while allowing deletion sharing");
  f.Track(moved);
  Check(CreateDirectoryW(original.c_str(), nullptr) != FALSE, "replace old path with new directory");
  Check(SameIdentity(beforeMove, Identity(root.value)), "moved directory handle retains identity");
  auto replacement = OpenDirectory(original);
  Check(!SameIdentity(beforeMove, Identity(replacement.value)), "replacement directory has distinct identity");
  fs::path tempPath; auto file = Temp(f, moved, root.value, &tempPath, "bound");
  const auto result = Rename(file.value, root.value, L"bound.txt");
  std::cout << "moved directory handle rename error=" << result << '\n'; Check(result == 0, "root handle survives directory rename");
  f.Track(moved / L"bound.txt"); Check(Read(moved / L"bound.txt") == "bound" && !fs::exists(original / L"bound.txt"), "handle does not rebind to replacement path");
  auto locked = f.Dir(L"locked"); auto lock = OpenDirectory(locked, FILE_SHARE_READ);
  const auto changed = f.root / L"forbidden"; f.Track(changed);
  SetLastError(0); const auto renameResult = MoveFileExW(locked.c_str(), changed.c_str(), 0); const auto code = GetLastError();
  std::cout << "locked directory external move error=" << code << '\n';
  Check(!renameResult && code == ERROR_SHARING_VIOLATION, "no-delete-sharing prevents directory substitution");
  Handle writable(CreateFileW(locked.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  const auto writeError = GetLastError(); std::cout << "locked directory external write-open error=" << writeError << '\n';
  Check(writable.value == INVALID_HANDLE_VALUE && writeError == ERROR_SHARING_VIOLATION, "no-write-sharing prevents reparse mutation handles");
  fs::path directPath; auto direct = Temp(f, locked, lock.value, &directPath, "same-parent");
  const auto sameParentResult = Rename(direct.value, nullptr, L"direct-final.txt");
  std::cout << "no-write-sharing source-parent-only native rename error=" << sameParentResult << '\n';
  Check(sameParentResult == 0, "source-parent-only rename supports strict target lock");
  f.Track(locked / L"direct-final.txt"); Check(Read(locked / L"direct-final.txt") == "same-parent", "source-parent-only publish retained payload");
}
DWORD SetJunction(const fs::path& path, const fs::path& target) {
  Handle handle(CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (handle.value == INVALID_HANDLE_VALUE) return GetLastError();
  struct JunctionBuffer { DWORD tag; WORD dataLength; WORD reserved; WORD substituteOffset; WORD substituteLength; WORD printOffset; WORD printLength; wchar_t path[1]; };
  const auto substitute = L"\\??\\" + target.native();
  const auto print = target.native();
  const auto bytes = offsetof(JunctionBuffer, path) + (substitute.size() + print.size() + 2) * sizeof(wchar_t);
  std::vector<unsigned char> buffer(bytes, 0); auto* data = reinterpret_cast<JunctionBuffer*>(buffer.data());
  data->tag = IO_REPARSE_TAG_MOUNT_POINT; data->dataLength = static_cast<WORD>(bytes - 8);
  data->substituteLength = static_cast<WORD>(substitute.size() * sizeof(wchar_t));
  data->printOffset = static_cast<WORD>((substitute.size() + 1) * sizeof(wchar_t));
  data->printLength = static_cast<WORD>(print.size() * sizeof(wchar_t));
  std::memcpy(data->path, substitute.data(), data->substituteLength);
  std::memcpy(reinterpret_cast<unsigned char*>(data->path) + data->printOffset, print.data(), data->printLength);
  DWORD returned = 0;
  if (DeviceIoControl(handle.value, FSCTL_SET_REPARSE_POINT, buffer.data(), static_cast<DWORD>(bytes), nullptr, 0, &returned, nullptr)) return 0;
  return GetLastError();
}
void ReparseAndAncestorBoundary() {
  Fixture f; auto parentPath = f.Dir(L"parent"); auto outsidePath = f.Dir(L"outside");
  auto parent = OpenDirectory(parentPath); auto link = parentPath / L"junction";
  f.Track(link); Check(CreateDirectoryW(link.c_str(), nullptr) != FALSE, "create empty junction fixture");
  Check(SetJunction(link, outsidePath) == 0, "create actual mountpoint reparse fixture");
  auto raw = RelativeOpen(parent.value, L"junction", FILE_READ_ATTRIBUTES | FILE_TRAVERSE | SYNCHRONIZE,
                           FILE_OPEN, FILE_DIRECTORY_FILE, FILE_SHARE_READ | FILE_SHARE_WRITE);
  Check(raw.value != INVALID_HANDLE_VALUE, "open reparse object without traversing");
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  Check(GetFileInformationByHandleEx(raw.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) &&
        (attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT), "native relative no-follow exposes reparse for rejection");
  bool rejected = false; try { auto blocked = OpenDirectory(link); } catch (const std::exception&) { rejected = true; }
  Check(rejected, "picker/walker rejects actual junction");
  raw.Close();
  // One handle is retained for each ancestor while walking. Replacement fails.
  const auto renamed = f.root / L"parent-replaced"; f.Track(renamed);
  SetLastError(0); const auto moved = MoveFileExW(parentPath.c_str(), renamed.c_str(), 0); const auto moveError = GetLastError();
  std::cout << "held ancestor rename error=" << moveError << '\n';
  Check(!moved && moveError == ERROR_SHARING_VIOLATION, "held ancestor cannot be renamed");
  auto destination = f.Dir(L"destination"); auto dest = OpenDirectory(destination);
  auto staging = destination / L"owned-staging"; f.Track(staging);
  Check(CreateDirectoryW(staging.c_str(), nullptr) != FALSE, "own staging keeps destination nonempty");
  const auto reparseError = SetJunction(destination, outsidePath);
  std::cout << "nonempty bound destination mountpoint mutation error=" << reparseError << '\n';
  Check(reparseError != 0, "nonempty bound destination rejects mountpoint conversion");
  Check(GetFileInformationByHandleEx(dest.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) &&
        !(attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT), "bound directory remains nonreparse");
  Check(fs::is_empty(outsidePath), "no data reached reparse target");
}
void NoFinalPlaceholder(bool sourceParent = false) {
  Fixture f; auto directory = f.Dir(L"target"); auto root = OpenDirectory(directory, sourceParent ? FILE_SHARE_READ : FILE_SHARE_READ | FILE_SHARE_WRITE);
  std::string data(1024 * 1024, 'p'); fs::path tempPath; auto file = Temp(f, directory, root.value, &tempPath, data);
  auto finalPath = directory / L"large.bin"; f.Track(finalPath);
  Check(!fs::exists(finalPath), "no placeholder exists before commit");
  std::atomic<bool> stop{false}; std::atomic<bool> partial{false}; std::atomic<unsigned int> observations{0};
  std::thread observer([&] { while (!stop) { WIN32_FILE_ATTRIBUTE_DATA info{}; if (GetFileAttributesExW(finalPath.c_str(), GetFileExInfoStandard, &info)) { ++observations; if (info.nFileSizeHigh || info.nFileSizeLow != data.size()) partial = true; } } });
  // Model the full validation read before publication; the abc test checks the
  // digest implementation against the standard SHA-256 vector.
  static_cast<void>(Sha256(file.value));
  const auto result = Rename(file.value, sourceParent ? nullptr : root.value, L"large.bin");
  for (unsigned int i = 0; i < 1000; ++i) std::this_thread::yield(); stop = true; observer.join();
  Check(result == 0 && !partial && Read(finalPath) == data, "observed final absent or full size, full payload after rename");
  std::cout << "published full-size observations=" << observations << " zero/partial observations=" << partial << '\n';
}
void SafeNames() {
  for (const auto* name : {L"", L".", L"..", L"../outside", L"x\\y", L"C:\\x", L"x:stream", L"\\\\server\\share", L"NUL.txt", L"con", L"COM1.bin", L"LPT\u00b9.log", L"CON .txt", L"trailing.", L"trailing ", L"a?b"}) Check(!SafeLeaf(name), "reject unsafe filename");
  Check(!SafeLeaf(std::wstring(L"nul\0tail", 8)), "reject embedded NUL");
  for (const auto* name : {L"report.txt", L"\u4e32\u4e32.txt", L"r\u00e9sum\u00e9.txt", L".gitignore", L"emoji\xd83d\xde00.txt"}) Check(SafeLeaf(name), "accept ordinary safe filename");
  Check(Numbered(L".gitignore", 3) == L".gitignore (3)", "dotfile suffix");
  Fixture f; auto directory = f.Dir(L"target"); auto root = OpenDirectory(directory); fs::path p; auto file = Temp(f, directory, root.value, &p);
  std::wstring actual;
  Check(PublishNumbered(file.value, root.value, L"../escape", &actual) == ERROR_INVALID_NAME && fs::exists(p), "boundary validation precedes any native rename");
}
void CleanupRetryAndAccessErrors() {
  Fixture f; auto directory = f.Dir(L"target"); auto root = OpenDirectory(directory); fs::path p; auto file = Temp(f, directory, root.value, &p);
  FILE_BASIC_INFO attributes{}; attributes.FileAttributes = FILE_ATTRIBUTE_READONLY;
  Check(SetFileInformationByHandle(file.value, FileBasicInfo, &attributes, sizeof(attributes)) != FALSE, "make own temp read-only for cleanup failure");
  FILE_DISPOSITION_INFO remove{TRUE};
  SetLastError(0); const auto first = SetFileInformationByHandle(file.value, FileDispositionInfo, &remove, sizeof(remove)); const auto firstError = GetLastError();
  std::cout << "read-only temp disposition error=" << firstError << '\n'; Check(!first && firstError == ERROR_ACCESS_DENIED, "cleanup denied remains retryable");
  attributes.FileAttributes = FILE_ATTRIBUTE_NORMAL;
  Check(SetFileInformationByHandle(file.value, FileBasicInfo, &attributes, sizeof(attributes)) != FALSE, "clear own temporary read-only attribute");
  Check(SetFileInformationByHandle(file.value, FileDispositionInfo, &remove, sizeof(remove)) != FALSE, "retry cleanup through original handle");
  file.Close(); Check(!fs::exists(p), "retry deleted owned temporary file");
  fs::path noDelete = directory / L"no-delete.part"; f.Track(noDelete);
  auto limited = RelativeOpen(root.value, noDelete.filename().native(), GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE, FILE_CREATE, FILE_NON_DIRECTORY_FILE, FILE_SHARE_READ);
  Check(limited.value != INVALID_HANDLE_VALUE, "create limited-access source");
  const auto denied = Rename(limited.value, root.value, L"never.txt");
  std::cout << "source without DELETE access rename error=" << denied << '\n'; Check(denied == ERROR_ACCESS_DENIED && !fs::exists(directory / L"never.txt"), "access denied is not collision");
}
void CancelCommitBoundary() {
  Fixture f; auto directory = f.Dir(L"target"); auto root = OpenDirectory(directory, FILE_SHARE_READ); fs::path p; auto file = Temp(f, directory, root.value, &p);
  enum class Phase { active, cancelled, committed }; Phase phase = Phase::active; std::mutex gate;
  auto cancel = [&] { std::lock_guard<std::mutex> guard(gate); if (phase == Phase::active) phase = Phase::cancelled; };
  auto commit = [&](const wchar_t* name) { std::lock_guard<std::mutex> guard(gate); if (phase != Phase::active) return false; if (Rename(file.value, nullptr, name) != 0) return false; phase = Phase::committed; f.Track(directory / name); return true; };
  cancel(); Check(!commit(L"cancelled.txt") && !fs::exists(directory / L"cancelled.txt"), "cancel before gate prevents publication");
  phase = Phase::active; Check(commit(L"committed.txt"), "commit acquired gate"); cancel();
  Check(phase == Phase::committed && Read(directory / L"committed.txt") == "verified payload", "cancel after successful rename preserves final file");
  ULONGLONG time = 0; QueryInterruptTimePrecise(&time); Check(time > 0, "correct continuous clock ABI");
  std::cout << "correct QueryInterruptTimePrecise output nonzero=yes\n";
}
}  // namespace

int main() {
  int failed = 0;
  for (const auto& test : std::vector<std::pair<const char*, std::function<void()>>>{
         {"relative handle rename and SHA", RelativeRename}, {"existing and concurrent names", [] { ExistingAndConcurrent(); }},
         {"strict source-parent concurrent names", [] { ExistingAndConcurrent(true); }},
         {"directory identity and locks", DirectoryBindingAndLocks}, {"reparse and ancestor boundary", ReparseAndAncestorBoundary}, {"no final placeholder", [] { NoFinalPlaceholder(); }},
         {"strict source-parent no placeholder", [] { NoFinalPlaceholder(true); }},
         {"safe single-component names", SafeNames}, {"cleanup retry and access errors", CleanupRetryAndAccessErrors},
         {"cancel commit boundary", CancelCommitBoundary}}) {
    try { test.second(); std::cout << "PASS " << test.first << '\n'; }
    catch (const std::exception& e) { ++failed; std::cout << "FAIL " << test.first << ": " << e.what() << '\n'; }
  }
  std::cout << "RESULT tests=10 failed=" << failed << '\n'; return failed ? 1 : 0;
}
