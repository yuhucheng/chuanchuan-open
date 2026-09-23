#ifndef SHARE_HUB_RECEIVE_STORE_H_
#define SHARE_HUB_RECEIVE_STORE_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace share_hub {

class ReceiveException : public std::runtime_error {
 public:
  explicit ReceiveException(const std::string& code);
  const std::string& code() const { return code_; }
 private:
  std::string code_;
};

struct ReceiveDirectory { std::string token; std::string label; };
struct ReceiveCheckpoint { int64_t offset; std::string sha256; std::string identity; };
struct ReceiveReceipt { std::string name; int64_t size; std::string sha256; };
enum class ReceiveStopMode { pause, cancel };

// Native-only fault/race seams. No channel method accepts these or OS handles.
enum class ReceiveIo { after_create, write, read, flush, cleanup, before_publish, publishing };
struct ReceiveIoDirective {
  uint32_t error = 0;
  size_t maximum_bytes = static_cast<size_t>(-1);
};
struct ReceiveStoreOptions {
  // Local host settings only; never accepted over the method channel. Empty
  // disables persistence for standalone stores and isolated native harnesses.
  std::wstring directory_settings_key;
  std::function<bool(uint64_t*)> clock;
  std::function<ReceiveIoDirective(ReceiveIo, uintptr_t, size_t)> io;
  std::function<bool(uint64_t volume, uint64_t* bytes)> free_bytes;
  // Optional host policy. Defaults impose no arbitrary product file-size cap.
  uint64_t maximum_reserved_bytes = UINT64_MAX;
};

// All disk work belongs on a bounded bridge executor, never the Flutter thread.
// Operations serialize per entry, not across files. ScopeStop/ScopeClose/Abort/
// Shutdown only gate work and do not wait for an entry's I/O, hash, or OS rename.
// An I/O admission CAS is its start boundary: already admitted I/O may finish
// after stop; no later admission succeeds. Publication has a distinct CAS;
// stop observes "committing" once that CAS wins and cannot promise cancellation.
// RetryCleanup runs on the executor. Destruction requires workers to be joined.
class ReceiveStore {
 public:
  static constexpr size_t kMaximumEntries = 64;
  static constexpr size_t kMaximumScopes = 64;
  static constexpr size_t kMaximumDirectories = 64;
  static constexpr size_t kMaximumChunk = 32768;
  static constexpr size_t kHashBlock = 256 * 1024;
  explicit ReceiveStore(ReceiveStoreOptions options = {});
  ~ReceiveStore();
  ReceiveStore(const ReceiveStore&) = delete;
  ReceiveStore& operator=(const ReceiveStore&) = delete;

  ReceiveDirectory DirectoryDefault();
  ReceiveDirectory DirectoryConfigured();
  // Call only with a native picker result. Arbitrary channel paths are forbidden.
  ReceiveDirectory DirectoryFromPicker(const std::wstring& path);
  void DirectoryRelease(const std::string& directory);
  std::string ScopeOpen(const std::string& key, int64_t deadline_micros);
  std::string ScopeStop(const std::string& scope, ReceiveStopMode mode);
  void ScopeClose(const std::string& scope);
  std::string Begin(const std::string& directory, const std::string& scope,
                    const std::string& name, int64_t size, const std::string& sha256);
  int64_t Append(const std::string& token, const std::string& scope,
                 int64_t offset, const std::vector<uint8_t>& bytes);
  ReceiveCheckpoint Checkpoint(const std::string& token);
  void Resume(const std::string& token, const std::string& scope,
              const ReceiveCheckpoint& expected);
  ReceiveReceipt Commit(const std::string& token, const std::string& scope);
  void Abort(const std::string& token);
  void RetryCleanup(const std::string& token);
  // Worker-only bounded sweep of known terminal objects, including failed Begin
  // objects whose tokens were never exposed. Continues after individual errors.
  void RetryPendingCleanup();
  // Only committed or cleaned terminal metadata; never removes published files.
  void Release(const std::string& token);
  void Shutdown();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace share_hub
#endif
