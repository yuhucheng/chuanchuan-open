#include "selected_file_store.h"

#include <windows.h>
#include <objbase.h>
#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

namespace share_hub {
namespace {
std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (count <= 0) throw SelectedFileException(SelectedFileError::unavailable);
  std::string result(static_cast<size_t>(count), '\0');
  if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                           static_cast<int>(value.size()), result.data(), count, nullptr, nullptr)) {
    throw SelectedFileException(SelectedFileError::unavailable);
  }
  return result;
}

std::string NewToken() {
  GUID guid{};
  if (CoCreateGuid(&guid) != S_OK) throw SelectedFileException(SelectedFileError::unavailable);
  wchar_t text[40];
  if (!StringFromGUID2(guid, text, 40)) throw SelectedFileException(SelectedFileError::unavailable);
  return Utf8(text);
}

struct Snapshot {
  FILE_ID_INFO id{};
  FILE_BASIC_INFO basic{};
  FILE_STANDARD_INFO standard{};
};

bool SnapshotHandle(HANDLE handle, Snapshot* state) {
  return GetFileInformationByHandleEx(handle, FileIdInfo, &state->id, sizeof(state->id)) &&
         GetFileInformationByHandleEx(handle, FileBasicInfo, &state->basic, sizeof(state->basic)) &&
         GetFileInformationByHandleEx(handle, FileStandardInfo, &state->standard,
                                      sizeof(state->standard));
}

bool Regular(const Snapshot& state) {
  return !state.standard.Directory && state.standard.EndOfFile.QuadPart >= 0 &&
         !(state.basic.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
}

bool Same(const Snapshot& a, const Snapshot& b) {
  return a.id.VolumeSerialNumber == b.id.VolumeSerialNumber &&
         std::memcmp(a.id.FileId.Identifier, b.id.FileId.Identifier,
                     sizeof(a.id.FileId.Identifier)) == 0 &&
         a.standard.EndOfFile.QuadPart == b.standard.EndOfFile.QuadPart &&
         a.basic.CreationTime.QuadPart == b.basic.CreationTime.QuadPart &&
         a.basic.LastWriteTime.QuadPart == b.basic.LastWriteTime.QuadPart &&
         a.basic.ChangeTime.QuadPart == b.basic.ChangeTime.QuadPart &&
         Regular(b);
}

HANDLE OpenRegular(const std::wstring& path, DWORD access, DWORD sharing) {
  return CreateFileW(path.c_str(), access, sharing,
                     nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
}
}

SelectedFileException::SelectedFileException(SelectedFileError reason)
    : std::runtime_error("selected file access failed"), reason_(reason) {}

struct SelectedFileStore::Entry {
  explicit Entry(const std::wstring& selected_path) : path(selected_path) {
    // Keep reads stable even when a writer holds its handle open: Windows can
    // defer LastWriteTime updates until that handle closes.
    handle = OpenRegular(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE);
    if (handle == INVALID_HANDLE_VALUE) {
      throw SelectedFileException(SelectedFileError::unavailable);
    }
    try {
      if (!SnapshotHandle(handle, &original) || !Regular(original)) {
        throw SelectedFileException(SelectedFileError::unavailable);
      }
      const auto split = path.find_last_of(L"\\/");
      info = {NewToken(), Utf8(path.substr(split == std::wstring::npos ? 0 : split + 1)),
              original.standard.EndOfFile.QuadPart};
    } catch (...) {
      CloseHandle(handle);
      handle = INVALID_HANDLE_VALUE;
      throw;
    }
  }
  ~Entry() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
  Entry(const Entry&) = delete;
  Entry& operator=(const Entry&) = delete;

  void Validate() const {
    Snapshot held{};
    Snapshot at_path{};
    if (!SnapshotHandle(handle, &held) || !Same(original, held)) {
      throw SelectedFileException(SelectedFileError::changed);
    }
    HANDLE path_handle = OpenRegular(path, FILE_READ_ATTRIBUTES,
                                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    const bool valid = path_handle != INVALID_HANDLE_VALUE &&
                       SnapshotHandle(path_handle, &at_path) && Same(original, at_path);
    if (path_handle != INVALID_HANDLE_VALUE) CloseHandle(path_handle);
    if (!valid) throw SelectedFileException(SelectedFileError::changed);
  }

  std::wstring path;
  HANDLE handle = INVALID_HANDLE_VALUE;
  Snapshot original{};
  SelectedFileInfo info{};
  int64_t offset = 0;
};

SelectedFileStore::SelectedFileStore() = default;
SelectedFileStore::~SelectedFileStore() { Shutdown(); }

std::vector<SelectedFileInfo> SelectedFileStore::AddPickerPaths(
    const std::vector<std::wstring>& paths) {
  if (closed_) throw SelectedFileException(SelectedFileError::closed);
  if (paths.size() > kMaximumFiles - entries_.size()) {
    throw SelectedFileException(SelectedFileError::limit);
  }
  std::vector<std::unique_ptr<Entry>> pending;
  pending.reserve(paths.size());
  for (const auto& path : paths) pending.push_back(std::make_unique<Entry>(path));
  std::vector<SelectedFileInfo> result;
  result.reserve(pending.size());
  for (auto& entry : pending) {
    result.push_back(entry->info);
    entries_.emplace(entry->info.token, std::move(entry));
  }
  return result;
}

SelectedFileStore::Entry& SelectedFileStore::Lookup(const std::string& token) {
  if (closed_) throw SelectedFileException(SelectedFileError::closed);
  auto found = entries_.find(token);
  if (found == entries_.end()) throw SelectedFileException(SelectedFileError::invalid_token);
  return *found->second;
}

std::vector<uint8_t> SelectedFileStore::Read(const std::string& token, int64_t offset, int length) {
  auto& entry = Lookup(token);
  if (length <= 0 || length > kMaximumChunk || offset < 0 || offset != entry.offset ||
      offset >= entry.info.size) {
    throw SelectedFileException(SelectedFileError::invalid_read);
  }
  entry.Validate();
  const auto amount = static_cast<DWORD>(std::min<int64_t>(length, entry.info.size - offset));
  LARGE_INTEGER position{};
  position.QuadPart = offset;
  if (!SetFilePointerEx(entry.handle, position, nullptr, FILE_BEGIN)) {
    throw SelectedFileException(SelectedFileError::changed);
  }
  std::vector<uint8_t> bytes(amount);
  DWORD received = 0;
  if (!ReadFile(entry.handle, bytes.data(), amount, &received, nullptr) || received != amount) {
    throw SelectedFileException(SelectedFileError::changed);
  }
  entry.Validate();
  entry.offset += received;
  return bytes;
}

void SelectedFileStore::Finish(const std::string& token) {
  auto& entry = Lookup(token);
  entry.Validate();
  if (entry.offset != entry.info.size) throw SelectedFileException(SelectedFileError::incomplete);
}

void SelectedFileStore::Release(const std::string& token) { entries_.erase(token); }

void SelectedFileStore::Shutdown() {
  closed_ = true;
  entries_.clear();
}
}
