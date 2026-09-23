#include "receive_store.h"
#include <windows.h>
#include <bcrypt.h>
#include <aclapi.h>
#include <winioctl.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

using namespace share_hub;
namespace fs = std::filesystem;
namespace {
void Check(bool condition, const char* text) {
  if (!condition) throw std::runtime_error(text);
}
template <typename F> void Reject(F f, const char* code) {
  try { f(); } catch (const ReceiveException& e) {
    if (e.code() == code) return;
    throw std::runtime_error(std::string("expected ") + code + ", got " + e.code());
  }
  throw std::runtime_error(std::string("expected rejection: ") + code);
}
std::string Digest(const std::string& text) {
  std::array<UCHAR, 32> hash{};
  Check(BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
    reinterpret_cast<PUCHAR>(const_cast<char*>(text.data())),
    static_cast<ULONG>(text.size()), hash.data(), static_cast<ULONG>(hash.size())) == 0, "fixture digest");
  std::string result;
  for (auto b : hash) { result += "0123456789abcdef"[b >> 4]; result += "0123456789abcdef"[b & 15]; }
  return result;
}
struct Fixture {
  fs::path root;
  std::set<fs::path> owned;
  Fixture() {
    wchar_t temp[32768]{};
    Check(GetTempPathW(32768, temp) != 0, "temp root");
    std::array<UCHAR, 16> nonce{};
    Check(BCryptGenRandom(nullptr, nonce.data(), 16, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0, "nonce");
    std::wstring name = L"receive-store-test-";
    for (auto b : nonce) { name += L"0123456789abcdef"[b >> 4]; name += L"0123456789abcdef"[b & 15]; }
    root = fs::path(temp) / name;
    Check(CreateDirectoryW(root.c_str(), nullptr) != 0, "fixture create");
    owned.insert(root);
  }
  fs::path Path(const std::wstring& name) {
    auto p = root / name;
    Check(p.parent_path() == root, "fixture path boundary");
    owned.insert(p); return p;
  }
  ~Fixture() {
    // Only exact fixture-owned paths; never recursive or wildcard deletion.
    std::vector<fs::path> paths(owned.begin(), owned.end());
    std::sort(paths.begin(), paths.end(), [](const auto& a, const auto& b) { return a.native().size() > b.native().size(); });
    for (const auto& p : paths) {
      const auto extended = L"\\\\?\\" + p.native();
      SetFileAttributesW(extended.c_str(), FILE_ATTRIBUTE_NORMAL);
      if (!DeleteFileW(extended.c_str())) RemoveDirectoryW(extended.c_str());
    }
  }
};
std::string Read(const fs::path& path) {
  std::ifstream f(path, std::ios::binary);
  Check(f.is_open(), "open receipt file");
  return {std::istreambuf_iterator<char>(f), {}};
}
void Write(const fs::path& path, const std::string& contents) {
  std::ofstream f(path, std::ios::binary); f << contents;
  Check(f.good(), "write fixture");
}
struct Context {
  std::atomic<uint64_t> now{100};
  ReceiveStore store;
  ReceiveDirectory directory;
  explicit Context(Fixture& f, ReceiveStoreOptions options = {})
    : store([&] { options.clock = [&](uint64_t* out) { *out = now.load(); return *out != 0; }; return options; }()),
      directory(store.DirectoryFromPicker(f.root.native())) {}
  std::string Scope(const std::string& key = "grant|peer|file", int64_t deadline = 10000) {
    return store.ScopeOpen(key, deadline);
  }
};
std::vector<uint8_t> Bytes(const std::string& text) { return {text.begin(), text.end()}; }
void SuccessAndCollisions() {
  Fixture f; Context c(f);
  for (const std::string contents : {std::string(), std::string(100123, 'z')}) {
    const auto scope = c.Scope();
    const auto token = c.store.Begin(c.directory.token, scope, "file.txt", static_cast<int64_t>(contents.size()), Digest(contents));
    Check(!fs::exists(f.root / "file.txt") || contents.size() > 0, "no final placeholder");
    int64_t offset = 0;
    while (offset < static_cast<int64_t>(contents.size())) {
      auto block = contents.substr(static_cast<size_t>(offset), 32768);
      offset = c.store.Append(token, scope, offset, Bytes(block));
    }
    const auto receipt = c.store.Commit(token, scope);
    auto path = f.Path(contents.empty() ? L"file.txt" : L"file (1).txt");
    Check(receipt.name == path.filename().string() && Read(path) == contents && receipt.sha256 == Digest(contents), "authoritative intact receipt");
    c.store.Abort(token); c.store.Release(token); c.store.ScopeClose(scope);
    Check(fs::exists(path), "committed survives abort/release");
  }
}
void NamesAndRanges() {
  Fixture f; Context c(f);
  const std::vector<std::string> unsafe = {"", "../escape", "a/b", "a\\b", "x:y", "CON", "aux.txt", "COM1.log", "lpt9", "CONIN$", "trail.", "trail ", "a?b", std::string("a\0b", 3), "\xc0\xaf", std::string(256, 'x'), "\x7f"};
  for (const auto& name : unsafe) {
    auto scope = c.Scope();
    Reject([&] { c.store.Begin(c.directory.token, scope, name, 0, Digest("")); }, "invalid_name");
    c.store.ScopeClose(scope);
  }
  auto scope = c.Scope();
  Reject([&] { c.store.Begin(c.directory.token, scope, "x", -1, Digest("")); }, "invalid_range");
  Reject([&] { c.store.Begin(c.directory.token, scope, "x", 1, "bad"); }, "integrity_mismatch");
  auto token = c.store.Begin(c.directory.token, scope, "x", 1, Digest("x"));
  auto other = c.Scope("different");
  Reject([&] { c.store.Append(token, other, 0, Bytes("x")); }, "stale_scope");
  Reject([&] { c.store.Append(token, scope, 1, Bytes("x")); }, "invalid_range");
  Reject([&] { c.store.Append(token, scope, 0, Bytes("x")); }, "cancelled");
  c.store.RetryCleanup(token); c.store.Release(token);
  for (const auto& block : {Bytes(""), Bytes("xx"), std::vector<uint8_t>(32769, 'x')}) {
    auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "x", 1, Digest("x"));
    Reject([&] { c.store.Append(t, s, 0, block); }, "invalid_range");
  }
}
void PauseResume() {
  Fixture f; Context c(f);
  auto scope = c.Scope();
  auto token = c.store.Begin(c.directory.token, scope, "resume", 6, Digest("abcdef"));
  c.store.Append(token, scope, 0, Bytes("abc"));
  Check(c.store.ScopeStop(scope, ReceiveStopMode::pause) == "paused", "pause wins");
  const auto cp = c.store.Checkpoint(token);
  Check(cp.offset == 3 && cp.sha256 == Digest("abc") && !cp.identity.empty(), "prefix checkpoint");
  Reject([&] { c.store.Append(token, scope, 3, Bytes("def")); }, "paused");
  const auto fresh = c.Scope();
  c.store.Resume(token, fresh, cp);
  Check(c.store.ScopeStop(scope, ReceiveStopMode::cancel) == "cancelled", "superseded stop is detached");
  c.store.ScopeClose(scope);
  c.store.Append(token, fresh, 3, Bytes("def"));
  auto receipt = c.store.Commit(token, fresh);
  Check(receipt.name == "resume" && Read(f.Path(L"resume")) == "abcdef", "resumed receipt");
  Check(c.store.ScopeStop(fresh, ReceiveStopMode::cancel) == "committed", "committed status");
}
void ResumeRejects() {
  for (int scenario = 0; scenario < 7; ++scenario) {
    Fixture f;
    uintptr_t handle = 0;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t file, size_t) {
      if (op == ReceiveIo::write) handle = file;
      return ReceiveIoDirective{};
    };
    Context c(f, options);
    auto scope = c.Scope(); auto token = c.store.Begin(c.directory.token, scope, "resume", 6, Digest("abcdef"));
    c.store.Append(token, scope, 0, Bytes("abc")); c.store.ScopeStop(scope, ReceiveStopMode::pause);
    auto cp = c.store.Checkpoint(token);
    if (scenario < 2) {
      LARGE_INTEGER pos{}; pos.QuadPart = scenario == 0 ? 0 : 3;
      Check(SetFilePointerEx(reinterpret_cast<HANDLE>(handle), pos, nullptr, FILE_BEGIN) != 0, "mutate position");
      DWORD written = 0; Check(WriteFile(reinterpret_cast<HANDLE>(handle), "z", 1, &written, nullptr) != 0, "mutate original file");
    }
    if (scenario == 2) cp.sha256 = Digest("wrong");
    if (scenario == 5) ++cp.offset;
    if (scenario == 6) cp.identity = "stale-object";
    auto fresh = c.Scope(scenario == 3 ? "other" : "grant|peer|file", scenario == 4 ? 20000 : 10000);
    Reject([&] { c.store.Resume(token, fresh, cp); }, (scenario == 3 || scenario == 4) ? "stale_scope" : (scenario == 1 ? "source_changed" : "integrity_mismatch"));
    Reject([&] { c.store.Append(token, fresh, 3, Bytes("def")); }, "cancelled");
    Check(!fs::exists(f.root / "resume"), "resume mismatch never publishes");
  }
}
void ClockAndLimits() {
  Fixture f; Context c(f);
  Reject([&] { c.Scope("", 10000); }, "stale_scope");
  Reject([&] { c.Scope(std::string(257, 'k')); }, "stale_scope");
  Reject([&] { c.Scope("key", 100); }, "expired");
  for (int scenario = 0; scenario < 3; ++scenario) {
    c.now = 100;
    auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "clock", 1, Digest("x"));
    c.now = scenario == 0 ? 10000 : (scenario == 1 ? 99 : 0);
    Reject([&] { c.store.Append(t, s, 0, Bytes("x")); }, scenario == 0 ? "expired" : "clock_unavailable");
    c.now = 100; c.store.ScopeClose(s); c.store.RetryCleanup(t); c.store.Release(t);
  }
  std::vector<std::string> scopes;
  for (int n = 0; n < 64; ++n) scopes.push_back(c.Scope());
  Reject([&] { c.Scope(); }, "resource_limit");
  for (const auto& s : scopes) c.store.ScopeClose(s);
  auto s = c.Scope(); c.store.ScopeClose(s);
  ReceiveStoreOptions options; options.maximum_reserved_bytes = 2;
  Context budget(f, options);
  s = budget.Scope();
  Reject([&] { budget.store.Begin(budget.directory.token, s, "oversize", 3, Digest("abc")); }, "resource_limit");
}
void IntegrityAndIoFailures() {
  for (int scenario = 0; scenario < 6; ++scenario) {
    Fixture f; int writes = 0;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t, size_t) {
      ReceiveIoDirective result;
      if (op == ReceiveIo::write) {
        ++writes; result.maximum_bytes = 1;
        if (scenario == 0 && writes == 2) result.error = ERROR_DISK_FULL;
      }
      if (op == ReceiveIo::read) {
        result.maximum_bytes = 1;
        if (scenario == 1) result.error = ERROR_READ_FAULT;
        if (scenario == 2) result.maximum_bytes = 0;
      }
      if (scenario == 3 && op == ReceiveIo::flush) result.error = ERROR_ACCESS_DENIED;
      return result;
    };
    Context c(f, options);
    auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "data", 3, Digest(scenario == 4 ? "xyz" : "abc"));
    if (scenario == 0) {
      Reject([&] { c.store.Append(t, s, 0, Bytes("abc")); }, "disk_full");
      Check(c.store.Checkpoint(t).offset == 1, "partial failure retains exact prefix");
    } else {
      Check(c.store.Append(t, s, 0, Bytes("abc")) == 3 && writes == 3, "partial write loop");
      if (scenario == 5) {
        auto receipt = c.store.Commit(t, s);
        Check(Read(f.Path(L"data")) == "abc" && receipt.sha256 == Digest("abc"), "partial reads complete hash");
      } else {
        Reject([&] { c.store.Commit(t, s); }, scenario < 3 ? "io_failure" : scenario == 3 ? "permission_denied" : "integrity_mismatch");
      }
    }
    if (scenario != 5) Check(!fs::exists(f.root / "data"), "failure has no final name");
  }
}
struct Barrier {
  std::mutex mutex; std::condition_variable changed; bool entered = false; bool released = false;
  void Block() { std::unique_lock<std::mutex> lock(mutex); entered = true; changed.notify_all(); changed.wait(lock, [&] { return released; }); }
  void Wait() { std::unique_lock<std::mutex> lock(mutex); changed.wait(lock, [&] { return entered; }); }
  void Release() { std::lock_guard<std::mutex> lock(mutex); released = true; changed.notify_all(); }
};
void StopRaces() {
  for (bool commit_wins : {false, true}) {
    Fixture f; Barrier barrier;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t, size_t) {
      if (op == (commit_wins ? ReceiveIo::publishing : ReceiveIo::before_publish)) barrier.Block();
      return ReceiveIoDirective{};
    };
    Context c(f, options); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "race", 3, Digest("abc"));
    c.store.Append(t, s, 0, Bytes("abc"));
    std::string result;
    std::thread worker([&] {
      try { result = c.store.Commit(t, s).name; }
      catch (const ReceiveException& e) { result = e.code(); }
    });
    barrier.Wait();
    const auto stopped = c.store.ScopeStop(s, ReceiveStopMode::cancel);
    barrier.Release(); worker.join();
    Check(stopped == (commit_wins ? "committing" : "cancelled"), "stop linearization result");
    Check(result == (commit_wins ? "race" : "cancelled"), "commit linearization result");
    if (commit_wins) Check(Read(f.Path(L"race")) == "abc", "commit winner preserved");
    else Check(!fs::exists(f.root / "race"), "cancel winner no publish");
  }
}
void CleanupAndShutdown() {
  Fixture f; bool fail_cleanup = true; int read_count = 0;
  ReceiveStoreOptions options;
  options.io = [&](ReceiveIo op, uintptr_t, size_t) {
    if (op == ReceiveIo::read) ++read_count;
    ReceiveIoDirective result;
    if (op == ReceiveIo::cleanup && fail_cleanup) result.error = ERROR_ACCESS_DENIED;
    return result;
  };
  Context c(f, options); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "cleanup", 3, Digest("abc"));
  c.store.Append(t, s, 0, Bytes("a")); c.store.ScopeStop(s, ReceiveStopMode::pause);
  auto cp = c.store.Checkpoint(t); c.store.Checkpoint(t);
  Check(read_count == 0, "paused checkpoint makes no file read");
  Reject([&] { c.store.Release(t); }, "invalid_range");
  c.store.Abort(t);
  Reject([&] { c.store.RetryCleanup(t); }, "cleanup_failed");
  fail_cleanup = false; c.store.RetryCleanup(t); c.store.Release(t);
  Reject([&] { c.store.Checkpoint(t); }, "invalid_token");
  s = c.Scope(); t = c.store.Begin(c.directory.token, s, "shutdown", 0, Digest(""));
  c.store.Shutdown();
  Reject([&] { c.store.Commit(t, s); }, "cancelled");
  Reject([&] { c.Scope(); }, "cancelled");
  c.store.RetryCleanup(t); c.store.Release(t);
}
void UnicodeAndLongNames() {
  Fixture f; Context c(f);
  const std::string max_name = std::string(251, 'a') + ".txt";
  auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, max_name, 0, Digest(""));
  auto r = c.store.Commit(t, s); f.Path(std::wstring(r.name.begin(), r.name.end()));
  Check(r.name == max_name, "full wire length admitted");
  s = c.Scope(); t = c.store.Begin(c.directory.token, s, max_name, 0, Digest(""));
  r = c.store.Commit(t, s); f.Path(std::wstring(r.name.begin(), r.name.end()));
  Check(r.name.size() <= 255 && r.name.find(" (1).txt") != std::string::npos, "numbered name reserves length");
  s = c.Scope(); t = c.store.Begin(c.directory.token, s, "cafe\xcc\x81.txt", 0, Digest(""));
  r = c.store.Commit(t, s); f.Path(L"caf\x00e9.txt");
  Check(r.name == "caf\xc3\xa9.txt", "NFC receipt");
  s = c.Scope(); t = c.store.Begin(c.directory.token, s, u8"空😀.txt", 0, Digest(""));
  r = c.store.Commit(t, s); f.Path(L"空😀.txt");
  Check(r.name == u8"空😀.txt", "non-BMP round trip");
}
void OldScopeCancelDuringResume() {
  for (bool close : {false, true}) {
    Fixture f; Barrier barrier; int reads = 0;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t, size_t) {
      if (op == ReceiveIo::read && ++reads == 1) barrier.Block();
      return ReceiveIoDirective{};
    };
    Context c(f, options); auto s = c.Scope();
    const std::string contents(600000, 'a');
    auto t = c.store.Begin(c.directory.token, s, "resume-race", static_cast<int64_t>(contents.size()), Digest(contents));
    int64_t offset = 0;
    while (offset < static_cast<int64_t>(contents.size()))
      offset = c.store.Append(t, s, offset, Bytes(contents.substr(static_cast<size_t>(offset), 32768)));
    c.store.ScopeStop(s, ReceiveStopMode::pause); auto cp = c.store.Checkpoint(t); auto fresh = c.Scope();
    std::string result;
    std::thread worker([&] { try { c.store.Resume(t, fresh, cp); result = "resumed"; }
      catch (const ReceiveException& e) { result = e.code(); } });
    barrier.Wait();
    if (close) c.store.ScopeClose(s); else c.store.ScopeStop(s, ReceiveStopMode::cancel);
    barrier.Release(); worker.join();
    Check(result == "cancelled" && reads == 1, "old scope stop prevents next resume read");
    Reject([&] { c.store.Commit(t, fresh); }, "cancelled");
  }
}
void QueuedWritesAndIndependentScopes() {
  Fixture f; Barrier barrier; bool block = true;
  ReceiveStoreOptions options;
  options.io = [&](ReceiveIo op, uintptr_t, size_t) {
    if (op == ReceiveIo::write && block) barrier.Block();
    return ReceiveIoDirective{};
  };
  Context c(f, options); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "stopped", 1, Digest("x"));
  std::string result;
  std::thread worker([&] { try { c.store.Append(t, s, 0, Bytes("x")); result = "written"; }
    catch (const ReceiveException& e) { result = e.code(); } });
  barrier.Wait(); c.store.ScopeStop(s, ReceiveStopMode::cancel); barrier.Release(); worker.join(); block = false;
  Check(result == "cancelled" && c.store.Checkpoint(t).offset == 0, "stop blocks queued write");
  auto other = c.Scope("other"); auto next = c.store.Begin(c.directory.token, other, "other", 1, Digest("y"));
  c.store.Append(next, other, 0, Bytes("y")); c.store.Commit(next, other);
  Check(Read(f.Path(L"other")) == "y", "stop isolates scope");
}
DWORD Junction(const fs::path& path, const fs::path& target) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return GetLastError();
  struct Data { DWORD tag; WORD length; WORD reserved; WORD sub_offset; WORD sub_length; WORD print_offset; WORD print_length; wchar_t path[1]; };
  const std::wstring sub = L"\\??\\" + target.native(); const auto print = target.native();
  const size_t size = offsetof(Data, path) + (sub.size() + print.size() + 2) * sizeof(wchar_t);
  std::vector<uint8_t> bytes(size, 0); auto* data = reinterpret_cast<Data*>(bytes.data());
  data->tag = IO_REPARSE_TAG_MOUNT_POINT; data->length = static_cast<WORD>(size - 8);
  data->sub_length = static_cast<WORD>(sub.size() * sizeof(wchar_t));
  data->print_offset = static_cast<WORD>((sub.size() + 1) * sizeof(wchar_t));
  data->print_length = static_cast<WORD>(print.size() * sizeof(wchar_t));
  std::memcpy(data->path, sub.data(), data->sub_length);
  std::memcpy(reinterpret_cast<uint8_t*>(data->path) + data->print_offset, print.data(), data->print_length);
  DWORD returned = 0;
  const auto success = DeviceIoControl(file, FSCTL_SET_REPARSE_POINT, bytes.data(), static_cast<DWORD>(size), nullptr, 0, &returned, nullptr);
  const auto error = success ? ERROR_SUCCESS : GetLastError(); CloseHandle(file); return error;
}
void AncestorLocksAndJunctions() {
  Fixture f; Fixture outside;
  auto child = f.Path(L"child"); Check(CreateDirectoryW(child.c_str(), nullptr) != 0, "child fixture");
  auto junction = f.Path(L"junction"); Check(CreateDirectoryW(junction.c_str(), nullptr) != 0, "junction fixture");
  Check(Junction(junction, outside.root) == ERROR_SUCCESS, "real junction created");
  ReceiveStore store;
  Reject([&] { store.DirectoryFromPicker(junction.native()); }, "directory_changed");
  auto outside_child = outside.Path(L"next"); Check(CreateDirectoryW(outside_child.c_str(), nullptr) != 0, "outside child");
  Reject([&] { store.DirectoryFromPicker((junction / L"next").native()); }, "directory_changed");
  auto directory = store.DirectoryFromPicker(child.native());
  const auto moved = f.root.native() + L"-moved";
  Check(!MoveFileExW(f.root.c_str(), moved.c_str(), 0) && GetLastError() == ERROR_SHARING_VIOLATION, "ancestor rename denied");
  HANDLE write = CreateFileW(child.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  Check(write == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION, "bound directory write denied");
  Check(Junction(child, outside.root) == ERROR_SHARING_VIOLATION, "bound directory reparse mutation denied");
  store.DirectoryRelease(directory.token);
  Check(MoveFileExW(f.root.c_str(), moved.c_str(), 0) != 0, "released ancestor unlocks");
  Check(MoveFileExW(moved.c_str(), f.root.c_str(), 0) != 0, "restore fixture");
  Reject([&] { store.DirectoryFromPicker(L"\\\\server\\share"); }, "unsupported_storage");
  Reject([&] { store.DirectoryFromPicker(f.root.native() + L"\\..\\escape"); }, "invalid_name");
}
void RestrictiveAclAndRealCleanupFailure() {
  Fixture f; uintptr_t file = 0;
  ReceiveStoreOptions options;
  options.io = [&](ReceiveIo op, uintptr_t h, size_t) { if (op == ReceiveIo::write) file = h; return ReceiveIoDirective{}; };
  Context c(f, options); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "acl", 1, Digest("a"));
  c.store.Append(t, s, 0, Bytes("a"));
  PSECURITY_DESCRIPTOR security = nullptr; PACL acl = nullptr; PSID owner = nullptr;
  Check(GetSecurityInfo(reinterpret_cast<HANDLE>(file), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
    &owner, nullptr, &acl, nullptr, &security) == ERROR_SUCCESS, "read temp ACL");
  SECURITY_DESCRIPTOR_CONTROL control{}; DWORD revision = 0;
  Check(GetSecurityDescriptorControl(security, &control, &revision) != 0 && (control & SE_DACL_PROTECTED) != 0, "inheritance disabled");
  Check(acl && acl->AceCount == 2, "two explicit ACEs");
  std::array<uint8_t, SECURITY_MAX_SID_SIZE> system{}; DWORD sid_size = static_cast<DWORD>(system.size());
  Check(CreateWellKnownSid(WinLocalSystemSid, nullptr, system.data(), &sid_size) != 0, "system SID");
  bool has_owner = false; bool has_system = false;
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* raw = nullptr; Check(GetAce(acl, i, &raw) != 0, "read ACE");
    const auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
    Check(ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE && ace->Header.AceFlags == 0, "only explicit allow ACEs");
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    has_owner |= EqualSid(sid, owner) != 0; has_system |= EqualSid(sid, system.data()) != 0;
  }
  LocalFree(security); Check(has_owner && has_system, "only current owner and SYSTEM");
  FILE_BASIC_INFO attrs{}; attrs.FileAttributes = FILE_ATTRIBUTE_READONLY;
  Check(SetFileInformationByHandle(reinterpret_cast<HANDLE>(file), FileBasicInfo, &attrs, sizeof(attrs)) != 0, "make original read-only");
  c.store.Abort(t); Reject([&] { c.store.RetryCleanup(t); }, "cleanup_failed");
  attrs.FileAttributes = FILE_ATTRIBUTE_NORMAL;
  Check(SetFileInformationByHandle(reinterpret_cast<HANDLE>(file), FileBasicInfo, &attrs, sizeof(attrs)) != 0, "retained original handle retry");
  c.store.RetryCleanup(t); c.store.Release(t);
}
void UnexposedCleanupAndUnexpectedAppendFailure() {
  Fixture f; int creations = 0; int cleanups = 0; bool fail = true;
  ReceiveStoreOptions options;
  options.io = [&](ReceiveIo op, uintptr_t, size_t) {
    ReceiveIoDirective result;
    if (op == ReceiveIo::after_create) { ++creations; if (fail) result.error = ERROR_ACCESS_DENIED; }
    if (op == ReceiveIo::cleanup) { ++cleanups; if (fail) result.error = ERROR_ACCESS_DENIED; }
    return result;
  };
  Context c(f, options); auto s = c.Scope();
  Reject([&] { c.store.Begin(c.directory.token, s, "hidden", 0, Digest("")); }, "permission_denied");
  Check(creations == 1 && cleanups == 1, "failed begin keeps exact object");
  c.store.ScopeClose(s); fail = false; c.store.RetryPendingCleanup();
  Check(cleanups == 2, "unexposed owned object retried");
  s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "later", 0, Digest(""));
  c.store.Commit(t, s); f.Path(L"later");

  int calls = 0;
  options.io = [&](ReceiveIo op, uintptr_t, size_t) {
    if (op == ReceiveIo::write && ++calls == 2) throw std::runtime_error("injected native failure");
    ReceiveIoDirective result; result.maximum_bytes = 1; return result;
  };
  Context unexpected(f, options); s = unexpected.Scope();
  t = unexpected.store.Begin(unexpected.directory.token, s, "unexpected", 3, Digest("abc"));
  bool failed = false;
  try { unexpected.store.Append(t, s, 0, Bytes("abc")); } catch (const std::runtime_error&) { failed = true; }
  Check(failed, "native exception propagated");
  Reject([&] { unexpected.store.Append(t, s, 1, Bytes("bc")); }, "cancelled");
}
void OutstandingDiskReservations() {
  Fixture f; uint64_t disk_free = 100;
  ReceiveStoreOptions options;
  options.free_bytes = [&](uint64_t, uint64_t* bytes) { *bytes = disk_free; return true; };
  Context c(f, options);
  auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "a", 60, Digest(std::string(60, 'a')));
  c.store.Append(t, s, 0, Bytes(std::string(40, 'a'))); disk_free = 60;
  auto second = c.Scope("second");
  auto second_token = c.store.Begin(c.directory.token, second, "b", 40, Digest(std::string(40, 'b')));
  auto third = c.Scope("third");
  Reject([&] { c.store.Begin(c.directory.token, third, "c", 1, Digest("c")); }, "disk_full");
  c.store.Abort(second_token); c.store.RetryCleanup(second_token); c.store.Release(second_token);
  auto last = c.Scope("last");
  auto last_token = c.store.Begin(c.directory.token, last, "d", 40, Digest(std::string(40, 'd')));
  c.store.Abort(last_token); c.store.RetryCleanup(last_token);
}
void ConcurrentNumberingAndExhaustion() {
  Fixture f; Context c(f);
  Write(f.Path(L"same.txt"), "existing");
  std::mutex mutex; std::condition_variable condition; int ready = 0; bool go = false;
  std::vector<std::string> scopes, tokens;
  constexpr int count = 12;
  for (int i = 0; i < count; ++i) {
    auto scope = c.Scope(); const auto bytes = std::to_string(i);
    auto token = c.store.Begin(c.directory.token, scope, "same.txt", static_cast<int64_t>(bytes.size()), Digest(bytes));
    c.store.Append(token, scope, 0, Bytes(bytes)); scopes.push_back(scope); tokens.push_back(token);
  }
  std::vector<ReceiveReceipt> receipts(count); std::vector<std::string> errors(count);
  std::vector<std::thread> workers;
  for (int i = 0; i < count; ++i) workers.emplace_back([&, i] {
    { std::unique_lock<std::mutex> lock(mutex); ++ready; condition.notify_all(); condition.wait(lock, [&] { return go; }); }
    try { receipts[i] = c.store.Commit(tokens[i], scopes[i]); }
    catch (const std::exception& error) { errors[i] = error.what(); }
  });
  { std::unique_lock<std::mutex> lock(mutex); condition.wait(lock, [&] { return ready == count; }); go = true; condition.notify_all(); }
  for (auto& worker : workers) worker.join();
  std::set<std::string> names;
  for (int i = 0; i < count; ++i) {
    Check(errors[i].empty(), "concurrent publish succeeded");
    names.insert(receipts[i].name);
    Check(Read(f.Path(std::wstring(receipts[i].name.begin(), receipts[i].name.end()))) == std::to_string(i), "concurrent receipt intact");
  }
  Check(names.size() == count && Read(f.root / L"same.txt") == "existing", "no concurrent overwrite");
  for (unsigned i = 0; i < 1000; ++i) {
    const auto name = i == 0 ? L"full" : L"full (" + std::to_wstring(i) + L")";
    Write(f.Path(name), "preserved");
  }
  auto scope = c.Scope(); auto token = c.store.Begin(c.directory.token, scope, "full", 0, Digest(""));
  Reject([&] { c.store.Commit(token, scope); }, "name_exhausted");
  Check(Read(f.root / L"full") == "preserved" && Read(f.root / L"full (999)") == "preserved", "exhaustion preserves endpoints");
  Check(!fs::exists(f.root / L"full (1000)"), "bounded candidate count");
}
void WholeHandleTamperAndBoundDirectoryLifetime() {
  for (bool extra_tail : {false, true}) {
    Fixture f; uintptr_t file = 0;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t handle, size_t) { if (op == ReceiveIo::write) file = handle; return ReceiveIoDirective{}; };
    Context c(f, options); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "verify", 3, Digest("abc"));
    c.store.Append(t, s, 0, Bytes("abc"));
    Check(c.store.Checkpoint(t).sha256 == Digest("abc"), "stream checkpoint known");
    LARGE_INTEGER offset{}; offset.QuadPart = extra_tail ? 3 : 0;
    Check(SetFilePointerEx(reinterpret_cast<HANDLE>(file), offset, nullptr, FILE_BEGIN) != 0, "wholehandle mutate position");
    DWORD written = 0; Check(WriteFile(reinterpret_cast<HANDLE>(file), "z", 1, &written, nullptr) != 0, "wholehandle mutate");
    Reject([&] { c.store.Commit(t, s); }, extra_tail ? "source_changed" : "integrity_mismatch");
    Check(!fs::exists(f.root / L"verify"), "cached checkpoint never used as completion proof");
  }
  Fixture f; Context c(f); auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "bound", 0, Digest(""));
  c.store.DirectoryRelease(c.directory.token);
  c.store.Commit(t, s); Check(Read(f.Path(L"bound")).empty(), "released directory retained by active entry");
  c.store.Release(t); c.store.ScopeClose(s);
  Reject([&] { c.store.Commit(t, s); }, "invalid_token");
}
void PauseDuringCommitAndDeadlineDuringRead() {
  for (bool pause : {true, false}) {
    Fixture f; Context* context = nullptr; bool intercept = true; std::string scope;
    ReceiveStoreOptions options;
    options.io = [&](ReceiveIo op, uintptr_t, size_t) {
      if (intercept && op == ReceiveIo::read) {
        intercept = false;
        if (pause) context->store.ScopeStop(scope, ReceiveStopMode::pause); else context->now = 10000;
      }
      return ReceiveIoDirective{};
    };
    Context c(f, options); context = &c; scope = c.Scope();
    auto t = c.store.Begin(c.directory.token, scope, "guard", 3, Digest("abc"));
    c.store.Append(t, scope, 0, Bytes("abc"));
    Reject([&] { c.store.Commit(t, scope); }, pause ? "paused" : "expired");
    Check(!fs::exists(f.root / L"guard"), "read guard prevents publication");
    if (pause) {
      auto cp = c.store.Checkpoint(t); auto fresh = c.Scope(); c.store.Resume(t, fresh, cp);
      c.store.Commit(t, fresh); Check(Read(f.Path(L"guard")) == "abc", "commit pause remains resumable");
    }
  }
}
void BoundedEntriesDirectoriesAndRelease() {
  Fixture f; Context c(f);
  std::vector<std::string> scopes, tokens;
  for (int i = 0; i < 64; ++i) {
    auto s = c.Scope(); auto t = c.store.Begin(c.directory.token, s, "pending", 0, Digest(""));
    scopes.push_back(s); tokens.push_back(t);
  }
  Reject([&] { c.store.Begin(c.directory.token, scopes[0], "over", 0, Digest("")); }, "resource_limit");
  Reject([&] { c.store.Release(tokens[0]); }, "invalid_range");
  c.store.Abort(tokens[0]); c.store.RetryCleanup(tokens[0]); c.store.Release(tokens[0]); c.store.ScopeClose(scopes[0]);
  auto fresh = c.Scope(); auto t = c.store.Begin(c.directory.token, fresh, "capacity", 0, Digest(""));
  c.store.Commit(t, fresh); f.Path(L"capacity");
  c.store.Release(t); c.store.ScopeClose(fresh);
  for (size_t i = 1; i < tokens.size(); ++i) {
    c.store.Abort(tokens[i]); c.store.RetryCleanup(tokens[i]); c.store.Release(tokens[i]); c.store.ScopeClose(scopes[i]);
  }
  std::vector<std::string> directories;
  for (int i = 1; i < 64; ++i) directories.push_back(c.store.DirectoryFromPicker(f.root.native()).token);
  Reject([&] { c.store.DirectoryFromPicker(f.root.native()); }, "resource_limit");
  c.store.DirectoryRelease(directories[0]);
  auto directory = c.store.DirectoryFromPicker(f.root.native());
  c.store.DirectoryRelease(directory.token);
  for (const auto& id : directories) c.store.DirectoryRelease(id);
  auto scope = c.Scope();
  Reject([&] { c.store.Begin(c.directory.token, scope, "huge", INT64_MAX, Digest("")); }, "disk_full");
  t = c.store.Begin(c.directory.token, scope, "offset", 1, Digest("x"));
  Reject([&] { c.store.Append(t, scope, INT64_MAX, Bytes("x")); }, "invalid_range");
}
struct DirectorySettingsFixture {
  std::wstring key = L"Software\\ShareHub\\Tests\\ReceiveDirectory-" +
    std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  ~DirectorySettingsFixture() { RegDeleteKeyW(HKEY_CURRENT_USER, key.c_str()); }
  ReceiveStoreOptions Options() const {
    ReceiveStoreOptions options;
    options.directory_settings_key = key;
    options.clock = [](uint64_t* value) { *value = 100; return true; };
    return options;
  }
  void Corrupt() {
    HKEY opened = nullptr;
    Check(RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &opened, nullptr) == ERROR_SUCCESS, "settings fixture");
    const BYTE bytes[] = {1, 2, 3};
    const auto status = RegSetValueExW(opened, L"ReceiveDirectoryV1", 0,
      REG_BINARY, bytes, sizeof(bytes));
    RegCloseKey(opened); Check(status == ERROR_SUCCESS, "corrupt settings fixture");
  }
};
void ConfiguredDirectorySurvivesRestart() {
  Fixture f; DirectorySettingsFixture settings;
  std::string old_token;
  {
    ReceiveStore first(settings.Options());
    old_token = first.DirectoryFromPicker(f.root.native()).token;
  }
  ReceiveStore restarted(settings.Options());
  const auto directory = restarted.DirectoryConfigured();
  Check(directory.token != old_token, "restored setting mints fresh capability");
  const auto scope = restarted.ScopeOpen("new-grant-file", 10000);
  Reject([&] { restarted.Begin(old_token, scope, "old", 0, Digest("")); }, "invalid_token");
  const auto file = restarted.Begin(directory.token, scope, "saved.txt", 0, Digest(""));
  const auto receipt = restarted.Commit(file, scope);
  Check(Read(f.Path(L"saved.txt")).empty() && receipt.name == "saved.txt", "new file uses restored directory");
  restarted.Release(file); restarted.ScopeClose(scope);
}
void ConfiguredReplacementFailsClosed() {
  Fixture f; DirectorySettingsFixture settings;
  auto chosen = f.Path(L"chosen"), moved = f.Path(L"moved");
  Check(CreateDirectoryW(chosen.c_str(), nullptr) != 0, "chosen fixture");
  { ReceiveStore store(settings.Options()); store.DirectoryFromPicker(chosen.native()); }
  Check(MoveFileW(chosen.c_str(), moved.c_str()) != 0, "move original chosen directory");
  Check(CreateDirectoryW(chosen.c_str(), nullptr) != 0, "replacement fixture");
  ReceiveStore restarted(settings.Options());
  Reject([&] { restarted.DirectoryConfigured(); }, "directory_changed");
  Check(fs::is_empty(chosen), "replacement receives no files");
  const auto selected = restarted.DirectoryFromPicker(chosen.native());
  const auto restored = restarted.DirectoryConfigured();
  Check(restored.token != selected.token, "explicit selection repairs preference");
}
void CorruptDirectorySettingsFailClosed() {
  Fixture f; DirectorySettingsFixture settings;
  settings.Corrupt();
  ReceiveStore store(settings.Options());
  Reject([&] { store.DirectoryConfigured(); }, "settings_unavailable");
  store.DirectoryFromPicker(f.root.native());
  Check(!store.DirectoryConfigured().token.empty(), "picker repairs malformed preference");
}
void FailedDirectorySaveKeepsOldPreference() {
  Fixture f; DirectorySettingsFixture settings;
  { ReceiveStore store(settings.Options()); store.DirectoryFromPicker(f.root.native()); }
  auto chosen = f.Path(L"new-destination");
  Check(CreateDirectoryW(chosen.c_str(), nullptr) != 0, "new chosen directory");
  HKEY key = nullptr;
  Check(RegOpenKeyExW(HKEY_CURRENT_USER, settings.key.c_str(), 0,
    WRITE_DAC | READ_CONTROL, &key) == ERROR_SUCCESS, "settings ACL handle");
  PACL original_acl = nullptr; PSECURITY_DESCRIPTOR security = nullptr;
  Check(GetSecurityInfo(key, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION,
    nullptr, nullptr, &original_acl, nullptr, &security) == ERROR_SUCCESS, "read settings ACL");
  BYTE everyone[SECURITY_MAX_SID_SIZE]; DWORD size = sizeof(everyone);
  Check(CreateWellKnownSid(WinWorldSid, nullptr, everyone, &size) != 0, "everyone SID");
  EXPLICIT_ACCESSW deny{};
  deny.grfAccessPermissions = KEY_SET_VALUE; deny.grfAccessMode = DENY_ACCESS;
  deny.Trustee.TrusteeForm = TRUSTEE_IS_SID; deny.Trustee.ptstrName = reinterpret_cast<LPWSTR>(everyone);
  PACL blocked = nullptr;
  Check(SetEntriesInAclW(1, &deny, original_acl, &blocked) == ERROR_SUCCESS, "deny setting writes ACL");
  Check(SetSecurityInfo(key, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION,
    nullptr, nullptr, blocked, nullptr) == ERROR_SUCCESS, "install setting write denial");
  auto restore = [&] {
    SetSecurityInfo(key, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION, nullptr, nullptr, original_acl, nullptr);
    LocalFree(blocked); LocalFree(security); RegCloseKey(key);
  };
  try {
    ReceiveStore failing(settings.Options());
    // Repeated failed saves must release unreturned directory capabilities.
    for (int i = 0; i < 65; ++i)
      Reject([&] { failing.DirectoryFromPicker(chosen.native()); }, "settings_unavailable");
  } catch (...) { restore(); throw; }
  restore();
  ReceiveStore original(settings.Options());
  const auto restored = original.DirectoryConfigured();
  const auto scope = original.ScopeOpen("after-save-error", 10000);
  const auto token = original.Begin(restored.token, scope, "old-destination.txt", 0, Digest(""));
  original.Commit(token, scope); original.Release(token);
  Check(Read(f.Path(L"old-destination.txt")).empty() && fs::is_empty(chosen), "failed save keeps previous destination");
}
void LongUnicodeDestinationRestores() {
  Fixture f; DirectorySettingsFixture settings;
  auto path = f.root;
  // Legal per-component UTF-16 names can exceed the UTF-8 record decoder's
  // former 32767-byte limit well before reaching the native depth/path limits.
  for (int i = 0; i < 48; ++i) {
    path /= std::wstring(240, L'界');
    f.owned.insert(path);
    Check(CreateDirectoryW((L"\\\\?\\" + path.native()).c_str(), nullptr) != 0, "long Unicode destination fixture");
  }
  { ReceiveStore first(settings.Options()); first.DirectoryFromPicker(path.native()); }
  ReceiveStore restarted(settings.Options());
  Check(!restarted.DirectoryConfigured().token.empty(), "long Unicode preference restores");
}
}  // namespace
int main() {
  int failures = 0;
  const std::vector<std::pair<const char*, std::function<void()>>> tests = {
    {"configured destination survives store restart with fresh capabilities", ConfiguredDirectorySurvivesRestart},
    {"configured replacement fails closed until reselected", ConfiguredReplacementFailsClosed},
    {"corrupt settings fail closed and picker repairs them", CorruptDirectorySettingsFailClosed},
    {"failed preference save preserves existing selection", FailedDirectorySaveKeepsOldPreference},
    {"legal long Unicode destination restores", LongUnicodeDestinationRestores},
    {"empty, multichunk and collision receipts", SuccessAndCollisions},
    {"strict names, exact offsets and chunks", NamesAndRanges},
    {"paused cached checkpoint and verified resume", PauseResume},
    {"resume mutation, extra tail, stale checkpoint and binding", ResumeRejects},
    {"clock failure, rollback, expiry and limits", ClockAndLimits},
    {"partial IO, injected failures and digest mismatch", IntegrityAndIoFailures},
    {"deterministic cancel versus publication", StopRaces},
    {"cleanup retry and shutdown barriers", CleanupAndShutdown},
    {"Unicode normalization and bounded numbering", UnicodeAndLongNames},
    {"old scope cancellation during resume hash", OldScopeCancelDuringResume},
    {"queued write barrier and independent scopes", QueuedWritesAndIndependentScopes},
    {"full ancestor locks and real junction rejection", AncestorLocksAndJunctions},
    {"owner SYSTEM ACL and real cleanup retry", RestrictiveAclAndRealCleanupFailure},
    {"unexposed cleanup ownership and unexpected exceptions", UnexposedCleanupAndUnexpectedAppendFailure},
    {"unwritten disk reservations avoid double counting", OutstandingDiskReservations},
    {"concurrent atomic numbering and candidate exhaustion", ConcurrentNumberingAndExhaustion},
    {"wholehandle tamper and bound directory lifetime", WholeHandleTamperAndBoundDirectoryLifetime},
    {"commit pause and read deadline guards", PauseDuringCommitAndDeadlineDuringRead},
    {"bounded entries directories and metadata release", BoundedEntriesDirectoriesAndRelease},
  };
  for (const auto& test : tests) {
    try { test.second(); std::cout << "PASS " << test.first << '\n'; }
    catch (const std::exception& e) { ++failures; std::cerr << "FAIL " << test.first << ": " << e.what() << '\n'; }
  }
  std::cout << "receive_store tests=" << tests.size() << " failed=" << failures << '\n';
  return failures == 0 ? 0 : 1;
}
