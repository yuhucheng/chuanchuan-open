#include "receive_bridge.h"
#include <condition_variable>
#include <deque>
#include <mutex>
#include <set>
#include <thread>
#include <utility>

namespace share_hub {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
[[noreturn]] void Invalid(const char* code = "invalid_range") { throw ReceiveException(code); }
const Map& Arguments(const Value* value) {
  const auto* map = value ? std::get_if<Map>(value) : nullptr;
  if (!map || map->size() > 8) Invalid();
  return *map;
}
const Value& Field(const Map& args, const char* key) {
  const auto found = args.find(Value(key));
  if (found == args.end()) Invalid();
  return found->second;
}
std::string Text(const Value& value, size_t bound = 256) {
  const auto* text = std::get_if<std::string>(&value);
  if (!text || text->empty() || text->size() > bound || text->find('\0') != std::string::npos) Invalid("invalid_token");
  return *text;
}
std::string Token(const Value* value) {
  if (!value) Invalid("invalid_token");
  return Text(*value);
}
int64_t Integer(const Value& value) {
  if (const auto* number = std::get_if<int64_t>(&value)) return *number;
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  Invalid();
}
Value DirectoryValue(const ReceiveDirectory& directory) {
  return Value(Map{{Value("token"), Value(directory.token)}, {Value("label"), Value(directory.label)}});
}
void Failure(ReceiveBridge::Result& result, const std::string& code) {
  result.Error(code, "Receiving file operation failed.");
}
}  // namespace

struct ReceiveBridge::Shared {
  struct Job { uint64_t id; std::function<Value(ReceiveStore&)> work; std::vector<std::string> keys; };
  struct Completion { uint64_t id; Value value; std::string error; };
  explicit Shared(HWND window, ReceiveStoreOptions options)
      : window(window), store(std::make_unique<ReceiveStore>(std::move(options))) {}
  HWND window;
  std::unique_ptr<ReceiveStore> store;
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<Job> jobs;
  std::deque<Completion> completions;
  std::set<std::string> active_keys;
  bool cleanup_requested = false, cleanup_running = false;
  bool closed = false;
  size_t workers = 2;

  // Preserve submission order for every shared entry/scope/directory while
  // allowing unrelated files to use both workers. A blocked earlier job also
  // reserves its keys against overtaking by later jobs.
  std::deque<Job>::iterator NextJob() {
    auto unavailable = active_keys;
    for (auto job = jobs.begin(); job != jobs.end(); ++job) {
      bool free = true;
      for (const auto& key : job->keys) if (unavailable.count(key)) free = false;
      if (free) return job;
      unavailable.insert(job->keys.begin(), job->keys.end());
    }
    return jobs.end();
  }

  void Run() {
    for (;;) {
      Job job;
      bool cleanup = false;
      {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [this] {
          return closed || NextJob() != jobs.end() || (cleanup_requested && !cleanup_running);
        });
        if (closed) break;
        const auto next = NextJob();
        // Give a requested sweep the next available worker even while public
        // jobs remain eligible. Continuous transfer traffic cannot starve
        // cancellation cleanup; repeated requests collapse into one sweep.
        if (cleanup_requested && !cleanup_running) {
          cleanup = true; cleanup_requested = false; cleanup_running = true;
        } else if (next != jobs.end()) {
          job = std::move(*next); jobs.erase(next);
          active_keys.insert(job.keys.begin(), job.keys.end());
        }
      }
      if (cleanup) {
        // One coalesced sweep has no Flutter result and does not consume a
        // public queue slot. Failure stays owned and awaits an explicit retry
        // or a later cancellation/transfer; it never spins on a locked file.
        try { store->RetryPendingCleanup(); } catch (...) {}
        std::lock_guard<std::mutex> lock(mutex);
        cleanup_running = false; changed.notify_all();
        continue;
      }
      Completion completion{job.id, Value(), {}};
      try { completion.value = job.work(*store); }
      catch (const ReceiveException& error) { completion.error = error.code(); }
      catch (...) { completion.error = "io_failure"; }
      {
        std::lock_guard<std::mutex> lock(mutex);
        for (const auto& key : job.keys) active_keys.erase(key);
        if (!closed) {
          if (!completion.error.empty()) cleanup_requested = true;
          completions.push_back(std::move(completion));
          // No pointers in window messages; an old/reused HWND cannot acquire
          // stale native state. The existing UI timer is a failed-post fallback.
          if (window) PostMessageW(window, ReceiveBridge::kMessage, 0, 0);
        }
        changed.notify_all();
      }
    }
    bool last = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (workers > 1) { --workers; changed.notify_all(); }
      else last = true;
    }
    if (last) {
      // Every other worker has finished using the store. Its destructor retries
      // cleanup on this worker, never on the UI thread or a destroyed engine.
      store.reset();
      std::lock_guard<std::mutex> lock(mutex);
      workers = 0; changed.notify_all();
    }
  }
};

ReceiveBridge::ReceiveBridge(HWND window, ReceiveStoreOptions options)
    : shared_(std::make_shared<Shared>(window, std::move(options))) {
  size_t started = 0;
  try {
    for (; started < 2; ++started) {
      std::thread([shared = shared_] { shared->Run(); }).detach();
    }
  } catch (...) {
    shared_->store->Shutdown();
    {
      std::lock_guard<std::mutex> lock(shared_->mutex);
      shared_->workers -= 2 - started;
      shared_->closed = true;
    }
    shared_->changed.notify_all();
    throw;
  }
}
ReceiveBridge::~ReceiveBridge() { Close(); }

void ReceiveBridge::Queue(std::function<Value(ReceiveStore&)> work,
                          std::unique_ptr<Result> result, std::vector<std::string> keys) {
  if (closed_) { Failure(*result, "closed"); return; }
  if (pending_.size() >= kMaximumPending || next_ == UINT64_MAX) {
    Failure(*result, "resource_limit"); return;
  }
  const auto id = ++next_;
  pending_.emplace(id, std::move(result));
  try {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->jobs.push_back({id, std::move(work), std::move(keys)});
  } catch (...) {
    auto reply = std::move(pending_.at(id)); pending_.erase(id);
    Failure(*reply, "io_failure"); return;
  }
  shared_->changed.notify_one();
}

void ReceiveBridge::RequestCleanup() {
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    if (shared_->closed) return;
    shared_->cleanup_requested = true;
  }
  shared_->changed.notify_one();
}

void ReceiveBridge::AcceptPickedDirectory(std::wstring path, std::unique_ptr<Result> result) {
  Queue([path = std::move(path)](ReceiveStore& store) {
    return DirectoryValue(store.DirectoryFromPicker(path));
  }, std::move(result), {"directory-settings"});
}

bool ReceiveBridge::Handle(const flutter::MethodCall<Value>& call,
                           std::unique_ptr<Result>& caller_result) {
  const auto& full_method = call.method_name();
  const std::string prefix = "files.receive.";
  if (full_method.compare(0, prefix.size(), prefix) != 0) return false;
  auto result = std::move(caller_result);
  if (closed_) { Failure(*result, "closed"); return true; }
  const auto method = full_method.substr(prefix.size());
  try {
    const auto* args = call.arguments();
    if (method == "scopeOpen") {
      const auto& map = Arguments(args);
      result->Success(Value(shared_->store->ScopeOpen(Text(Field(map, "key")),
                                                       Integer(Field(map, "deadlineMicros")))));
    } else if (method == "scopeStop") {
      const auto& map = Arguments(args);
      const auto mode = Text(Field(map, "mode"));
      if (mode != "pause" && mode != "cancel") Invalid();
      result->Success(Value(shared_->store->ScopeStop(Text(Field(map, "scope")),
            mode == "pause" ? ReceiveStopMode::pause : ReceiveStopMode::cancel)));
      if (mode == "cancel") RequestCleanup();
    } else if (method == "scopeClose") {
      shared_->store->ScopeClose(Token(args)); RequestCleanup(); result->Success();
    } else if (method == "abort") {
      shared_->store->Abort(Token(args)); RequestCleanup(); result->Success();
    } else if (method == "directoryConfigured") {
      if (args && !std::holds_alternative<std::monostate>(*args)) Invalid();
      Queue([](ReceiveStore& store) { return DirectoryValue(store.DirectoryConfigured()); }, std::move(result), {"directory-settings"});
    } else if (method == "directoryRelease" || method == "checkpoint" ||
               method == "retryCleanup" || method == "release") {
      const auto token = Token(args);
      Queue([token, method](ReceiveStore& store) {
        if (method == "directoryRelease") store.DirectoryRelease(token);
        else if (method == "retryCleanup") store.RetryCleanup(token);
        else if (method == "release") store.Release(token);
        else {
          const auto checkpoint = store.Checkpoint(token);
          return Value(Map{{Value("offset"), Value(checkpoint.offset)},
              {Value("sha256"), Value(checkpoint.sha256)}, {Value("identity"), Value(checkpoint.identity)}});
        }
        return Value();
      }, std::move(result), {(method == "directoryRelease" ? "d:" : "e:") + token});
    } else if (method == "begin") {
      const auto& map = Arguments(args);
      const auto directory = Text(Field(map, "directory")), scope = Text(Field(map, "scope"));
      const auto name = Text(Field(map, "name")), digest = Text(Field(map, "sha256"), 64);
      const auto size = Integer(Field(map, "size"));
      if (size < 0) Invalid();
      Queue([directory, scope, name, size, digest](ReceiveStore& store) {
        return Value(store.Begin(directory, scope, name, size, digest));
      }, std::move(result), {"d:" + directory, "s:" + scope});
    } else if (method == "append") {
      const auto& map = Arguments(args);
      const auto token = Text(Field(map, "token")), scope = Text(Field(map, "scope"));
      const auto offset = Integer(Field(map, "offset"));
      const auto* bytes = std::get_if<std::vector<uint8_t>>(&Field(map, "bytes"));
      if (!bytes || bytes->empty() || bytes->size() > ReceiveStore::kMaximumChunk || offset < 0) Invalid();
      Queue([token, scope, offset, bytes = *bytes](ReceiveStore& store) {
        return Value(store.Append(token, scope, offset, bytes));
      }, std::move(result), {"e:" + token, "s:" + scope});
    } else if (method == "resume") {
      const auto& map = Arguments(args);
      const auto token = Text(Field(map, "token")), scope = Text(Field(map, "scope"));
      const ReceiveCheckpoint checkpoint{Integer(Field(map, "offset")),
          Text(Field(map, "sha256"), 64), Text(Field(map, "identity"))};
      if (checkpoint.offset < 0) Invalid();
      Queue([token, scope, checkpoint](ReceiveStore& store) {
        store.Resume(token, scope, checkpoint); return Value();
      }, std::move(result), {"e:" + token, "s:" + scope});
    } else if (method == "commit") {
      const auto& map = Arguments(args);
      const auto token = Text(Field(map, "token")), scope = Text(Field(map, "scope"));
      Queue([token, scope](ReceiveStore& store) {
        const auto receipt = store.Commit(token, scope);
        return Value(Map{{Value("name"), Value(receipt.name)}, {Value("size"), Value(receipt.size)},
                         {Value("sha256"), Value(receipt.sha256)}});
      }, std::move(result), {"e:" + token, "s:" + scope});
    } else result->NotImplemented();
  } catch (const ReceiveException& error) {
    if (result) Failure(*result, error.code());
  } catch (...) {
    if (result) Failure(*result, "io_failure");
  }
  return true;
}

void ReceiveBridge::Pump() {
  if (closed_) return;
  std::deque<Shared::Completion> completions;
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    completions.swap(shared_->completions);
  }
  for (auto& completion : completions) {
    const auto found = pending_.find(completion.id);
    if (found == pending_.end()) continue;
    auto result = std::move(found->second); pending_.erase(found);
    if (completion.error.empty()) result->Success(completion.value);
    else Failure(*result, completion.error);
  }
}

void ReceiveBridge::Close() {
  if (closed_) return;
  closed_ = true;
  shared_->store->Shutdown();
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->closed = true;
    shared_->jobs.clear(); shared_->completions.clear();
  }
  shared_->changed.notify_all();
  auto replies = std::move(pending_);
  // A close result makes no claim that an already-admitted atomic commit was
  // undone. No callbacks remain when the Flutter engine is destroyed.
  for (auto& reply : replies) Failure(*reply.second, "closed");
}

void ReceiveBridge::WaitForWorkers() {
  std::unique_lock<std::mutex> lock(shared_->mutex);
  shared_->changed.wait(lock, [this] { return shared_->workers == 0; });
}
}  // namespace share_hub
