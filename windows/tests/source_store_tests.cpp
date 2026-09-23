#include <objbase.h>
#include <windows.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

#include "selected_file_store.h"
using namespace share_hub;
namespace {
void Require(bool yes, const char* label) {
  if (!yes) throw std::runtime_error(label);
}
template <class F>
void Reject(F work, SelectedFileError expected) {
  try {
    work();
  } catch (const SelectedFileException& e) {
    Require(e.reason() == expected, "wrong rejection");
    return;
  }
  throw std::runtime_error("expected source rejection");
}
struct Fixture {
  std::wstring dir, path;
  Fixture() {
    wchar_t tmp[MAX_PATH], id[40];
    GUID guid{};
    GetTempPathW(MAX_PATH, tmp);
    CoCreateGuid(&guid);
    StringFromGUID2(guid, id, 40);
    dir = std::wstring(tmp) + L"share-hub-source-" + id;
    Require(CreateDirectoryW(dir.c_str(), nullptr) != 0, "fixture directory");
    path = dir + L"\\source.bin";
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    Require(h != INVALID_HANDLE_VALUE, "fixture open");
    DWORD n = 0;
    const bool ok = WriteFile(h, "abcdef", 6, &n, nullptr) != 0;
    CloseHandle(h);
    Require(ok && n == 6, "fixture bytes");
  }
  ~Fixture() {
    DeleteFileW(path.c_str());
    RemoveDirectoryW(dir.c_str());
  }
  bool Exclusive() {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr,
                           OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    CloseHandle(h);
    return true;
  }
};
SelectedFileStoreOptions Clock(std::atomic<uint64_t>& now) {
  SelectedFileStoreOptions o;
  o.clock = [&](uint64_t* out) {
    *out = now.load();
    return true;
  };
  return o;
}
void GuardedPassAndRebind() {
  Fixture f;
  std::atomic<uint64_t> now{10};
  SelectedFileStore s(Clock(now));
  auto token = s.AddPickerPaths({f.path})[0].token;
  auto legacy = s.BeginReadPass(token);
  auto scope = s.ScopeOpen(token, "transfer", 100);
  Reject([&] { s.Read(token, 0, 1); }, SelectedFileError::invalid_read);
  Reject([&] { s.Finish(token); }, SelectedFileError::invalid_read);
  Reject([&] { s.BeginReadPass(token); }, SelectedFileError::invalid_read);
  Reject([&] { s.ReadPass(token, legacy, 0, 1); },
         SelectedFileError::invalid_read);
  Reject([&] { s.FinishPass(token, legacy); }, SelectedFileError::invalid_read);
  auto pass = s.BeginPass(token, scope);
  Require(s.ReadPass(token, scope, pass, 0, 3) ==
              std::vector<uint8_t>({'a', 'b', 'c'}),
          "guarded first bytes");
  Reject([&] { s.FinishPass(token, scope, pass); },
         SelectedFileError::incomplete);
  Require(s.ScopeStop(scope, SourceStopMode::pause) == "paused", "pause");
  Reject([&] { s.ScopeOpen(token, "other", 100); },
         SelectedFileError::invalid_scope);
  Reject([&] { s.ScopeOpen(token, "transfer", 101); },
         SelectedFileError::invalid_scope);
  auto next = s.ScopeOpen(token, "transfer", 100);
  s.ScopeClose(scope);
  Reject([&] { s.ReadPass(token, next, pass, 3, 3); },
         SelectedFileError::invalid_read);
  auto fresh = s.BeginPass(token, next);
  Require(s.ReadPass(token, next, fresh, 0, 6).size() == 6,
          "rebind original handle");
  s.FinishPass(token, next, fresh);
  Require(s.ScopeStop(next, SourceStopMode::cancel) == "cancelled", "cancel");
  Require(s.ScopeStop(next, SourceStopMode::pause) == "cancelled",
          "cancel cannot become pause");
  Reject([&] { s.ScopeOpen(token, "transfer", 100); },
         SelectedFileError::stopped);
}
void DeadlineAndClock() {
  Fixture f;
  std::atomic<uint64_t> now{10};
  SelectedFileStore s(Clock(now));
  auto token = s.AddPickerPaths({f.path})[0].token;
  auto scope = s.ScopeOpen(token, "key", 20);
  auto pass = s.BeginPass(token, scope);
  now = 20;
  Reject([&] { s.ReadPass(token, scope, pass, 0, 1); },
         SelectedFileError::expired);
  now = 19;
  Reject([&] { s.BeginPass(token, scope); }, SelectedFileError::clock_failure);
  now = 10;
  SelectedFileStoreOptions o = Clock(now);
  bool works = true;
  o.clock = [&](uint64_t* p) {
    *p = now;
    return works;
  };
  SelectedFileStore failed(o);
  token = failed.AddPickerPaths({f.path})[0].token;
  scope = failed.ScopeOpen(token, "k", 100);
  works = false;
  Reject([&] { failed.BeginPass(token, scope); },
         SelectedFileError::clock_failure);
  works = true;
  Reject([&] { failed.BeginPass(token, scope); },
         SelectedFileError::clock_failure);
}
void StopBlockedReadAndDeferredRelease() {
  Fixture f;
  std::atomic<uint64_t> now{10};
  auto o = Clock(now);
  std::mutex m;
  std::condition_variable cv;
  bool blocked = false, go = false;
  std::atomic<int> reads{0};
  o.io = [&](SourceIo op) {
    if (op != SourceIo::read) return;
    ++reads;
    std::unique_lock<std::mutex> lock(m);
    blocked = true;
    cv.notify_all();
    cv.wait(lock, [&] { return go; });
  };
  SelectedFileStore s(o);
  auto token = s.AddPickerPaths({f.path})[0].token;
  auto scope = s.ScopeOpen(token, "key", 100);
  auto pass = s.BeginPass(token, scope);
  auto read = std::async(std::launch::async, [&] {
    Reject([&] { s.ReadPass(token, scope, pass, 0, 3); },
           SelectedFileError::stopped);
  });
  {
    std::unique_lock<std::mutex> lock(m);
    Require(cv.wait_for(lock, std::chrono::seconds(5), [&] { return blocked; }),
            "read admitted");
  }
  auto stop = std::async(std::launch::async, [&] {
    return s.ScopeStop(scope, SourceStopMode::cancel);
  });
  const bool fast = stop.wait_for(std::chrono::milliseconds(300)) ==
                    std::future_status::ready;
  s.Release(token);
  s.CleanupReleased();
  const bool held = !f.Exclusive();
  {
    std::lock_guard<std::mutex> lock(m);
    go = true;
    cv.notify_all();
  }
  read.get();
  Require(fast && stop.get() == "cancelled", "stop bypasses blocked I/O");
  Require(held, "release retains in-flight handle");
  s.CleanupReleased();
  Require(f.Exclusive(), "worker cleanup releases safe handle");
  Require(reads == 1, "only admitted data call occurs");
}
void ClosedCannotReviveAndIndependentFile() {
  Fixture f;
  std::atomic<uint64_t> now{10};
  SelectedFileStore s(Clock(now));
  auto a = s.AddPickerPaths({f.path, f.path});
  auto scope = s.ScopeOpen(a[0].token, "one", 100);
  s.ScopeClose(scope);
  Reject([&] { s.ScopeOpen(a[0].token, "one", 100); },
         SelectedFileError::stopped);
  auto other = s.ScopeOpen(a[1].token, "two", 100);
  auto pass = s.BeginPass(a[1].token, other);
  Require(s.ReadPass(a[1].token, other, pass, 0, 6).size() == 6,
          "unrelated source unaffected");
  s.FinishPass(a[1].token, other, pass);
}
void RetainedCleanupCountsCapacity() {
  Fixture f;
  std::mutex m;
  std::condition_variable cv;
  bool entered = false, go = false;
  SelectedFileStoreOptions o;
  o.io = [&](SourceIo op) {
    if (op != SourceIo::before_close) return;
    std::unique_lock<std::mutex> lock(m);
    entered = true;
    cv.notify_all();
    cv.wait(lock, [&] { return go; });
  };
  SelectedFileStore s(o);
  auto selected = s.AddPickerPaths(std::vector<std::wstring>(64, f.path));
  for (const auto& file : selected) s.Release(file.token);
  auto cleanup = std::async(std::launch::async, [&] { s.CleanupReleased(); });
  bool blocked = false;
  {
    std::unique_lock<std::mutex> lock(m);
    blocked =
        cv.wait_for(lock, std::chrono::seconds(2), [&] { return entered; });
  }
  bool bounded = false;
  try {
    s.AddPickerPaths({f.path});
  } catch (const SelectedFileException& e) {
    bounded = e.reason() == SelectedFileError::limit;
  }
  {
    std::lock_guard<std::mutex> lock(m);
    go = true;
    cv.notify_all();
  }
  cleanup.get();
  Require(blocked, "physical handle teardown seam reached");
  Require(bounded, "released handles retain capacity until physical close");
  Require(s.AddPickerPaths(std::vector<std::wstring>(64, f.path)).size() == 64,
          "cleanup restores capacity");
}
void LegacyUpgradeAndShutdownAdmission() {
  for (bool upgrade : {true, false}) {
    Fixture f;
    std::atomic<uint64_t> now{10};
    auto o = Clock(now);
    std::mutex m;
    std::condition_variable cv;
    bool armed = false, entered = false, go = false;
    int metadata = 0;
    o.io = [&](SourceIo op) {
      if (!armed || op != SourceIo::metadata) return;
      std::unique_lock<std::mutex> lock(m);
      ++metadata;
      if (metadata == 1) {
        entered = true;
        cv.notify_all();
        cv.wait(lock, [&] { return go; });
      }
    };
    SelectedFileStore s(o);
    auto token = s.AddPickerPaths({f.path})[0].token;
    armed = true;
    auto reading = std::async(std::launch::async, [&] {
      Reject([&] { s.Read(token, 0, 1); }, upgrade
                                               ? SelectedFileError::invalid_read
                                               : SelectedFileError::closed);
    });
    {
      std::unique_lock<std::mutex> lock(m);
      Require(
          cv.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }),
          "first metadata admitted");
    }
    if (upgrade)
      s.ScopeOpen(token, "key", 100);
    else
      s.Shutdown();
    s.CleanupReleased();
    const bool held = !f.Exclusive();
    {
      std::lock_guard<std::mutex> lock(m);
      go = true;
      cv.notify_all();
    }
    reading.get();
    Require(held && metadata == 1,
            "upgrade/shutdown rejects next metadata and retains active handle");
    if (!upgrade) {
      s.CleanupReleased();
      Require(f.Exclusive(), "shutdown cleanup closes after call");
    }
  }
}
void BeginInvalidatesBeforeWaitingForAdmittedRead() {
  Fixture fixture;
  std::atomic<uint64_t> now{10};
  auto options = Clock(now);
  std::mutex mutex;
  std::condition_variable changed;
  bool armed = false, reading = false, invalidated = false, go = false;
  options.io = [&](SourceIo op) {
    if (!armed) return;
    std::unique_lock<std::mutex> lock(mutex);
    if (op == SourceIo::pass_invalidated) {
      invalidated = true;
      changed.notify_all();
    }
    if (op == SourceIo::read) {
      reading = true;
      changed.notify_all();
      changed.wait(lock, [&] { return go; });
    }
  };
  SelectedFileStore store(options);
  auto token = store.AddPickerPaths({fixture.path})[0].token;
  auto scope = store.ScopeOpen(token, "key", 100);
  auto pass = store.BeginPass(token, scope);
  armed = true;
  auto old_read = std::async(std::launch::async, [&] {
    try {
      store.ReadPass(token, scope, pass, 0, 3);
      return false;
    } catch (const SelectedFileException& error) {
      return error.reason() == SelectedFileError::invalid_read;
    }
  });
  {
    std::unique_lock<std::mutex> lock(mutex);
    Require(changed.wait_for(lock, std::chrono::seconds(5),
                             [&] { return reading; }),
            "old read admitted");
  }
  auto next = std::async(std::launch::async,
                         [&] { return store.BeginPass(token, scope); });
  bool before_wait = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    before_wait = changed.wait_for(lock, std::chrono::seconds(2),
                                   [&] { return invalidated; });
    go = true;
    changed.notify_all();
  }
  const bool rejected = old_read.get();
  const auto replacement = next.get();
  Require(before_wait && rejected,
          "begin invalidates old pass before waiting for work lock");
  Require(replacement != pass &&
              store.ReadPass(token, scope, replacement, 0, 6).size() == 6,
          "replacement resets original handle");
}
}  // namespace
int main() {
  int failures = 0;
  for (auto test :
       {GuardedPassAndRebind, DeadlineAndClock,
        StopBlockedReadAndDeferredRelease, ClosedCannotReviveAndIndependentFile,
        RetainedCleanupCountsCapacity, LegacyUpgradeAndShutdownAdmission,
        BeginInvalidatesBeforeWaitingForAdmittedRead}) {
    try {
      test();
    } catch (const std::exception& e) {
      ++failures;
      std::cerr << "FAIL: " << e.what() << '\n';
    }
  }
  std::cout << "source-store groups=7 failures=" << failures << '\n';
  return failures ? 1 : 0;
}
