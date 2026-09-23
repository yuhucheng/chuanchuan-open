#include "file_drop_target.h"
#include <shlobj_core.h>
#include <cstring>
#include <utility>
namespace share_hub {
std::optional<std::vector<std::wstring>> ReadDroppedPaths(HGLOBAL memory) {
  if (!memory) return std::nullopt;
  const auto size = GlobalSize(memory);
  if (size < sizeof(DROPFILES) + 2 * sizeof(wchar_t) || size > 4 * 1024 * 1024)
    return std::nullopt;
  const auto* bytes = static_cast<const unsigned char*>(GlobalLock(memory));
  if (!bytes) return std::nullopt;
  struct Unlock { HGLOBAL memory; ~Unlock() { GlobalUnlock(memory); } } unlock{memory};
  DROPFILES header{};
  std::memcpy(&header, bytes, sizeof(header));
  if (!header.fWide || header.pFiles < sizeof(header) ||
      header.pFiles % sizeof(wchar_t) != 0 || header.pFiles >= size)
    return std::nullopt;
  const auto count = (size - header.pFiles) / sizeof(wchar_t);
  const auto* text = reinterpret_cast<const wchar_t*>(bytes + header.pFiles);
  std::vector<std::wstring> paths;
  size_t begin = 0;
  while (begin < count) {
    if (text[begin] == L'\0') return paths.empty() ? std::nullopt :
        std::optional<std::vector<std::wstring>>(std::move(paths));
    size_t end = begin;
    while (end < count && text[end] != L'\0' && end - begin <= 32767) ++end;
    if (end == count || end - begin > 32767 || paths.size() == 64)
      return std::nullopt;
    paths.emplace_back(text + begin, end - begin);
    begin = end + 1;
  }
  return std::nullopt;
}
namespace {
FORMATETC DropFormat() { return {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL}; }
}
FileDropTarget::FileDropTarget(Ready ready, DropFiles drop)
    : ready_(std::move(ready)), drop_(std::move(drop)) {}
HRESULT FileDropTarget::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER;
  *object = nullptr;
  if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
  *object = static_cast<IDropTarget*>(this); AddRef(); return S_OK;
}
ULONG FileDropTarget::AddRef() { return static_cast<ULONG>(InterlockedIncrement(&references_)); }
ULONG FileDropTarget::Release() {
  const auto count = InterlockedDecrement(&references_);
  if (!count) delete this;
  return static_cast<ULONG>(count);
}
HRESULT FileDropTarget::DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) {
  if (!effect) return E_POINTER;
  auto format = DropFormat();
  candidate_ = data && ready_() && SUCCEEDED(data->QueryGetData(&format));
  *effect = candidate_ && (*effect & DROPEFFECT_COPY) ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}
HRESULT FileDropTarget::DragOver(DWORD, POINTL, DWORD* effect) {
  if (!effect) return E_POINTER;
  *effect = candidate_ && ready_() && (*effect & DROPEFFECT_COPY) ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}
HRESULT FileDropTarget::DragLeave() { candidate_ = false; return S_OK; }
HRESULT FileDropTarget::Drop(IDataObject* data, DWORD, POINTL position, DWORD* effect) {
  if (!effect) return E_POINTER;
  const bool copy = (*effect & DROPEFFECT_COPY) != 0;
  *effect = DROPEFFECT_NONE;
  candidate_ = false;
  if (!copy || !data || !ready_()) return S_OK;
  auto format = DropFormat();
  STGMEDIUM medium{};
  if (FAILED(data->GetData(&format, &medium))) return S_OK;
  struct Release { STGMEDIUM* value; ~Release() { ReleaseStgMedium(value); } } release{&medium};
  try {
    auto paths = medium.tymed == TYMED_HGLOBAL ? ReadDroppedPaths(medium.hGlobal) : std::nullopt;
    // GetData can run a nested COM message loop; recheck admission afterward.
    if (paths && ready_() && drop_(std::move(*paths), position)) *effect = DROPEFFECT_COPY;
  } catch (...) { /* No C++ exceptions cross the COM boundary. */ }
  return S_OK;
}
}
