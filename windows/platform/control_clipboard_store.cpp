#include "control_clipboard_store.h"

#include "connection_security.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

namespace share_hub {
namespace {
constexpr size_t kMaximumUtf8Bytes = 32768;

bool ValidText(std::wstring_view text) {
  if (text.size() > kMaximumUtf8Bytes ||
      text.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  for (size_t index = 0; index < text.size(); ++index) {
    const auto unit = static_cast<uint16_t>(text[index]);
    if (unit == 0) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index == text.size()) return false;
      const auto next = static_cast<uint16_t>(text[index]);
      if (next < 0xdc00 || next > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  if (text.empty()) return true;
  const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  return bytes > 0 && bytes <= static_cast<int>(kMaximumUtf8Bytes);
}

class OpenClipboardGuard {
 public:
  explicit OpenClipboardGuard(HWND owner) : opened_(OpenClipboard(owner) != 0) {}
  ~OpenClipboardGuard() { if (opened_) CloseClipboard(); }
  bool opened() const { return opened_; }
 private:
  bool opened_;
};

std::optional<ControlClipboardSnapshot> ReadSystem(HWND owner) {
  OpenClipboardGuard guard(owner);
  if (!guard.opened()) return std::nullopt;
  const DWORD sequence = GetClipboardSequenceNumber();
  if (sequence == 0) return std::nullopt;
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    return ControlClipboardSnapshot{sequence, std::nullopt};
  }
  const HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (!handle) return std::nullopt;
  const SIZE_T size = GlobalSize(handle);
  if (size < sizeof(wchar_t) || size > (kMaximumUtf8Bytes + 1) * sizeof(wchar_t)) {
    return std::nullopt;
  }
  const auto* data = static_cast<const wchar_t*>(GlobalLock(handle));
  if (!data) return std::nullopt;
  const size_t units = size / sizeof(wchar_t);
  const auto* end = std::find(data, data + units, L'\0');
  std::optional<std::wstring> text;
  if (end != data + units) {
    std::wstring copy(data, end);
    if (ValidText(copy)) text = std::move(copy);
  }
  GlobalUnlock(handle);
  if (!text) return std::nullopt;
  return ControlClipboardSnapshot{sequence, std::move(text)};
}

ControlClipboardWriteResult WriteSystem(HWND owner, uint32_t expected,
    std::wstring_view text, const std::function<bool()>& still_current) {
  if (!ValidText(text) || expected == 0) {
    return {ControlClipboardWriteStatus::rejected};
  }
  const SIZE_T size = (text.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!memory) return {ControlClipboardWriteStatus::rejected};
  auto* data = static_cast<wchar_t*>(GlobalLock(memory));
  if (!data) { GlobalFree(memory); return {ControlClipboardWriteStatus::rejected}; }
  if (!text.empty()) std::memcpy(data, text.data(), text.size() * sizeof(wchar_t));
  data[text.size()] = L'\0';
  GlobalUnlock(memory);
  OpenClipboardGuard guard(owner);
  if (!guard.opened()) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::rejected};
  }
  const DWORD current = GetClipboardSequenceNumber();
  if (current == 0) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::rejected};
  }
  if (current != expected) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::conflict};
  }
  if (!still_current()) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::rejected};
  }
  // There is no await between this check and the OS write. Other processes
  // cannot mutate the clipboard while our OpenClipboardGuard is held.
  if (!EmptyClipboard()) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::unknown};
  }
  if (!SetClipboardData(CF_UNICODETEXT, memory)) {
    GlobalFree(memory);
    return {ControlClipboardWriteStatus::unknown};
  }
  // Clipboard ownership transferred to Windows. A wrapped or unavailable
  // sequence cannot safely be used for echo suppression.
  const DWORD written = GetClipboardSequenceNumber();
  if (written == 0 || written <= current) {
    return {ControlClipboardWriteStatus::unknown};
  }
  return {ControlClipboardWriteStatus::written, written};
}
}  // namespace

ControlClipboardStore::ControlClipboardStore(
    HWND owner, ControlClipboardStoreOptions options)
    : options_(std::move(options)) {
  if (!options_.clock) options_.clock = ConnectionSecurity::ContinuousMicros;
  if (!options_.read) options_.read = [owner] { return ReadSystem(owner); };
  if (!options_.write) options_.write = [owner](uint32_t expected,
      std::wstring_view text, const std::function<bool()>& current) {
    return WriteSystem(owner, expected, text, current);
  };
  if (!options_.subscribe) options_.subscribe = [owner] {
    return owner == nullptr || AddClipboardFormatListener(owner) != 0;
  };
  if (!options_.unsubscribe) options_.unsubscribe = [owner] {
    if (owner != nullptr) RemoveClipboardFormatListener(owner);
  };
}

ControlClipboardStore::~ControlClipboardStore() { Shutdown(); }

int64_t ControlClipboardStore::Open(uint64_t deadline_micros, int64_t epoch,
                                    int64_t controller_revision,
                                    int64_t target_revision) {
  uint64_t now = 0;
  if (lease_ != 0) throw ControlClipboardException("busy");
  if (epoch < 1 || controller_revision < 1 || target_revision < 1 ||
      !options_.clock(&now) || now == 0 || now >= deadline_micros ||
      next_lease_ == std::numeric_limits<int64_t>::max()) {
    throw ControlClipboardException("invalid_scope");
  }
  if (!options_.subscribe()) {
    throw ControlClipboardException("clipboard_unavailable");
  }
  subscribed_ = true;
  deadline_micros_ = deadline_micros;
  epoch_ = epoch;
  controller_revision_ = controller_revision;
  target_revision_ = target_revision;
  lease_ = next_lease_++;
  return lease_;
}

void ControlClipboardStore::Require(int64_t lease, int64_t epoch,
                                    int64_t controller_revision,
                                    int64_t target_revision) {
  if (lease_ == 0 || lease != lease_ || epoch != epoch_ ||
      controller_revision != controller_revision_ ||
      target_revision != target_revision_) {
    throw ControlClipboardException("stale_scope");
  }
  uint64_t now = 0;
  if (!options_.clock(&now) || now == 0 || now >= deadline_micros_) {
    Shutdown();
    throw ControlClipboardException("expired");
  }
}

ControlClipboardSnapshot ControlClipboardStore::Read(
    int64_t lease, int64_t epoch, int64_t controller_revision,
    int64_t target_revision) {
  Require(lease, epoch, controller_revision, target_revision);
  const auto value = options_.read();
  if (!value || value->sequence == 0 ||
      (value->text && !ValidText(*value->text))) {
    throw ControlClipboardException("clipboard_unavailable");
  }
  Require(lease, epoch, controller_revision, target_revision);
  return *value;
}

ControlClipboardWriteResult ControlClipboardStore::Write(
    int64_t lease, int64_t epoch, int64_t controller_revision,
    int64_t target_revision, uint32_t expected_sequence,
    std::wstring_view text) {
  Require(lease, epoch, controller_revision, target_revision);
  if (expected_sequence == 0 || !ValidText(text)) {
    throw ControlClipboardException("invalid_text");
  }
  const auto current = [this, lease, epoch, controller_revision,
      target_revision]() {
    try { Require(lease, epoch, controller_revision, target_revision); }
    catch (const ControlClipboardException&) { return false; }
    return true;
  };
  const auto result = options_.write(expected_sequence, text, current);
  if (result.status == ControlClipboardWriteStatus::unknown) Shutdown();
  return result;
}

void ControlClipboardStore::Close(int64_t lease) {
  if (lease_ == 0 || lease != lease_) {
    throw ControlClipboardException("stale_scope");
  }
  Shutdown();
}

void ControlClipboardStore::Shutdown() {
  if (subscribed_) {
    subscribed_ = false;
    options_.unsubscribe();
  }
  lease_ = epoch_ = controller_revision_ = target_revision_ = 0;
  deadline_micros_ = 0;
}

}  // namespace share_hub
