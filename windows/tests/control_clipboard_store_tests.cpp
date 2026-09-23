#include "control_clipboard_store.h"

#include <iostream>
#include <stdexcept>

namespace {
using namespace share_hub;

void Check(bool value, const char* why) {
  if (!value) throw std::runtime_error(why);
}
void Reject(const std::function<void()>& action, const char* code) {
  try { action(); }
  catch (const ControlClipboardException& error) {
    Check(error.code() == code, "wrong rejection");
    return;
  }
  throw std::runtime_error("missing rejection");
}

void ExactLeaseAndConflict() {
  uint64_t now = 10;
  ControlClipboardSnapshot os{7, std::wstring(L"existing")};
  int writes = 0;
  ControlClipboardStoreOptions options;
  options.clock = [&](uint64_t* time) { *time = now; return true; };
  options.read = [&] { return os; };
  options.write = [&](uint32_t expected, std::wstring_view text,
                      const std::function<bool()>& current) {
    Check(current(), "native write gate");
    if (expected != os.sequence) {
      return ControlClipboardWriteResult{ControlClipboardWriteStatus::conflict};
    }
    writes++;
    os.sequence++;
    os.text = std::wstring(text);
    return ControlClipboardWriteResult{ControlClipboardWriteStatus::written,
                                       os.sequence};
  };
  ControlClipboardStore store(nullptr, options);
  const auto lease = store.Open(100, 1, 2, 3);
  Check(store.Read(lease, 1, 2, 3).text == L"existing", "initial text");
  Reject([&] { store.Read(lease, 2, 2, 3); }, "stale_scope");
  Reject([&] { store.Write(lease, 1, 2, 4, 7, L"bad"); }, "stale_scope");
  Check(store.Write(lease, 1, 2, 3, 6, L"stale").status ==
            ControlClipboardWriteStatus::conflict && writes == 0,
        "observed local copy wins");
  const auto written = store.Write(lease, 1, 2, 3, 7, L"中文\nA");
  Check(written.status == ControlClipboardWriteStatus::written &&
        written.sequence == 8 && os.text == L"中文\nA", "unicode text write");
  store.Close(lease);
  Reject([&] { store.Read(lease, 1, 2, 3); }, "stale_scope");
  Check(store.Open(100, 2, 2, 3) != lease, "old lease never reused");
}

void DeadlineAndUnknownResult() {
  uint64_t now = 10;
  int writes = 0;
  bool unknown = false;
  ControlClipboardStoreOptions options;
  options.clock = [&](uint64_t* time) { *time = now; return true; };
  options.read = [] { return std::optional<ControlClipboardSnapshot>(
      ControlClipboardSnapshot{9, std::nullopt}); };
  options.write = [&](uint32_t, std::wstring_view,
                      const std::function<bool()>& current) {
    if (unknown) return ControlClipboardWriteResult{
        ControlClipboardWriteStatus::unknown};
    now = 100;
    if (current()) writes++;
    return ControlClipboardWriteResult{ControlClipboardWriteStatus::rejected};
  };
  ControlClipboardStore store(nullptr, options);
  const auto lease = store.Open(100, 1, 1, 1);
  Check(!store.Read(lease, 1, 1, 1).text, "no plain text format preserved");
  Check(store.Write(lease, 1, 1, 1, 9, L"late").status ==
            ControlClipboardWriteStatus::rejected && writes == 0,
        "deadline rechecked inside write");
  Reject([&] { store.Read(lease, 1, 1, 1); }, "stale_scope");
  now = 20;
  const auto fresh = store.Open(100, 2, 1, 1);
  unknown = true;
  Check(store.Write(fresh, 2, 1, 1, 9, L"maybe").status ==
            ControlClipboardWriteStatus::unknown, "unknown result reported");
  Reject([&] { store.Read(fresh, 2, 1, 1); }, "stale_scope");
}

void InvalidTextNeverReachesOs() {
  uint64_t now = 10;
  int writes = 0;
  ControlClipboardStoreOptions options;
  options.clock = [&](uint64_t* time) { *time = now; return true; };
  options.read = [] { return std::optional<ControlClipboardSnapshot>(
      ControlClipboardSnapshot{9, std::wstring(L"")}); };
  options.write = [&](uint32_t, std::wstring_view,
                      const std::function<bool()>&) {
    writes++;
    return ControlClipboardWriteResult{ControlClipboardWriteStatus::written, 10};
  };
  ControlClipboardStore store(nullptr, options);
  const auto lease = store.Open(100, 1, 1, 1);
  Reject([&] { store.Write(lease, 1, 1, 1, 9, std::wstring(32769, L'a')); },
         "invalid_text");
  Reject([&] { store.Write(lease, 1, 1, 1, 9, std::wstring(1, 0xd800)); },
         "invalid_text");
  Reject([&] { store.Write(lease, 1, 1, 1, 9, std::wstring(L"a\0b", 3)); },
         "invalid_text");
  Check(writes == 0, "invalid text cannot touch OS");
}

void NotificationRegistrationFollowsLease() {
  uint64_t now = 10;
  int registrations = 0, removals = 0;
  bool available = false;
  ControlClipboardStoreOptions options;
  options.clock = [&](uint64_t* time) { *time = now; return true; };
  options.read = [] { return std::optional<ControlClipboardSnapshot>(
      ControlClipboardSnapshot{9, std::wstring(L"text")}); };
  options.write = [](uint32_t, std::wstring_view,
                     const std::function<bool()>&) {
    return ControlClipboardWriteResult{ControlClipboardWriteStatus::unknown};
  };
  options.subscribe = [&] { registrations++; return available; };
  options.unsubscribe = [&] { removals++; };
  ControlClipboardStore store(nullptr, options);
  Reject([&] { store.Open(100, 1, 1, 1); }, "clipboard_unavailable");
  Check(registrations == 1 && removals == 0,
        "failed listener registration must not open lease");
  available = true;
  const auto lease = store.Open(100, 1, 1, 1);
  Check(registrations == 2, "listen only after lease admission");
  store.Close(lease);
  Check(removals == 1, "close removes listener");
  const auto next = store.Open(100, 2, 1, 1);
  Check(store.Write(next, 2, 1, 1, 9, L"text").status ==
        ControlClipboardWriteStatus::unknown, "unknown result returned");
  Check(removals == 2, "unknown write removes listener");
}
}  // namespace

int main() {
  try {
    ExactLeaseAndConflict();
    DeadlineAndUnknownResult();
    InvalidTextNeverReachesOs();
    NotificationRegistrationFollowsLease();
    std::cout << "control clipboard store: 4 passed\n";
  } catch (const std::exception& error) {
    std::cerr << "control clipboard store failed: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
