#include <windows.h>
#include <shellapi.h>
#include <shlobj_core.h>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include "file_drop_target.h"

namespace {
void Require(bool value, const char* why) {
  if (!value) throw std::runtime_error(why);
}
struct DropMemory {
  HGLOBAL memory;
  explicit DropMemory(const std::vector<std::wstring>& paths) {
    std::wstring payload;
    for (const auto& path : paths) { payload += path; payload += L'\0'; }
    payload += L'\0';
    memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                         sizeof(DROPFILES) + payload.size() * sizeof(wchar_t));
    auto* bytes = static_cast<unsigned char*>(GlobalLock(memory));
    DROPFILES header{};
    header.pFiles = sizeof(DROPFILES);
    header.fWide = TRUE;
    std::memcpy(bytes, &header, sizeof(header));
    std::memcpy(bytes + sizeof(header), payload.data(), payload.size() * sizeof(wchar_t));
    GlobalUnlock(memory);
  }
  ~DropMemory() { GlobalFree(memory); }
  void Header(DWORD offset, BOOL wide) {
    auto* header = static_cast<DROPFILES*>(GlobalLock(memory));
    header->pFiles = offset; header->fWide = wide;
    GlobalUnlock(memory);
  }
};
struct DataObject final : IDataObject {
  DropMemory payload{{L"C:\\文件\\测试.txt"}};
  std::function<void()> on_get;
  int gets = 0;
  ULONG refs = 1;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
    *out = static_cast<IDataObject*>(this); AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
  ULONG STDMETHODCALLTYPE Release() override { return --refs; }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* out) override {
    if (FAILED(QueryGetData(format))) return DV_E_FORMATETC;
    ++gets;
    if (on_get) on_get();
    *out = {};
    out->tymed = TYMED_HGLOBAL;
    const auto size = GlobalSize(payload.memory);
    out->hGlobal = GlobalAlloc(GMEM_MOVEABLE, size);
    auto* destination = GlobalLock(out->hGlobal);
    const auto* source = GlobalLock(payload.memory);
    std::memcpy(destination, source, size);
    GlobalUnlock(payload.memory); GlobalUnlock(out->hGlobal);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* f) override {
    return f && f->cfFormat == CF_HDROP && f->tymed == TYMED_HGLOBAL ? S_OK : DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
};
void OleDropBoundary() {
  Require(SUCCEEDED(OleInitialize(nullptr)), "OLE initialization");
  struct Uninitialize { ~Uninitialize() { OleUninitialize(); } } uninitialize;
  bool ready = true;
  int calls = 0;
  auto* target = new share_hub::FileDropTarget([&] { return ready; },
      [&](std::vector<std::wstring> paths, POINTL point) {
        Require(paths.size() == 1 && paths.front() == L"C:\\文件\\测试.txt", "drop yields OS path");
        Require(point.x == 42 && point.y == 56, "screen location preserved");
        ++calls; return true;
      });
  struct Release { IDropTarget* target; ~Release() { target->Release(); } } release{target};
  const auto window = CreateWindowW(L"STATIC", L"Drop test", WS_OVERLAPPED, 0, 0, 10, 10,
                                     nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "hidden test window");
  const auto registered = RegisterDragDrop(window, target);
  if (SUCCEEDED(registered)) RevokeDragDrop(window);
  DestroyWindow(window);
  Require(SUCCEEDED(registered), "OLE target registration and revocation");
  DataObject data;
  DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
  target->DragEnter(&data, 0, {42, 56}, &effect);
  Require(effect == DROPEFFECT_COPY, "drag enter only advertises copy");
  target->Drop(&data, 0, {42, 56}, &effect);
  Require(effect == DROPEFFECT_COPY && calls == 1, "valid OS drop delivered");
  effect = DROPEFFECT_MOVE;
  target->Drop(&data, 0, {42, 56}, &effect);
  Require(effect == DROPEFFECT_NONE && calls == 1 && data.gets == 1, "move does not open files");
  ready = false;
  effect = DROPEFFECT_COPY;
  target->Drop(&data, 0, {42, 56}, &effect);
  Require(effect == DROPEFFECT_NONE && data.gets == 1, "closed admission avoids GetData");
  ready = true;
  data.on_get = [&] { ready = false; };
  effect = DROPEFFECT_COPY;
  target->Drop(&data, 0, {42, 56}, &effect);
  Require(effect == DROPEFFECT_NONE && calls == 1, "nested COM cancellation rechecked");
}
}
int main() {
  try {
    OleDropBoundary();
    DropMemory unicode({L"C:\\文件\\测试.txt", L"C:\\second.bin"});
    auto parsed = share_hub::ReadDroppedPaths(unicode.memory);
    Require(parsed && parsed->size() == 2 && parsed->front() == L"C:\\文件\\测试.txt",
            "OS Unicode multi-file drop must parse");
    DropMemory empty({});
    Require(!share_hub::ReadDroppedPaths(empty.memory), "empty offer rejected");
    DropMemory many(std::vector<std::wstring>(65, L"C:\\file"));
    Require(!share_hub::ReadDroppedPaths(many.memory), "65 files rejected");
    unicode.Header(1, TRUE);
    Require(!share_hub::ReadDroppedPaths(unicode.memory), "invalid offset rejected");
    unicode.Header(sizeof(DROPFILES), FALSE);
    Require(!share_hub::ReadDroppedPaths(unicode.memory), "ANSI unsupported");
    DropMemory long_path({std::wstring(32768, L'a')});
    Require(!share_hub::ReadDroppedPaths(long_path.memory), "oversize path rejected");
    DropMemory unterminated({L"C:\\file"});
    auto* buffer = static_cast<unsigned char*>(GlobalLock(unterminated.memory));
    std::memset(buffer + sizeof(DROPFILES), 1, GlobalSize(unterminated.memory) - sizeof(DROPFILES));
    GlobalUnlock(unterminated.memory);
    Require(!share_hub::ReadDroppedPaths(unterminated.memory), "missing terminator rejected");
    auto oversized = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 4 * 1024 * 1024 + 1);
    Require(!share_hub::ReadDroppedPaths(oversized), "oversize allocation rejected");
    GlobalFree(oversized);
    std::cout << "file drop parser: 8 cases and OLE boundary passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n'; return 1;
  }
}
