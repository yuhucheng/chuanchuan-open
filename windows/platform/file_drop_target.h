#ifndef SHARE_HUB_FILE_DROP_TARGET_H_
#define SHARE_HUB_FILE_DROP_TARGET_H_
#include <windows.h>
#include <oleidl.h>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace share_hub {
// OS-owned CF_HDROP only. Never exposed as a Dart path-access method.
std::optional<std::vector<std::wstring>> ReadDroppedPaths(HGLOBAL memory);

class FileDropTarget final : public IDropTarget {
 public:
  using Ready = std::function<bool()>;
  using DropFiles = std::function<bool(std::vector<std::wstring>, POINTL)>;
  FileDropTarget(Ready ready, DropFiles drop);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject*, DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD*) override;
 private:
  ~FileDropTarget() = default;
  LONG references_ = 1;
  bool candidate_ = false;
  Ready ready_;
  DropFiles drop_;
};
}  // namespace share_hub
#endif
