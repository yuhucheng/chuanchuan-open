#include <flutter/method_result_functions.h>
#include <objbase.h>

#include <chrono>
#include <condition_variable>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

#include "source_bridge.h"
#include "file_drop_session.h"
using namespace share_hub;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
namespace {
void Require(bool yes, const char* message) {
  if (!yes) throw std::runtime_error(message);
}
struct Answer {
  bool done = false;
  Value value;
  std::string error;
  DWORD thread = 0;
};
std::unique_ptr<SourceBridge::Result> Reply(Answer& a) {
  return std::make_unique<flutter::MethodResultFunctions<Value>>(
      [&a](const Value* v) {
        a.done = true;
        a.thread = GetCurrentThreadId();
        if (v) a.value = *v;
      },
      [&a](const std::string& e, const std::string&, const Value*) {
        a.done = true;
        a.error = e;
        a.thread = GetCurrentThreadId();
      },
      [&a] {
        a.done = true;
        a.error = "not_implemented";
      });
}
void Call(SourceBridge& b, const std::string& method, Value args, Answer& a) {
  auto result = Reply(a);
  Require(b.Handle(flutter::MethodCall<Value>(
                       method, std::make_unique<Value>(std::move(args))),
                   result),
          "source route recognized");
}
void Await(SourceBridge& b, Answer& a) {
  for (int i = 0; i < 500 && !a.done; ++i) {
    b.Pump();
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  Require(a.done, "source completion timeout");
}
std::string Text(const Answer& a) {
  Require(a.error.empty(), a.error.c_str());
  return std::get<std::string>(a.value);
}
struct Fixture {
  std::wstring dir, path;
  SourceBridge bridge;
  explicit Fixture(SelectedFileStoreOptions options = {})
      : bridge(nullptr, std::move(options)) {
    wchar_t tmp[MAX_PATH], id[40];
    GUID guid{};
    GetTempPathW(MAX_PATH, tmp);
    CoCreateGuid(&guid);
    StringFromGUID2(guid, id, 40);
    dir = std::wstring(tmp) + L"source-bridge-" + id;
    CreateDirectoryW(dir.c_str(), nullptr);
    path = dir + L"\\data";
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                           0, nullptr);
    Require(h != INVALID_HANDLE_VALUE, "fixture open");
    DWORD n = 0;
    WriteFile(h, "abcdef", 6, &n, nullptr);
    CloseHandle(h);
  }
  ~Fixture() {
    bridge.Close();
    bridge.WaitForWorkers();
    DeleteFileW(path.c_str());
    RemoveDirectoryW(dir.c_str());
  }
  std::string Pick() {
    Answer a;
    bridge.AcceptPickedFiles({path}, Reply(a));
    Await(bridge, a);
    Require(a.error.empty(), "native picker selection available");
    return std::get<std::string>(
        std::get<Map>(std::get<List>(a.value).front()).at(Value("token")));
  }
  std::string Scope(const std::string& token) {
    Answer a;
    Call(bridge, "files.source.scopeOpen",
         Value(Map{{Value("token"), Value(token)},
                   {Value("key"), Value("key")},
                   {Value("deadlineMicros"), Value(INT64_MAX)}}),
         a);
    Require(a.done, "scope open synchronous");
    return Text(a);
  }
  std::string Pass(const std::string& token, const std::string& scope) {
    Answer a;
    Call(bridge, "files.source.beginPass", Args(token, scope), a);
    Await(bridge, a);
    return Text(a);
  }
  static Value Args(const std::string& token, const std::string& scope,
                    const std::string& pass = {}, int64_t offset = 0,
                    int64_t length = 3) {
    Map m{{Value("token"), Value(token)}, {Value("scope"), Value(scope)}};
    if (!pass.empty()) {
      m.emplace(Value("passId"), Value(pass));
      m.emplace(Value("offset"), Value(offset));
      m.emplace(Value("length"), Value(length));
    }
    return Value(m);
  }
};
void ChannelAndFifo() {
  Fixture f;
  auto token = f.Pick();
  auto scope = f.Scope(token);
  auto pass = f.Pass(token, scope);
  Answer first, second, finish;
  Call(f.bridge, "files.source.readPass", Fixture::Args(token, scope, pass, 0),
       first);
  Call(f.bridge, "files.source.readPass", Fixture::Args(token, scope, pass, 3),
       second);
  Call(f.bridge, "files.source.finishPass", Fixture::Args(token, scope, pass),
       finish);
  Await(f.bridge, finish);
  Require(first.done && second.done && finish.error.empty(),
          "FIFO read before finish");
  Require(std::get<std::vector<uint8_t>>(first.value) ==
              std::vector<uint8_t>({'a', 'b', 'c'}),
          "first real bytes");
  Require(std::get<std::vector<uint8_t>>(second.value) ==
              std::vector<uint8_t>({'d', 'e', 'f'}),
          "second real bytes");
  Require(first.thread == GetCurrentThreadId(), "UI delivery only");
  Answer bad;
  Call(f.bridge, "files.source.readPass",
       Value(Map{{Value("token"), Value(token)},
                 {Value("scope"), Value(scope)},
                 {Value("passId"), Value(pass)},
                 {Value("offset"), Value(true)},
                 {Value("length"), Value(1)}}),
       bad);
  Require(bad.error == "invalid_read", "bool integer rejected");
}
void StopQueuedAndLate() {
  std::mutex m;
  std::condition_variable cv;
  bool entered = false, go = false;
  int reads = 0;
  SelectedFileStoreOptions o;
  o.io = [&](SourceIo op) {
    if (op != SourceIo::read) return;
    std::unique_lock<std::mutex> lock(m);
    ++reads;
    entered = true;
    cv.notify_all();
    cv.wait(lock, [&] { return go; });
  };
  Fixture f(o);
  auto token = f.Pick();
  auto scope = f.Scope(token);
  auto pass = f.Pass(token, scope);
  struct Unblock {
    std::function<void()> run;
    ~Unblock() { run(); }
  } unblock{[&] {
    std::lock_guard<std::mutex> lock(m);
    go = true;
    cv.notify_all();
  }};
  Answer first, next;
  Call(f.bridge, "files.source.readPass", Fixture::Args(token, scope, pass, 0),
       first);
  Call(f.bridge, "files.source.readPass", Fixture::Args(token, scope, pass, 3),
       next);
  {
    std::unique_lock<std::mutex> lock(m);
    Require(cv.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }),
            "data call entered");
  }
  Answer stop;
  Call(f.bridge, "files.source.scopeStop",
       Value(Map{{Value("scope"), Value(scope)},
                 {Value("mode"), Value("cancel")}}),
       stop);
  Require(stop.done && Text(stop) == "cancelled", "stop bypasses I/O queue");
  {
    std::lock_guard<std::mutex> lock(m);
    go = true;
    cv.notify_all();
  }
  Await(f.bridge, next);
  Require(first.error == "stopped" && next.error == "stopped" && reads == 1,
          "queued and admitted late reads rejected");
}
void PendingBoundAndFastClose() {
  Fixture f;
  auto token = f.Pick();
  auto scope = f.Scope(token);
  auto pass = f.Pass(token, scope);
  std::vector<Answer> answers(65);
  for (auto& a : answers)
    Call(f.bridge, "files.source.finishPass", Fixture::Args(token, scope, pass),
         a);
  Require(answers.back().done && answers.back().error == "resource_limit",
          "undelivered results count toward bound");
  Answer stop;
  Call(f.bridge, "files.source.scopeStop",
       Value(Map{{Value("scope"), Value(scope)},
                 {Value("mode"), Value("cancel")}}),
       stop);
  Require(Text(stop) == "cancelled", "full queue stop works");
  f.bridge.Close();
  for (size_t i = 0; i < 64; ++i)
    Require(answers[i].done && answers[i].error == "closed",
            "close replies exactly once");
}
void CompletedReadStoppedBeforeUiDelivery() {
  std::mutex mutex;
  std::condition_variable changed;
  bool armed = false, entered = false, go = false;
  int metadata = 0;
  SelectedFileStoreOptions options;
  options.io = [&](SourceIo op) {
    if (!armed || op != SourceIo::metadata) return;
    std::unique_lock<std::mutex> lock(mutex);
    // A read makes two six-query identity checks. The following finish's first
    // query proves the read has completed and its result is awaiting UI Pump.
    if (++metadata == 13) {
      entered = true;
      changed.notify_all();
      changed.wait(lock, [&] { return go; });
    }
  };
  Fixture f(options);
  auto token = f.Pick();
  auto scope = f.Scope(token);
  auto pass = f.Pass(token, scope);
  struct Unblock {
    std::function<void()> run;
    ~Unblock() { run(); }
  } unblock{[&] {
    std::lock_guard<std::mutex> lock(mutex);
    go = true;
    changed.notify_all();
  }};
  armed = true;
  Answer read, finish;
  Call(f.bridge, "files.source.readPass",
       Fixture::Args(token, scope, pass, 0, 6), read);
  Call(f.bridge, "files.source.finishPass", Fixture::Args(token, scope, pass),
       finish);
  {
    std::unique_lock<std::mutex> lock(mutex);
    Require(changed.wait_for(lock, std::chrono::seconds(5),
                             [&] { return entered; }),
            "read completed before UI pump");
  }
  Answer stop;
  Call(f.bridge, "files.source.scopeStop",
       Value(Map{{Value("scope"), Value(scope)},
                 {Value("mode"), Value("pause")}}),
       stop);
  f.bridge.Pump();
  const bool rejected = read.done && read.error == "stopped";
  {
    std::lock_guard<std::mutex> lock(mutex);
    go = true;
    changed.notify_all();
  }
  Await(f.bridge, finish);
  Require(rejected,
          "completed read cannot succeed after native stop before UI delivery");
}
void CloseDoesNotJoinBlockedWorker() {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false, go = false;
  SelectedFileStoreOptions options;
  options.io = [&](SourceIo op) {
    if (op != SourceIo::read) return;
    std::unique_lock<std::mutex> lock(mutex);
    entered = true;
    changed.notify_all();
    changed.wait(lock, [&] { return go; });
  };
  Fixture f(options);
  auto token = f.Pick();
  auto scope = f.Scope(token);
  auto pass = f.Pass(token, scope);
  struct Unblock {
    std::function<void()> run;
    ~Unblock() { run(); }
  } unblock{[&] {
    std::lock_guard<std::mutex> lock(mutex);
    go = true;
    changed.notify_all();
  }};
  Answer read;
  Call(f.bridge, "files.source.readPass", Fixture::Args(token, scope, pass),
       read);
  {
    std::unique_lock<std::mutex> lock(mutex);
    Require(changed.wait_for(lock, std::chrono::seconds(5),
                             [&] { return entered; }),
            "read blocked before close");
  }
  // A watchdog frees the syscall only if Close incorrectly joins it. The result
  // asserts that Close returned before the watchdog had to rescue the test.
  bool rescued = false;
  bool close_returned = false;
  std::thread watchdog([&] {
    std::unique_lock<std::mutex> lock(mutex);
    if (!changed.wait_for(lock, std::chrono::milliseconds(300),
                          [&] { return close_returned; })) {
      rescued = true;
      go = true;
      changed.notify_all();
    }
  });
  f.bridge.Close();
  {
    std::lock_guard<std::mutex> lock(mutex);
    close_returned = true;
    changed.notify_all();
  }
  watchdog.join();
  Require(!rescued && read.done && read.error == "closed" &&
              read.thread == GetCurrentThreadId(),
          "close gates and replies on UI without joining worker");
  {
    std::lock_guard<std::mutex> lock(mutex);
    go = true;
    changed.notify_all();
  }
  f.bridge.WaitForWorkers();
  f.bridge.Pump();
  Require(read.error == "closed", "late worker cannot deliver after close");
}
}  // namespace
void DropOwnership() {
  Fixture f;
  Value offered;
  FileDropSession::Decision decision;
  int errors = 0, offers = 0;
  FileDropSession drops(f.bridge,
      [](double, double, FileDropSession::Decision reply) { reply(true); },
      [&](Value value, FileDropSession::Decision reply) {
        offered = std::move(value); decision = std::move(reply); ++offers;
      }, [&] { ++errors; });
  auto wait = [&](const std::function<bool()>& done) {
    for (int i = 0; i < 500 && !done(); ++i) {
      f.bridge.Pump(); std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    Require(done(), "drop completion timeout");
  };
  Require(!drops.Accept({f.path}, 4, 8), "unlistened drop rejected");
  drops.Listen();
  Require(drops.Accept({f.path}, 4, 8), "authorized OS drop admitted");
  Require(!drops.Accept({f.path}, 4, 8), "one outstanding offer bound");
  wait([&] { return offers == 1; });
  const auto& map = std::get<Map>(offered);
  Require(std::get<double>(map.at(Value("x"))) == 4, "logical position preserved");
  auto token = std::get<std::string>(std::get<Map>(std::get<List>(map.at(Value("files"))).front()).at(Value("token")));
  Require(map.size() == 3, "no native paths exposed");
  decision(false);
  Answer rejected;
  Call(f.bridge, "files.read", Value(Map{{Value("token"), Value(token)},
       {Value("offset"), Value(0)}, {Value("length"), Value(1)}}), rejected);
  Await(f.bridge, rejected);
  Require(!rejected.error.empty(), "Dart rejection revokes token");
  drops.Accept({f.path}, 1, 2);
  wait([&] { return offers == 2; });
  token = std::get<std::string>(std::get<Map>(std::get<List>(std::get<Map>(offered).at(Value("files"))).front()).at(Value("token")));
  drops.Cancel();
  decision(true); // Dart already owns it even if cancellation crosses the reply.
  Answer retained;
  Call(f.bridge, "files.read", Value(Map{{Value("token"), Value(token)},
       {Value("offset"), Value(0)}, {Value("length"), Value(1)}}), retained);
  Await(f.bridge, retained);
  Require(retained.error.empty(), "accepted token survives listening cancellation");
  Answer released;
  Call(f.bridge, "files.release", Value(token), released);
  drops.Listen();
  drops.Accept({f.path}, 1, 2);
  drops.Cancel();
  drops.Listen();
  wait([&] { return drops.ready(); });
  Require(offers == 2, "cancelled generation cannot deliver into new listener");
  // If cancellation leaked a token, 64 fresh capabilities would exceed store capacity.
  drops.Accept(std::vector<std::wstring>(64, f.path), 1, 2);
  wait([&] { return offers == 3 || errors != 0; });
  Require(offers == 3 && errors == 0, "cancelled preparation releases all native capacity");
  decision(false);
  drops.Accept({f.dir}, 1, 2);
  wait([&] { return errors == 1; });
  Require(drops.ready(), "folder rejection releases busy state");
  drops.Close();
  Require(!drops.Accept({f.path}, 1, 2), "closed drop session rejects new work");
}
int main() {
  int failures = 0;
  for (auto test :
       {ChannelAndFifo, StopQueuedAndLate, PendingBoundAndFastClose,
        CompletedReadStoppedBeforeUiDelivery, CloseDoesNotJoinBlockedWorker, DropOwnership}) {
    try {
      test();
    } catch (const std::exception& e) {
      ++failures;
      std::cerr << "FAIL: " << e.what() << '\n';
    }
  }
  std::cout << "source-bridge groups=6 failures=" << failures << '\n';
  return failures ? 1 : 0;
}
