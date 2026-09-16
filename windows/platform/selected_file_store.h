#ifndef SHARE_HUB_SELECTED_FILE_STORE_H_
#define SHARE_HUB_SELECTED_FILE_STORE_H_

#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace share_hub {

enum class SelectedFileError { closed, limit, unavailable, changed, invalid_read,
                               incomplete, invalid_token };

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

// Paths enter only from the native picker. The Flutter channel never accepts paths.
// All calls run serially on the runner's UI thread.
class SelectedFileStore {
 public:
  static constexpr size_t kMaximumFiles = 64;
  static constexpr int kMaximumChunk = 256 * 1024;
  SelectedFileStore();
  ~SelectedFileStore();
  SelectedFileStore(const SelectedFileStore&) = delete;
  SelectedFileStore& operator=(const SelectedFileStore&) = delete;

  std::vector<SelectedFileInfo> AddPickerPaths(const std::vector<std::wstring>& paths);
  std::vector<uint8_t> Read(const std::string& token, int64_t offset, int length);
  void Finish(const std::string& token);
  void Release(const std::string& token);
  void Shutdown();
  size_t count() const { return entries_.size(); }

 private:
  struct Entry;
  Entry& Lookup(const std::string& token);
  std::map<std::string, std::unique_ptr<Entry>> entries_;
  bool closed_ = false;
};
}
#endif
