#ifndef SHARE_HUB_SELECTED_FILE_STORE_H_
#define SHARE_HUB_SELECTED_FILE_STORE_H_

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace share_hub {

enum class SelectedFileError {
  closed,
  limit,
  unavailable,
  changed,
  invalid_read,
  incomplete,
  invalid_token,
  invalid_scope,
  expired,
  clock_failure,
  stopped
};
enum class SourceStopMode { pause, cancel };
enum class SourceIo {
  metadata,
  open_path,
  seek,
  read,
  before_close,
  pass_invalidated
};
struct SelectedFileStoreOptions {
  std::function<bool(uint64_t*)> clock;
  std::function<void(SourceIo)> io;
};

class SelectedFileException : public std::runtime_error {
 public:
  explicit SelectedFileException(SelectedFileError reason);
  SelectedFileError reason() const { return reason_; }

 private:
  SelectedFileError reason_;
};

struct SelectedFileInfo {
  std::string token;
  std::string name;
  int64_t size;
};

// Paths enter only from the native picker. The Flutter channel never accepts
// paths. Disk methods run on bounded workers. Scope controls, Release and
// Shutdown only close admission gates; CleanupReleased/destruction run after
// I/O on workers.
class SelectedFileStore {
 public:
  static constexpr size_t kMaximumFiles = 64;
  static constexpr int kMaximumChunk = 256 * 1024;
  SelectedFileStore();
  explicit SelectedFileStore(SelectedFileStoreOptions options);
  ~SelectedFileStore();
  SelectedFileStore(const SelectedFileStore&) = delete;
  SelectedFileStore& operator=(const SelectedFileStore&) = delete;

  std::vector<SelectedFileInfo> AddPickerPaths(
      const std::vector<std::wstring>& paths);
  std::vector<uint8_t> Read(const std::string& token, int64_t offset,
                            int length);
  void Finish(const std::string& token);
  std::string BeginReadPass(const std::string& token);
  std::vector<uint8_t> ReadPass(const std::string& token,
                                const std::string& pass_id, int64_t offset,
                                int length);
  void FinishPass(const std::string& token, const std::string& pass_id);
  std::string ScopeOpen(const std::string& token, const std::string& key,
                        int64_t deadline);
  std::string ScopeStop(const std::string& scope, SourceStopMode mode);
  void ScopeClose(const std::string& scope);
  std::string BeginPass(const std::string& token, const std::string& scope);
  std::vector<uint8_t> ReadPass(const std::string& token,
                                const std::string& scope,
                                const std::string& pass, int64_t offset,
                                int length);
  void FinishPass(const std::string& token, const std::string& scope,
                  const std::string& pass);
  void CleanupReleased();
  // UI completion gate only, no disk I/O. Prevents undelivered success after
  // stop.
  void ValidateCompletion(const std::string& token, const std::string& scope,
                          const std::string& pass);
  void Release(const std::string& token);
  void Shutdown();
  size_t count() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace share_hub
#endif
