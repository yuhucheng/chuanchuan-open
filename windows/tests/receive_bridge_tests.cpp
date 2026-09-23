#include "receive_bridge.h"
#include <flutter/method_result_functions.h>
#include <windows.h>
#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
void Require(bool value, const char* label) {
  if (!value) throw std::runtime_error(label);
}
struct Answer {
  bool done = false;
  Value value;
  std::string error;
  DWORD thread = 0;
};
void Call(share_hub::ReceiveBridge& bridge, const std::string& method,
          Value args, Answer& answer) {
  std::unique_ptr<Result> result = std::make_unique<flutter::MethodResultFunctions<Value>>(
      [&answer](const Value* value) {
        answer.thread = GetCurrentThreadId(); answer.done = true;
        if (value) answer.value = *value;
      },
      [&answer](const std::string& code, const std::string&, const Value*) {
        answer.thread = GetCurrentThreadId(); answer.done = true; answer.error = code;
      }, [&answer]() { answer.done = true; answer.error = "not_implemented"; });
  flutter::MethodCall<Value> call("files.receive." + method,
                                std::make_unique<Value>(std::move(args)));
  Require(bridge.Handle(call, result), "recognized receive method");
  Require(!result, "bridge owns result");
}
void Await(share_hub::ReceiveBridge& bridge, Answer& answer) {
  const auto end = GetTickCount64() + 5000;
  while (!answer.done && GetTickCount64() < end) {
    bridge.Pump();
    std::this_thread::yield();
  }
  Require(answer.done, "UI completion timeout");
}
std::string Text(const Answer& answer) {
  Require(answer.error.empty(), "native operation failed");
  return std::get<std::string>(answer.value);
}
struct Fixture {
  static std::atomic<unsigned> next_id;
  std::filesystem::path path;
  share_hub::ReceiveBridge bridge;
  explicit Fixture(share_hub::ReceiveStoreOptions options)
      : path(std::filesystem::temp_directory_path() /
             (L"share-hub-bridge-" + std::to_wstring(GetCurrentProcessId()) +
              L"-" + std::to_wstring(GetTickCount64()) + L"-" +
              std::to_wstring(next_id.fetch_add(1)))),
        bridge(nullptr, std::move(options)) {
    Require(std::filesystem::create_directory(path), "owned test directory");
  }
  ~Fixture() {
    bridge.Close(); bridge.WaitForWorkers();
    std::error_code ignored; std::filesystem::remove_all(path, ignored);
  }
  std::string Directory() {
    Answer answer;
    std::unique_ptr<Result> result = std::make_unique<flutter::MethodResultFunctions<Value>>(
        [&answer](const Value* value) { answer.done = true; answer.value = *value; },
        [&answer](const std::string& code, const std::string&, const Value*) {
          answer.done = true; answer.error = code;
        }, nullptr);
    bridge.AcceptPickedDirectory(path.wstring(), std::move(result));
    Await(bridge, answer); Require(answer.error.empty(), "directory accepted");
    return std::get<std::string>(std::get<Map>(answer.value).at(Value("token")));
  }
  std::string Scope(const std::string& key = "grant/sender/transfer") {
    Answer answer;
    Call(bridge, "scopeOpen", Value(Map{{Value("key"), Value(key)},
      {Value("deadlineMicros"), Value(int64_t{1000000})}}), answer);
    Require(answer.done, "scope open immediate"); return Text(answer);
  }
};
std::atomic<unsigned> Fixture::next_id{0};
share_hub::ReceiveStoreOptions Options() {
  share_hub::ReceiveStoreOptions options;
  options.clock = [](uint64_t* value) { *value = 100; return true; };
  return options;
}
void RoundTripAndValidation() {
  Fixture f(Options()); const auto ui = GetCurrentThreadId();
  const auto directory = f.Directory(), scope = f.Scope();
  Answer begin;
  Call(f.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
      {Value("scope"), Value(scope)}, {Value("name"), Value("empty.bin")},
      {Value("size"), Value(int64_t{0})}, {Value("sha256"), Value(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")}}), begin);
  Await(f.bridge, begin); const auto token = Text(begin);
  Require(begin.thread == ui, "begin callback on UI");
  Answer commit;
  Call(f.bridge, "commit", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}}), commit);
  Await(f.bridge, commit); Require(commit.error.empty(), "commit success");
  Require(commit.thread == ui, "commit callback on UI");
  Require(std::get<std::string>(std::get<Map>(commit.value).at(Value("name"))) ==
      "empty.bin", "actual saved name");
  Require(std::filesystem::exists(f.path / "empty.bin"), "actual published file");
  Answer stop;
  Call(f.bridge, "scopeStop", Value(Map{{Value("scope"), Value(scope)},
      {Value("mode"), Value("cancel")}}), stop);
  Require(Text(stop) == "committed", "stop tells committed truth");
  Answer bad;
  Call(f.bridge, "append", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}, {Value("offset"), Value(int64_t{0})},
      {Value("bytes"), Value(std::vector<uint8_t>(32769, 1))}}), bad);
  Require(bad.done && bad.error == "invalid_range", "oversize rejected before queue");
  Answer path;
  Call(f.bridge, "directoryConfigured", Value(f.path.u8string()), path);
  Require(path.done && path.error == "invalid_range", "no arbitrary path argument");
}
void NativeStorageFailuresReachChannel() {
  auto full = Options();
  full.free_bytes = [](uint64_t, uint64_t* bytes) {
    *bytes = 0; return true;
  };
  Fixture disk(std::move(full));
  const auto disk_directory = disk.Directory(), disk_scope = disk.Scope();
  Answer denied_begin;
  Call(disk.bridge, "begin", Value(Map{{Value("directory"), Value(disk_directory)},
      {Value("scope"), Value(disk_scope)}, {Value("name"), Value("full.bin")},
      {Value("size"), Value(int64_t{1})}, {Value("sha256"), Value(
      "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")}}), denied_begin);
  Await(disk.bridge, denied_begin);
  Require(denied_begin.error == "disk_full", "bridge preserves native disk-full code");
  Require(!std::filesystem::exists(disk.path / "full.bin"), "disk-full never publishes file");

  auto denied = Options();
  denied.io = [](share_hub::ReceiveIo operation, uintptr_t, size_t) {
    share_hub::ReceiveIoDirective result;
    if (operation == share_hub::ReceiveIo::flush) result.error = ERROR_ACCESS_DENIED;
    return result;
  };
  Fixture permissions(std::move(denied));
  const auto directory = permissions.Directory(), scope = permissions.Scope();
  Answer begin;
  Call(permissions.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
      {Value("scope"), Value(scope)}, {Value("name"), Value("denied.bin")},
      {Value("size"), Value(int64_t{0})}, {Value("sha256"), Value(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")}}), begin);
  Await(permissions.bridge, begin);
  const auto token = Text(begin);
  Answer commit;
  Call(permissions.bridge, "commit", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}}), commit);
  Await(permissions.bridge, commit);
  Require(commit.error == "permission_denied", "bridge preserves native permission code");
  Require(!std::filesystem::exists(permissions.path / "denied.bin"),
          "permission failure never publishes file");
}
void StopBypassesBlockedWorkerAndBoundedCompletions() {
  std::mutex mutex; std::condition_variable condition;
  bool entered = false, released = false;
  auto options = Options();
  options.io = [&](share_hub::ReceiveIo operation, uintptr_t, size_t) {
    if (operation == share_hub::ReceiveIo::flush) {
      std::unique_lock<std::mutex> lock(mutex);
      entered = true; condition.notify_all();
      condition.wait(lock, [&] { return released; });
    }
    return share_hub::ReceiveIoDirective{};
  };
  Fixture f(std::move(options));
  const auto directory = f.Directory(), scope = f.Scope();
  Answer begin;
  Call(f.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
      {Value("scope"), Value(scope)}, {Value("name"), Value("cancel.bin")},
      {Value("size"), Value(int64_t{0})}, {Value("sha256"), Value(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")}}), begin);
  Await(f.bridge, begin); const auto token = Text(begin);
  Answer commit;
  Call(f.bridge, "commit", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}}), commit);
  { std::unique_lock<std::mutex> lock(mutex);
    Require(condition.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }),
            "commit reached deterministic disk barrier"); }
  Answer stop;
  Call(f.bridge, "scopeStop", Value(Map{{Value("scope"), Value(scope)},
      {Value("mode"), Value("cancel")}}), stop);
  Require(stop.done && Text(stop) == "cancelled", "stop bypasses disk worker");
  std::vector<Answer> queued(64);
  for (auto& answer : queued) Call(f.bridge, "release", Value("unknown"), answer);
  Require(queued.back().done && queued.back().error == "resource_limit",
          "64 outstanding includes active work and undrained completions");
  f.bridge.Close();
  Require(commit.done && commit.error == "closed", "close completes pending on UI");
  { std::lock_guard<std::mutex> lock(mutex); released = true; condition.notify_all(); }
  f.bridge.WaitForWorkers(); f.bridge.Pump();
  Require(commit.error == "closed", "late result cannot touch Flutter callback");
  Require(!std::filesystem::exists(f.path / "cancel.bin"), "cancelled never published");
}
void AbortCleansWithoutAnotherTransfer() {
  Fixture f(Options());
  const auto directory = f.Directory(), scope = f.Scope();
  Answer begin;
  Call(f.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
      {Value("scope"), Value(scope)}, {Value("name"), Value("cleanup.bin")},
      {Value("size"), Value(int64_t{0})}, {Value("sha256"), Value(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")}}), begin);
  Await(f.bridge, begin);
  Require(!std::filesystem::is_empty(f.path), "owned partial file exists");
  Answer abort;
  Call(f.bridge, "abort", Value(Text(begin)), abort);
  Require(abort.done && abort.error.empty(), "abort gates immediately");
  const auto end = GetTickCount64() + 3000;
  while (!std::filesystem::is_empty(f.path) && GetTickCount64() < end) {
    f.bridge.Pump(); std::this_thread::yield();
  }
  Require(std::filesystem::is_empty(f.path), "abort schedules cleanup without new Begin or shutdown");
}
void AppendCheckpointResumeAndOldScopeClose() {
  Fixture f(Options());
  const auto directory = f.Directory(), scope = f.Scope();
  Answer begin;
  Call(f.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
      {Value("scope"), Value(scope)}, {Value("name"), Value("abc.bin")},
      {Value("size"), Value(int64_t{3})}, {Value("sha256"), Value(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")}}), begin);
  Await(f.bridge, begin); const auto token = Text(begin);
  Answer first, second, checkpoint;
  Call(f.bridge, "append", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}, {Value("offset"), Value(int64_t{0})},
      {Value("bytes"), Value(std::vector<uint8_t>{'a'})}}), first);
  Call(f.bridge, "append", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(scope)}, {Value("offset"), Value(int64_t{1})},
      {Value("bytes"), Value(std::vector<uint8_t>{'b'})}}), second);
  Call(f.bridge, "checkpoint", Value(token), checkpoint);
  Await(f.bridge, checkpoint);
  Require(first.done && second.done && first.error.empty() && second.error.empty(),
          "same-file appends delivered in submission order");
  Require(std::get<int64_t>(first.value) == 1 && std::get<int64_t>(second.value) == 2,
          "exact append offsets");
  auto proof = std::get<Map>(checkpoint.value);
  Require(std::get<int64_t>(proof.at(Value("offset"))) == 2,
          "checkpoint follows queued appends");
  Answer pause;
  Call(f.bridge, "scopeStop", Value(Map{{Value("scope"), Value(scope)},
      {Value("mode"), Value("pause")}}), pause);
  Require(Text(pause) == "paused", "paused before resume");
  const auto fresh = f.Scope();
  proof[Value("token")] = Value(token); proof[Value("scope")] = Value(fresh);
  Answer resumed;
  Call(f.bridge, "resume", Value(proof), resumed); Await(f.bridge, resumed);
  Require(resumed.error.empty(), "original prefix restored");
  Answer closed;
  Call(f.bridge, "scopeClose", Value(scope), closed);
  Require(closed.done && closed.error.empty(), "old scope retired");
  Answer last, committed;
  Call(f.bridge, "append", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(fresh)}, {Value("offset"), Value(int64_t{2})},
      {Value("bytes"), Value(std::vector<uint8_t>{'c'})}}), last);
  Call(f.bridge, "commit", Value(Map{{Value("token"), Value(token)},
      {Value("scope"), Value(fresh)}}), committed);
  Await(f.bridge, committed);
  Require(last.error.empty() && committed.error.empty(), "new scope remains usable");
  Require(std::filesystem::file_size(f.path / "abc.bin") == 3, "full file committed");
  Answer release;
  Call(f.bridge, "release", Value(token), release); Await(f.bridge, release);
  Require(release.error.empty() && std::filesystem::exists(f.path / "abc.bin"),
          "metadata release preserves final file");
}
void CleanupPrecedesPublicBacklog() {
  std::mutex mutex; std::condition_variable condition;
  int entered = 0;
  bool released[2]{false, false}, clean_before_backlog = false;
  std::filesystem::path directory_path;
  auto options = Options();
  options.io = [&](share_hub::ReceiveIo operation, uintptr_t, size_t) {
    if (operation == share_hub::ReceiveIo::flush) {
      std::unique_lock<std::mutex> lock(mutex);
      const auto index = entered++;
      if (index == 2) {
        clean_before_backlog = std::distance(std::filesystem::directory_iterator(directory_path),
                                            std::filesystem::directory_iterator{}) == 3;
      }
      condition.notify_all();
      if (index < 2) condition.wait(lock, [&] { return released[index]; });
    }
    return share_hub::ReceiveIoDirective{};
  };
  Fixture f(std::move(options)); directory_path = f.path;
  struct Unblock {
    std::function<void()> run;
    ~Unblock() { run(); }
  } unblock{[&] {
    std::lock_guard<std::mutex> lock(mutex);
    released[0] = released[1] = true; condition.notify_all();
  }};
  const auto directory = f.Directory();
  std::string scopes[4], tokens[4];
  for (int index = 0; index < 4; ++index) {
    scopes[index] = f.Scope("transfer-" + std::to_string(index));
    Answer begin;
    Call(f.bridge, "begin", Value(Map{{Value("directory"), Value(directory)},
        {Value("scope"), Value(scopes[index])}, {Value("name"), Value(std::to_string(index) + ".bin")},
        {Value("size"), Value(int64_t{0})}, {Value("sha256"), Value(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")}}), begin);
    Await(f.bridge, begin); tokens[index] = Text(begin);
  }
  Answer commits[3];
  for (int index = 0; index < 2; ++index) {
    Call(f.bridge, "commit", Value(Map{{Value("token"), Value(tokens[index])},
        {Value("scope"), Value(scopes[index])}}), commits[index]);
  }
  { std::unique_lock<std::mutex> lock(mutex);
    Require(condition.wait_for(lock, std::chrono::seconds(5), [&] { return entered == 2; }),
            "both workers blocked before backlog"); }
  Answer abort;
  Call(f.bridge, "abort", Value(tokens[2]), abort);
  Call(f.bridge, "commit", Value(Map{{Value("token"), Value(tokens[3])},
      {Value("scope"), Value(scopes[3])}}), commits[2]);
  { std::unique_lock<std::mutex> lock(mutex);
    released[0] = true; condition.notify_all();
    Require(condition.wait_for(lock, std::chrono::seconds(5), [&] { return entered == 3; }),
            "backlog executed after one worker freed"); }
  Require(clean_before_backlog, "cancel cleanup cannot be starved by public backlog");
  { std::lock_guard<std::mutex> lock(mutex); released[1] = true; condition.notify_all(); }
  for (auto& answer : commits) { Await(f.bridge, answer); Require(answer.error.empty(), "unrelated commits survive cleanup"); }
}
}  // namespace
int main() {
  try {
    RoundTripAndValidation(); NativeStorageFailuresReachChannel();
    StopBypassesBlockedWorkerAndBoundedCompletions();
    AbortCleansWithoutAnotherTransfer();
    AppendCheckpointResumeAndOldScopeClose();
    CleanupPrecedesPublicBacklog();
    std::cout << "Receive bridge: real storage, UI dispatch, bounded queue, cancellation and shutdown passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n'; return 1;
  }
}
