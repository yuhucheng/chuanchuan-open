#include "source_bridge.h"

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
using List = flutter::EncodableList;
[[noreturn]] void Invalid(
    SelectedFileError error = SelectedFileError::invalid_read) {
  throw SelectedFileException(error);
}
const Map& Arguments(const Value* value) {
  const auto* map = value ? std::get_if<Map>(value) : nullptr;
  if (!map || map->size() > 8) Invalid();
  return *map;
}
const Value& Field(const Map& map, const char* name) {
  auto it = map.find(Value(name));
  if (it == map.end()) Invalid();
  return it->second;
}
std::string Text(const Value& value) {
  const auto* text = std::get_if<std::string>(&value);
  if (!text || text->empty() || text->size() > 256 ||
      text->find('\0') != std::string::npos ||
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
                          static_cast<int>(text->size()), nullptr, 0) <= 0)
    Invalid(SelectedFileError::invalid_token);
  return *text;
}
std::string Token(const Value* value) {
  if (!value) Invalid(SelectedFileError::invalid_token);
  return Text(*value);
}
int64_t Integer(const Value& value) {
  if (auto p = std::get_if<int64_t>(&value)) return *p;
  if (auto p = std::get_if<int32_t>(&value)) return *p;
  Invalid();
}
const char* Code(SelectedFileError error) {
  switch (error) {
    case SelectedFileError::closed:
      return "closed";
    case SelectedFileError::limit:
      return "resource_limit";
    case SelectedFileError::unavailable:
      return "source_unavailable";
    case SelectedFileError::changed:
      return "source_changed";
    case SelectedFileError::invalid_read:
      return "invalid_read";
    case SelectedFileError::incomplete:
      return "source_incomplete";
    case SelectedFileError::invalid_token:
      return "invalid_token";
    case SelectedFileError::invalid_scope:
      return "invalid_scope";
    case SelectedFileError::expired:
      return "expired";
    case SelectedFileError::clock_failure:
      return "clock_failure";
    case SelectedFileError::stopped:
      return "stopped";
  }
  return "source_unavailable";
}
void Failure(SourceBridge::Result& result, const std::string& code,
             bool guarded) {
  result.Error(guarded ? code : "file_access",
               "Selected file operation failed.");
}
}  // namespace
struct SourceBridge::Shared {
  struct Job {
    uint64_t id;
    std::function<Value(SelectedFileStore&)> work;
    bool guarded;
    std::vector<std::string> keys;
    Check check;
  };
  struct Completion {
    uint64_t id;
    Value value;
    std::string error;
    bool guarded;
    Check check;
  };
  Shared(HWND target, SelectedFileStoreOptions options)
      : window(target),
        store(std::make_unique<SelectedFileStore>(std::move(options))) {}
  HWND window;
  std::unique_ptr<SelectedFileStore> store;
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<Job> jobs;
  std::deque<Completion> completions;
  std::set<std::string> active;
  bool closed = false, cleanup_requested = false, cleanup_running = false;
  size_t workers = 2;
  std::deque<Job>::iterator Next() {
    auto blocked = active;
    for (auto it = jobs.begin(); it != jobs.end(); ++it) {
      bool free = true;
      for (const auto& key : it->keys)
        if (blocked.count(key)) free = false;
      if (free) return it;
      blocked.insert(it->keys.begin(), it->keys.end());
    }
    return jobs.end();
  }
  void Run() {
    for (;;) {
      Job job{};
      bool cleanup = false;
      {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] {
          return closed || Next() != jobs.end() ||
                 (cleanup_requested && !cleanup_running);
        });
        if (closed) break;
        if (cleanup_requested && !cleanup_running) {
          cleanup = true;
          cleanup_requested = false;
          cleanup_running = true;
        } else {
          auto next = Next();
          job = std::move(*next);
          jobs.erase(next);
          active.insert(job.keys.begin(), job.keys.end());
        }
      }
      if (cleanup) {
        try {
          store->CleanupReleased();
        } catch (...) {
        }
        std::lock_guard<std::mutex> lock(mutex);
        cleanup_running = false;
        changed.notify_all();
        continue;
      }
      Completion done{job.id, Value(), {}, job.guarded, std::move(job.check)};
      try {
        done.value = job.work(*store);
      } catch (const SelectedFileException& e) {
        done.error = Code(e.reason());
      } catch (...) {
        done.error = "source_unavailable";
      }
      {
        std::lock_guard<std::mutex> lock(mutex);
        for (const auto& key : job.keys) active.erase(key);
        cleanup_requested = true;
        if (!closed) {
          completions.push_back(std::move(done));
          if (window) PostMessageW(window, SourceBridge::kMessage, 0, 0);
        }
        changed.notify_all();
      }
    }
    bool last = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (workers > 1) {
        --workers;
        changed.notify_all();
      } else
        last = true;
    }
    if (last) {
      store.reset();
      std::lock_guard<std::mutex> lock(mutex);
      workers = 0;
      changed.notify_all();
    }
  }
};
SourceBridge::SourceBridge(HWND window, SelectedFileStoreOptions options)
    : shared_(std::make_shared<Shared>(window, std::move(options))) {
  size_t started = 0;
  try {
    for (; started < 2; ++started)
      std::thread([shared = shared_] { shared->Run(); }).detach();
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
SourceBridge::~SourceBridge() { Close(); }
void SourceBridge::Queue(std::function<Value(SelectedFileStore&)> work,
                         std::unique_ptr<Result> result, bool guarded,
                         std::vector<std::string> keys, Check check) {
  if (closed_) {
    Failure(*result, "closed", guarded);
    return;
  }
  if (pending_.size() >= kMaximumPending || next_ == UINT64_MAX) {
    Failure(*result, "resource_limit", guarded);
    return;
  }
  const auto id = ++next_;
  pending_.emplace(id, std::move(result));
  try {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->jobs.push_back(
        {id, std::move(work), guarded, std::move(keys), std::move(check)});
  } catch (...) {
    auto reply = std::move(pending_.at(id));
    pending_.erase(id);
    Failure(*reply, "source_unavailable", guarded);
    return;
  }
  shared_->changed.notify_one();
}
void SourceBridge::RequestCleanup() {
  std::lock_guard<std::mutex> lock(shared_->mutex);
  if (!shared_->closed) {
    shared_->cleanup_requested = true;
    shared_->changed.notify_one();
  }
}
void SourceBridge::AcceptPickedFiles(std::vector<std::wstring> paths,
                                     std::unique_ptr<Result> result) {
  if (paths.size() > SelectedFileStore::kMaximumFiles) {
    Failure(*result, "resource_limit", false);
    return;
  }
  Queue(
      [paths = std::move(paths)](SelectedFileStore& store) {
        List output;
        for (const auto& file : store.AddPickerPaths(paths))
          output.emplace_back(Map{{Value("token"), Value(file.token)},
                                  {Value("name"), Value(file.name)},
                                  {Value("size"), Value(file.size)}});
        return Value(output);
      },
      std::move(result), false, {"picker"});
}
bool SourceBridge::Handle(const flutter::MethodCall<Value>& call,
                          std::unique_ptr<Result>& caller) {
  const auto& method = call.method_name();
  const std::string prefix = "files.source.";
  const bool guarded = method.compare(0, prefix.size(), prefix) == 0;
  if (!guarded && method != "files.read" && method != "files.finish" &&
      method != "files.release" && method != "files.beginReadPass" &&
      method != "files.readPass" && method != "files.finishPass")
    return false;
  auto result = std::move(caller);
  if (closed_) {
    Failure(*result, "closed", guarded);
    return true;
  }
  try {
    const auto* args = call.arguments();
    const auto name = guarded ? method.substr(prefix.size()) : method.substr(6);
    if (guarded && name == "scopeOpen") {
      const auto& map = Arguments(args);
      result->Success(Value(shared_->store->ScopeOpen(
          Text(Field(map, "token")), Text(Field(map, "key")),
          Integer(Field(map, "deadlineMicros")))));
    } else if (guarded && name == "scopeStop") {
      const auto& map = Arguments(args);
      const auto mode = Text(Field(map, "mode"));
      if (mode != "pause" && mode != "cancel")
        Invalid(SelectedFileError::invalid_scope);
      result->Success(Value(shared_->store->ScopeStop(
          Text(Field(map, "scope")),
          mode == "pause" ? SourceStopMode::pause : SourceStopMode::cancel)));
    } else if (guarded && name == "scopeClose") {
      shared_->store->ScopeClose(Token(args));
      result->Success();
    } else if (!guarded && name == "release") {
      shared_->store->Release(Token(args));
      RequestCleanup();
      result->Success();
    } else if ((guarded && (name == "beginPass" || name == "readPass" ||
                            name == "finishPass")) ||
               (!guarded &&
                (name == "beginReadPass" || name == "readPass" ||
                 name == "finishPass" || name == "read" || name == "finish"))) {
      const bool begin = name == "beginPass" || name == "beginReadPass";
      const bool read = name == "readPass" || name == "read";
      std::string token, scope, pass;
      int64_t offset = 0, length = 0;
      if (!guarded && (name == "beginReadPass" || name == "finish"))
        token = Token(args);
      else {
        const auto& map = Arguments(args);
        token = Text(Field(map, "token"));
        if (guarded) scope = Text(Field(map, "scope"));
        if (name == "readPass" || name == "finishPass")
          pass = Text(Field(map, "passId"));
        if (read) {
          offset = Integer(Field(map, "offset"));
          length = Integer(Field(map, "length"));
          if (offset < 0 || length <= 0 ||
              length > SelectedFileStore::kMaximumChunk)
            Invalid();
        }
      }
      std::vector<std::string> keys{"e:" + token};
      if (guarded) keys.push_back("s:" + scope);
      Queue(
          [token, scope, pass, offset, length, guarded, begin, read,
           name](SelectedFileStore& store) {
            if (begin)
              return Value(guarded ? store.BeginPass(token, scope)
                                   : store.BeginReadPass(token));
            if (read) {
              if (guarded)
                return Value(store.ReadPass(token, scope, pass, offset,
                                            static_cast<int>(length)));
              return Value(
                  name == "read"
                      ? store.Read(token, offset, static_cast<int>(length))
                      : store.ReadPass(token, pass, offset,
                                       static_cast<int>(length)));
            }
            if (guarded)
              store.FinishPass(token, scope, pass);
            else if (name == "finish")
              store.Finish(token);
            else
              store.FinishPass(token, pass);
            return Value();
          },
          std::move(result), guarded, std::move(keys),
          [token, scope, pass, begin](SelectedFileStore& store,
                                      const Value& value) {
            store.ValidateCompletion(
                token, scope, begin ? std::get<std::string>(value) : pass);
          });
    } else
      result->NotImplemented();
  } catch (const SelectedFileException& e) {
    if (result) Failure(*result, Code(e.reason()), guarded);
  } catch (...) {
    if (result) Failure(*result, "source_unavailable", guarded);
  }
  return true;
}
void SourceBridge::Pump() {
  if (closed_) return;
  std::deque<Shared::Completion> completions;
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    completions.swap(shared_->completions);
  }
  for (auto& done : completions) {
    auto it = pending_.find(done.id);
    if (it == pending_.end()) continue;
    auto result = std::move(it->second);
    pending_.erase(it);
    if (done.error.empty() && done.check) {
      try {
        done.check(*shared_->store, done.value);
      } catch (const SelectedFileException& e) {
        done.error = Code(e.reason());
      } catch (...) {
        done.error = "source_unavailable";
      }
    }
    if (done.error.empty())
      result->Success(done.value);
    else
      Failure(*result, done.error, done.guarded);
  }
}
void SourceBridge::Close() {
  if (closed_) return;
  closed_ = true;
  shared_->store->Shutdown();
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->closed = true;
    shared_->jobs.clear();
    shared_->completions.clear();
  }
  shared_->changed.notify_all();
  auto replies = std::move(pending_);
  for (auto& pair : replies)
    pair.second->Error("closed", "Selected file access closed.");
}
void SourceBridge::WaitForWorkers() {
  std::unique_lock<std::mutex> lock(shared_->mutex);
  shared_->changed.wait(lock, [&] { return shared_->workers == 0; });
}
}  // namespace share_hub
