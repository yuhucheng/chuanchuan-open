#ifndef SHARE_HUB_CONTROL_CLIPBOARD_STORE_H_
#define SHARE_HUB_CONTROL_CLIPBOARD_STORE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace share_hub {

class ControlClipboardException : public std::runtime_error {
 public:
  explicit ControlClipboardException(const char* code)
      : std::runtime_error(code), code_(code) {}
  const std::string& code() const { return code_; }
 private:
  std::string code_;
};

struct ControlClipboardSnapshot {
  uint32_t sequence;
  std::optional<std::wstring> text;
};

enum class ControlClipboardWriteStatus { written, conflict, rejected, unknown };
struct ControlClipboardWriteResult {
  ControlClipboardWriteStatus status;
  uint32_t sequence = 0;
};

// Injected operations are native-only test seams. Production read/write hold
// OpenClipboard across the sequence check and the complete CF_UNICODETEXT write.
struct ControlClipboardStoreOptions {
  std::function<bool(uint64_t*)> clock;
  std::function<std::optional<ControlClipboardSnapshot>()> read;
  std::function<ControlClipboardWriteResult(
      uint32_t, std::wstring_view, const std::function<bool()>&)> write;
  std::function<bool()> subscribe;
  std::function<void()> unsubscribe;
};

// Called on the Flutter platform thread. The SDK owner must validate its exact
// authority before opening and using this local lease; native checks the same
// original deadline, clipboard epoch and both settings revisions at each call.
class ControlClipboardStore {
 public:
  explicit ControlClipboardStore(HWND owner,
                                 ControlClipboardStoreOptions options = {});
  ~ControlClipboardStore();
  int64_t Open(uint64_t deadline_micros, int64_t epoch,
               int64_t controller_revision, int64_t target_revision);
  ControlClipboardSnapshot Read(int64_t lease, int64_t epoch,
                                int64_t controller_revision,
                                int64_t target_revision);
  ControlClipboardWriteResult Write(int64_t lease, int64_t epoch,
                                    int64_t controller_revision,
                                    int64_t target_revision,
                                    uint32_t expected_sequence,
                                    std::wstring_view text);
  void Close(int64_t lease);
  void Shutdown();

 private:
  void Require(int64_t lease, int64_t epoch, int64_t controller_revision,
               int64_t target_revision);
  ControlClipboardStoreOptions options_;
  bool subscribed_ = false;
  int64_t next_lease_ = 1, lease_ = 0, epoch_ = 0;
  int64_t controller_revision_ = 0, target_revision_ = 0;
  uint64_t deadline_micros_ = 0;
};

}  // namespace share_hub
#endif
