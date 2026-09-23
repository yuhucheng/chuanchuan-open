#include "selected_file_store.h"

#include <objbase.h>
#include <windows.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

namespace share_hub {
namespace {
std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (count <= 0) throw SelectedFileException(SelectedFileError::unavailable);
  std::string result(static_cast<size_t>(count), '\0');
  if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                           static_cast<int>(value.size()), result.data(), count,
                           nullptr, nullptr)) {
    throw SelectedFileException(SelectedFileError::unavailable);
  }
  return result;
}

std::string NewToken() {
  GUID guid{};
  if (CoCreateGuid(&guid) != S_OK)
    throw SelectedFileException(SelectedFileError::unavailable);
  wchar_t text[40];
  if (!StringFromGUID2(guid, text, 40))
    throw SelectedFileException(SelectedFileError::unavailable);
  return Utf8(text);
}

struct Snapshot {
  FILE_ID_INFO id{};
  FILE_BASIC_INFO basic{};
  FILE_STANDARD_INFO standard{};
};

bool Regular(const Snapshot& state) {
  return !state.standard.Directory && state.standard.EndOfFile.QuadPart >= 0 &&
         !(state.basic.FileAttributes &
           (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
}

bool Same(const Snapshot& a, const Snapshot& b) {
  return a.id.VolumeSerialNumber == b.id.VolumeSerialNumber &&
         std::memcmp(a.id.FileId.Identifier, b.id.FileId.Identifier,
                     sizeof(a.id.FileId.Identifier)) == 0 &&
         a.standard.EndOfFile.QuadPart == b.standard.EndOfFile.QuadPart &&
         a.basic.CreationTime.QuadPart == b.basic.CreationTime.QuadPart &&
         a.basic.LastWriteTime.QuadPart == b.basic.LastWriteTime.QuadPart &&
         a.basic.ChangeTime.QuadPart == b.basic.ChangeTime.QuadPart &&
         Regular(b);
}

HANDLE OpenRegular(const std::wstring& path, DWORD access, DWORD sharing) {
  return CreateFileW(path.c_str(), access, sharing, nullptr, OPEN_EXISTING,
                     FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
}
}  // namespace

SelectedFileException::SelectedFileException(SelectedFileError reason)
    : std::runtime_error("selected file access failed"), reason_(reason) {}
namespace {
[[noreturn]] void Fail(SelectedFileError error) {
  throw SelectedFileException(error);
}
void Text(const std::string& value, SelectedFileError error) {
  if (value.empty() || value.size() > 256 ||
      value.find('\0') != std::string::npos ||
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0) <= 0)
    Fail(error);
}
bool ContinuousMicros(uint64_t* out) {
  using Precise = decltype(&QueryInterruptTimePrecise);
  static const auto precise = reinterpret_cast<Precise>(GetProcAddress(
      GetModuleHandleW(L"kernel32.dll"), "QueryInterruptTimePrecise"));
  if (precise) {
    ULONGLONG ticks = 0;
    precise(&ticks);
    *out = ticks / 10;
  } else
    *out = GetTickCount64() * 1000;
  return *out != 0;
}
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() {
    if (value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
};
}  // namespace
struct SelectedFileStore::Impl {
  enum class State { active, paused, cancelled };
  struct Scope {
    std::string id, token, key;
    int64_t deadline = 0;
    State state = State::active;
  };
  struct Entry {
    std::function<void(SourceIo)> io;
    ~Entry() {
      if (io) try {
          io(SourceIo::before_close);
        } catch (...) {
        }
    }
    std::mutex work;
    Handle handle;
    std::wstring path;
    Snapshot original{};
    SelectedFileInfo info{};
    int64_t offset = 0;  // work mutex
    // All following control fields use Impl::mutex, never the work mutex.
    bool released = false, guarded = false, pass_mode = false;
    uint64_t generation = 0;
    std::string pass;
    std::shared_ptr<Scope> scope;
  };
  explicit Impl(SelectedFileStoreOptions value) : options(std::move(value)) {
    if (!options.clock) options.clock = ContinuousMicros;
  }
  SelectedFileStoreOptions options;
  mutable std::mutex mutex;
  std::map<std::string, std::shared_ptr<Entry>> entries;
  std::map<std::string, std::shared_ptr<Scope>> scopes;
  size_t selecting = 0, closing_count = 0;
  bool closed = false, clock_failed = false;
  uint64_t last_clock = 0;
  void Open() const {
    if (closed) Fail(SelectedFileError::closed);
    if (clock_failed) Fail(SelectedFileError::clock_failure);
  }
  uint64_t Now() {
    Open();
    uint64_t now = 0;
    bool valid = false;
    try {
      valid = options.clock(&now);
    } catch (...) {
      valid = false;
    }
    if (!valid || now == 0 || now > INT64_MAX || now < last_clock) {
      clock_failed = true;
      Fail(SelectedFileError::clock_failure);
    }
    last_clock = now;
    return now;
  }
  std::shared_ptr<Entry> Lookup(const std::string& token) {
    Text(token, SelectedFileError::invalid_token);
    std::lock_guard<std::mutex> lock(mutex);
    Open();
    auto it = entries.find(token);
    if (it == entries.end() || it->second->released)
      Fail(SelectedFileError::invalid_token);
    return it->second;
  }
  // Caller holds only control mutex. This admission is the I/O start boundary;
  // the actual syscall may complete after stop but no subsequent one is
  // admitted.
  void Check(const Entry& entry, const std::string& scope,
             const std::string& pass, bool begin = false,
             uint64_t generation = 0) {
    Open();
    if (entry.released) Fail(SelectedFileError::stopped);
    if (scope.empty()) {
      if (entry.guarded || (!begin && ((entry.pass_mode && pass.empty()) ||
                                       (!pass.empty() && entry.pass != pass))))
        Fail(SelectedFileError::invalid_read);
    } else {
      const auto now = Now();
      if (!entry.guarded || !entry.scope || entry.scope->id != scope)
        Fail(SelectedFileError::invalid_scope);
      if (now >= static_cast<uint64_t>(entry.scope->deadline))
        Fail(SelectedFileError::expired);
      if (entry.scope->state != State::active) Fail(SelectedFileError::stopped);
      if (!begin && (pass.empty() || entry.pass != pass))
        Fail(SelectedFileError::invalid_read);
    }
    if (generation && entry.generation != generation)
      Fail(SelectedFileError::invalid_read);
  }
  void Gate(const Entry& entry, const std::string& scope,
            const std::string& pass, bool begin = false,
            uint64_t generation = 0) {
    std::lock_guard<std::mutex> lock(mutex);
    Check(entry, scope, pass, begin, generation);
  }
  void Before(SourceIo op, const std::function<void()>& gate) {
    gate();
    if (options.io) options.io(op);
  }
  void SnapshotFile(HANDLE handle, Snapshot& snapshot,
                    const std::function<void()>& gate) {
    Before(SourceIo::metadata, gate);
    if (!GetFileInformationByHandleEx(handle, FileIdInfo, &snapshot.id,
                                      sizeof(snapshot.id)))
      Fail(SelectedFileError::changed);
    Before(SourceIo::metadata, gate);
    if (!GetFileInformationByHandleEx(handle, FileBasicInfo, &snapshot.basic,
                                      sizeof(snapshot.basic)))
      Fail(SelectedFileError::changed);
    Before(SourceIo::metadata, gate);
    if (!GetFileInformationByHandleEx(handle, FileStandardInfo,
                                      &snapshot.standard,
                                      sizeof(snapshot.standard)))
      Fail(SelectedFileError::changed);
  }
  void Validate(Entry& entry, const std::function<void()>& gate) {
    Snapshot held{}, at_path{};
    SnapshotFile(entry.handle.value, held, gate);
    if (!Same(entry.original, held)) Fail(SelectedFileError::changed);
    Before(SourceIo::open_path, gate);
    Handle path;
    path.value =
        OpenRegular(entry.path, FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    if (path.value == INVALID_HANDLE_VALUE) Fail(SelectedFileError::changed);
    SnapshotFile(path.value, at_path, gate);
    if (!Same(entry.original, at_path)) Fail(SelectedFileError::changed);
  }
  std::string Begin(const std::string& token, const std::string& scope) {
    auto entry = Lookup(token);
    uint64_t generation = 0;
    {
      std::lock_guard<std::mutex> lock(mutex);
      Check(*entry, scope, {}, true);
      if (entry->generation == UINT64_MAX) Fail(SelectedFileError::limit);
      generation = ++entry->generation;
      entry->pass_mode = true;
      entry->pass.clear();
    }
    if (options.io) options.io(SourceIo::pass_invalidated);
    // Invalidate before waiting for an admitted read; only the newest begin
    // may reset/complete the original handle once the work lock becomes free.
    std::unique_lock<std::mutex> work(entry->work);
    auto gate = [&] { Gate(*entry, scope, {}, true, generation); };
    Validate(*entry, gate);
    Before(SourceIo::seek, gate);
    LARGE_INTEGER zero{};
    if (!SetFilePointerEx(entry->handle.value, zero, nullptr, FILE_BEGIN))
      Fail(SelectedFileError::changed);
    Validate(*entry, gate);
    auto pass = NewToken();
    {
      std::lock_guard<std::mutex> lock(mutex);
      Check(*entry, scope, {}, true, generation);
      entry->offset = 0;
      entry->pass = pass;
    }
    return pass;
  }
  std::vector<uint8_t> Read(const std::string& token, const std::string& scope,
                            const std::string& pass, int64_t offset,
                            int length) {
    auto entry = Lookup(token);
    std::unique_lock<std::mutex> work(entry->work);
    auto gate = [&] { Gate(*entry, scope, pass); };
    gate();
    if (length <= 0 || length > kMaximumChunk || offset < 0 ||
        offset != entry->offset || offset >= entry->info.size)
      Fail(SelectedFileError::invalid_read);
    Validate(*entry, gate);
    const auto amount = static_cast<DWORD>(
        std::min<int64_t>(length, entry->info.size - offset));
    Before(SourceIo::seek, gate);
    LARGE_INTEGER position{};
    position.QuadPart = offset;
    if (!SetFilePointerEx(entry->handle.value, position, nullptr, FILE_BEGIN))
      Fail(SelectedFileError::changed);
    std::vector<uint8_t> bytes(amount);
    DWORD received = 0;
    Before(SourceIo::read, gate);
    if (!ReadFile(entry->handle.value, bytes.data(), amount, &received,
                  nullptr) ||
        received != amount)
      Fail(SelectedFileError::changed);
    Validate(*entry, gate);
    {
      std::lock_guard<std::mutex> lock(mutex);
      Check(*entry, scope, pass);
      entry->offset += received;
    }
    return bytes;
  }
  void Finish(const std::string& token, const std::string& scope,
              const std::string& pass) {
    auto entry = Lookup(token);
    std::unique_lock<std::mutex> work(entry->work);
    auto gate = [&] { Gate(*entry, scope, pass); };
    gate();
    Validate(*entry, gate);
    if (entry->offset != entry->info.size) Fail(SelectedFileError::incomplete);
    gate();
  }
};
SelectedFileStore::SelectedFileStore()
    : SelectedFileStore(SelectedFileStoreOptions{}) {}
SelectedFileStore::SelectedFileStore(SelectedFileStoreOptions options)
    : impl_(std::make_unique<Impl>(std::move(options))) {}
SelectedFileStore::~SelectedFileStore() {
  Shutdown();
  CleanupReleased();
}
std::vector<SelectedFileInfo> SelectedFileStore::AddPickerPaths(
    const std::vector<std::wstring>& paths) {
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->Open();
    if (paths.size() > kMaximumFiles - impl_->entries.size() -
                           impl_->selecting - impl_->closing_count)
      Fail(SelectedFileError::limit);
    impl_->selecting += paths.size();
  }
  try {
    std::map<std::string, std::shared_ptr<Impl::Entry>> pending;
    std::vector<SelectedFileInfo> result;
    auto gate = [&] {
      std::lock_guard<std::mutex> lock(impl_->mutex);
      impl_->Open();
    };
    for (const auto& path : paths) {
      auto entry = std::make_shared<Impl::Entry>();
      entry->path = path;
      entry->io = impl_->options.io;
      impl_->Before(SourceIo::open_path, gate);
      entry->handle.value =
          OpenRegular(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE);
      if (entry->handle.value == INVALID_HANDLE_VALUE)
        Fail(SelectedFileError::unavailable);
      impl_->SnapshotFile(entry->handle.value, entry->original, gate);
      if (!Regular(entry->original)) Fail(SelectedFileError::unavailable);
      const auto split = path.find_last_of(L"\\/");
      entry->info = {
          NewToken(),
          Utf8(path.substr(split == std::wstring::npos ? 0 : split + 1)),
          entry->original.standard.EndOfFile.QuadPart};
      result.push_back(entry->info);
      pending.emplace(entry->info.token, std::move(entry));
    }
    {
      std::lock_guard<std::mutex> lock(impl_->mutex);
      impl_->Open();
      impl_->entries.merge(pending);
      impl_->selecting -= paths.size();
    }
    return result;
  } catch (...) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->selecting -= paths.size();
    throw;
  }
}
std::vector<uint8_t> SelectedFileStore::Read(const std::string& token,
                                             int64_t offset, int length) {
  return impl_->Read(token, {}, {}, offset, length);
}
void SelectedFileStore::Finish(const std::string& token) {
  impl_->Finish(token, {}, {});
}
std::string SelectedFileStore::BeginReadPass(const std::string& token) {
  return impl_->Begin(token, {});
}
std::vector<uint8_t> SelectedFileStore::ReadPass(const std::string& token,
                                                 const std::string& pass,
                                                 int64_t offset, int length) {
  Text(pass, SelectedFileError::invalid_read);
  return impl_->Read(token, {}, pass, offset, length);
}
void SelectedFileStore::FinishPass(const std::string& token,
                                   const std::string& pass) {
  Text(pass, SelectedFileError::invalid_read);
  impl_->Finish(token, {}, pass);
}
std::string SelectedFileStore::ScopeOpen(const std::string& token,
                                         const std::string& key,
                                         int64_t deadline) {
  Text(key, SelectedFileError::invalid_scope);
  if (deadline <= 0) Fail(SelectedFileError::invalid_scope);
  auto entry = impl_->Lookup(token);
  auto scope = std::make_shared<Impl::Scope>();
  scope->id = NewToken();
  scope->token = token;
  scope->key = key;
  scope->deadline = deadline;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  const auto now = impl_->Now();
  if (entry->released) Fail(SelectedFileError::stopped);
  if (now >= static_cast<uint64_t>(deadline)) Fail(SelectedFileError::expired);
  if (impl_->scopes.size() >= kMaximumFiles) Fail(SelectedFileError::limit);
  if (entry->guarded) {
    const auto& old = entry->scope;
    if (!old || old->state == Impl::State::cancelled)
      Fail(SelectedFileError::stopped);
    if (old->state != Impl::State::paused || old->key != key ||
        old->deadline != deadline)
      Fail(SelectedFileError::invalid_scope);
  }
  impl_->scopes.emplace(scope->id, scope);
  entry->guarded = true;
  entry->scope = scope;
  entry->pass.clear();
  return scope->id;
}
std::string SelectedFileStore::ScopeStop(const std::string& id,
                                         SourceStopMode mode) {
  Text(id, SelectedFileError::invalid_scope);
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (impl_->closed) Fail(SelectedFileError::closed);
  auto found = impl_->scopes.find(id);
  if (found == impl_->scopes.end()) Fail(SelectedFileError::invalid_scope);
  auto& state = found->second->state;
  if (mode == SourceStopMode::cancel)
    state = Impl::State::cancelled;
  else if (state == Impl::State::active)
    state = Impl::State::paused;
  return state == Impl::State::paused ? "paused" : "cancelled";
}
void SelectedFileStore::ScopeClose(const std::string& id) {
  Text(id, SelectedFileError::invalid_scope);
  std::lock_guard<std::mutex> lock(impl_->mutex);
  auto found = impl_->scopes.find(id);
  if (found == impl_->scopes.end()) return;
  found->second->state = Impl::State::cancelled;
  impl_->scopes.erase(found);
}
std::string SelectedFileStore::BeginPass(const std::string& token,
                                         const std::string& scope) {
  Text(scope, SelectedFileError::invalid_scope);
  return impl_->Begin(token, scope);
}
std::vector<uint8_t> SelectedFileStore::ReadPass(const std::string& token,
                                                 const std::string& scope,
                                                 const std::string& pass,
                                                 int64_t offset, int length) {
  Text(scope, SelectedFileError::invalid_scope);
  Text(pass, SelectedFileError::invalid_read);
  return impl_->Read(token, scope, pass, offset, length);
}
void SelectedFileStore::FinishPass(const std::string& token,
                                   const std::string& scope,
                                   const std::string& pass) {
  Text(scope, SelectedFileError::invalid_scope);
  Text(pass, SelectedFileError::invalid_read);
  impl_->Finish(token, scope, pass);
}
void SelectedFileStore::Release(const std::string& token) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  auto found = impl_->entries.find(token);
  if (found == impl_->entries.end()) return;
  found->second->released = true;
  if (found->second->scope)
    found->second->scope->state = Impl::State::cancelled;
  for (auto it = impl_->scopes.begin(); it != impl_->scopes.end();)
    if (it->second->token == token)
      it = impl_->scopes.erase(it);
    else
      ++it;
}
void SelectedFileStore::Shutdown() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->closed = true;
  for (auto& pair : impl_->entries) pair.second->released = true;
  impl_->scopes.clear();
}
void SelectedFileStore::CleanupReleased() {
  std::vector<std::shared_ptr<Impl::Entry>> closing;
  closing.reserve(kMaximumFiles);
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    for (auto it = impl_->entries.begin(); it != impl_->entries.end();) {
      if (it->second->released && it->second.use_count() == 1) {
        closing.push_back(std::move(it->second));
        it = impl_->entries.erase(it);
        ++impl_->closing_count;
      } else
        ++it;
    }
  }
  // Entry handles close here, outside the control lock and only on a worker.
  const auto count = closing.size();
  closing.clear();
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->closing_count -= count;
  }
}
void SelectedFileStore::ValidateCompletion(const std::string& token,
                                           const std::string& scope,
                                           const std::string& pass) {
  auto entry = impl_->Lookup(token);
  impl_->Gate(*entry, scope, pass);
}
size_t SelectedFileStore::count() const {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return impl_->entries.size() + impl_->selecting + impl_->closing_count;
}
}  // namespace share_hub
