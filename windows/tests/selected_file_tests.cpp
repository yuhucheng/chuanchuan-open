#include "selected_file_store.h"

#include <windows.h>
#include <objbase.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using share_hub::SelectedFileError;
using share_hub::SelectedFileStore;

namespace {
int checks = 0;
int failures = 0;

void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) { ++failures; std::cerr << "FAIL: " << label << '\n'; }
}

template <typename Work>
void Reject(Work work, SelectedFileError expected, const char* label) {
  try { work(); Check(false, label); }
  catch (const share_hub::SelectedFileException& error) { Check(error.reason() == expected, label); }
  catch (...) { Check(false, label); }
}

struct TempFiles {
  std::wstring directory;
  std::vector<std::wstring> paths;
  TempFiles() {
    wchar_t root[MAX_PATH];
    GetTempPathW(MAX_PATH, root);
    GUID guid;
    CoCreateGuid(&guid);
    wchar_t suffix[40];
    StringFromGUID2(guid, suffix, 40);
    directory = std::wstring(root) + L"share-hub-files-" + suffix;
    CreateDirectoryW(directory.c_str(), nullptr);
  }
  ~TempFiles() {
    for (const auto& path : paths) DeleteFileW(path.c_str());
    RemoveDirectoryW(directory.c_str());
  }
  std::wstring Path(const std::wstring& name) {
    auto path = directory + L"\\" + name;
    paths.push_back(path);
    return path;
  }
  void Write(const std::wstring& path, const std::string& bytes) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
        FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    Check(handle != INVALID_HANDLE_VALUE, "fixture write opens");
    if (handle == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    Check(WriteFile(handle, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
        written == bytes.size(), "fixture write completes");
    CloseHandle(handle);
  }
};

bool CanOpenExclusive(const std::wstring& path) {
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  CloseHandle(handle);
  return true;
}

void OrdinaryEmptyUnicodeAndBounds() {
  TempFiles files;
  auto ordinary = files.Path(L"ordinary.bin");
  auto empty = files.Path(L"空 文件.txt");
  files.Write(ordinary, "abcdef");
  files.Write(empty, "");
  SelectedFileStore store;
  auto selected = store.AddPickerPaths({ordinary, empty});
  Check(selected.size() == 2 && selected[0].size == 6 && selected[1].size == 0,
        "ordinary and empty metadata");
  Check(selected[1].name == u8"空 文件.txt", "Unicode and space name");
  Check(selected[0].token != selected[1].token &&
        selected[0].token.find("ordinary.bin") == std::string::npos,
        "tokens opaque and unique");
  Check(!CanOpenExclusive(ordinary), "selected file handle retained");
  Reject([&] { store.Finish(selected[0].token); }, SelectedFileError::incomplete,
         "incomplete file not ready");
  Reject([&] { store.Read(selected[0].token, 1, 2); }, SelectedFileError::invalid_read,
         "out-of-order read rejected");
  Reject([&] { store.Read(selected[0].token, 0, 0); }, SelectedFileError::invalid_read,
         "zero read rejected");
  Reject([&] { store.Read(selected[0].token, 0, 256 * 1024 + 1); },
         SelectedFileError::invalid_read, "oversized read rejected");
  Check(store.Read(selected[0].token, 0, 3) == std::vector<uint8_t>({'a', 'b', 'c'}),
        "first chunk bytes");
  Check(store.Read(selected[0].token, 3, 3) == std::vector<uint8_t>({'d', 'e', 'f'}),
        "second chunk bytes");
  store.Finish(selected[0].token);
  store.Finish(selected[1].token);
  store.Release(selected[0].token);
  store.Release(selected[0].token);
  Check(CanOpenExclusive(ordinary), "release idempotently closes handle");
  store.Shutdown();
  Check(CanOpenExclusive(empty), "shutdown closes empty file handle");
  Reject([&] { store.Read(selected[1].token, 0, 1); }, SelectedFileError::closed,
         "shutdown rejects reads");
  Reject([&] { store.AddPickerPaths({ordinary}); }, SelectedFileError::closed,
         "shutdown rejects late selection");
}

void InvalidTokenLimitsAndAtomicSelection() {
  TempFiles files;
  auto path = files.Path(L"one.txt");
  files.Write(path, "a");
  SelectedFileStore store;
  Reject([&] { store.Read("arbitrary-path", 0, 1); }, SelectedFileError::invalid_token,
         "unselected token rejected");
  Reject([&] { store.Finish("arbitrary-path"); }, SelectedFileError::invalid_token,
         "unselected finish rejected");
  auto chosen = store.AddPickerPaths({path});
  std::vector<std::wstring> too_many(64, path);
  Reject([&] { store.AddPickerPaths(too_many); }, SelectedFileError::limit,
         "64 retained-file limit");
  auto bad = files.Path(L"missing.txt");
  Reject([&] { store.AddPickerPaths({path, bad}); }, SelectedFileError::unavailable,
         "invalid batch rejected atomically");
  Check(store.count() == 1, "failed batch retains no new handles");
  store.Release(chosen[0].token);
  Check(CanOpenExclusive(path), "failed batch and release leave no handles");
  auto at_limit = store.AddPickerPaths(std::vector<std::wstring>(64, path));
  Check(at_limit.size() == 64 && store.count() == 64, "exactly 64 files retained");
  Reject([&] { store.AddPickerPaths({path}); }, SelectedFileError::limit,
         "65th retained file rejected");
  store.Shutdown();
  Check(CanOpenExclusive(path), "limit batch handles released on shutdown");
}

void MaximumChunkBoundary() {
  TempFiles files;
  auto path = files.Path(L"large.bin");
  files.Write(path, std::string(256 * 1024, 'x') + 'z');
  SelectedFileStore store;
  auto file = store.AddPickerPaths({path})[0];
  auto first = store.Read(file.token, 0, 256 * 1024);
  Check(first.size() == 256 * 1024 && first.front() == 'x' && first.back() == 'x',
        "256 KiB chunk reads completely");
  Check(store.Read(file.token, 256 * 1024, 1) == std::vector<uint8_t>({'z'}),
        "next sequential chunk reads final byte");
  store.Finish(file.token);
}

void ChangesAndReplacement() {
  TempFiles files;
  auto path = files.Path(L"changing.txt");
  files.Write(path, "abc");
  SelectedFileStore store;
  auto token = store.AddPickerPaths({path})[0].token;
  auto moved = files.Path(L"moved.txt");
  Check(MoveFileExW(path.c_str(), moved.c_str(), 0) != 0, "fixture moves old file");
  files.Write(path, "abcd");
  Reject([&] { store.Read(token, 0, 3); }, SelectedFileError::changed,
         "length-changing replacement before read rejected");
  store.Release(token);
  files.Write(path, "abc");
  token = store.AddPickerPaths({path})[0].token;
  store.Read(token, 0, 3);
  auto second_moved = files.Path(L"second-moved.txt");
  Check(MoveFileExW(path.c_str(), second_moved.c_str(), 0) != 0, "fixture moves read file");
  files.Write(path, "changed");
  Reject([&] { store.Finish(token); }, SelectedFileError::changed,
         "replacement before finish rejected");
  store.Release(token);
  files.Write(path, "abc");
  token = store.AddPickerPaths({path})[0].token;
  auto third_moved = files.Path(L"third-moved.txt");
  Check(MoveFileExW(path.c_str(), third_moved.c_str(), 0) != 0, "fixture replace moves old file");
  files.Write(path, "abc");
  Reject([&] { store.Read(token, 0, 3); }, SelectedFileError::changed,
         "same-length replacement rejected");
  store.Shutdown();
  Check(CanOpenExclusive(third_moved), "shutdown releases replaced source handle");
}

void OpenWriterCannotChangeUnnoticed() {
  TempFiles files;
  auto path = files.Path(L"open-writer.txt");
  files.Write(path, "abc");
  SelectedFileStore store;
  auto token = store.AddPickerPaths({path})[0].token;
  HANDLE writer = CreateFileW(path.c_str(), GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(writer == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION,
        "selected file prevents open writer same-length rewrite");
  if (writer != INVALID_HANDLE_VALUE) CloseHandle(writer);
  store.Read(token, 0, 3);
  store.Finish(token);
  store.Release(token);
  writer = CreateFileW(path.c_str(), GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(writer != INVALID_HANDLE_VALUE, "writer can open after release");
  if (writer != INVALID_HANDLE_VALUE) CloseHandle(writer);
}
}

int main() {
  OrdinaryEmptyUnicodeAndBounds();
  InvalidTokenLimitsAndAtomicSelection();
  MaximumChunkBoundary();
  ChangesAndReplacement();
  OpenWriterCannotChangeUnnoticed();
  std::cout << "selected-file checks=" << checks << " failures=" << failures << '\n';
  return failures ? 1 : 0;
}
