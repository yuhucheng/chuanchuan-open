#include "platform_bridge.h"
#include "connection_security.h"
#include "device_preferences.h"
#include "native_discovery.h"
#include "source_bridge.h"
#include "receive_bridge.h"
#include "file_drop_target.h"
#include "file_drop_session.h"
#include "control_display_geometry.h"
#include "control_pointer_bridge.h"
#include "control_clipboard_bridge.h"
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <climits>
#include <optional>
#include <utility>

namespace share_hub {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
constexpr UINT_PTR kTimer = 0x53484453;
ReceiveStoreOptions ReceiveOptions(const std::wstring& key) {
  ReceiveStoreOptions options;
  options.directory_settings_key = key;
  return options;
}
using Microsoft::WRL::ComPtr;
std::optional<int64_t> Integer(const Value& value) {
  if (const auto* number = std::get_if<int64_t>(&value)) return *number;
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  return std::nullopt;
}
const Value* Field(const Map& value, const char* name) {
  auto found = value.find(Value(name));
  return found == value.end() ? nullptr : &found->second;
}
const char* FileMessage(SelectedFileError reason) {
  switch (reason) {
    case SelectedFileError::closed: return u8"文件访问已结束，请重新选择文件。";
    case SelectedFileError::limit: return u8"一次最多保留 64 个文件，请先移除部分文件。";
    case SelectedFileError::unavailable: return u8"无法读取所选文件，请选择本机可用的普通文件。";
    case SelectedFileError::changed: return u8"文件在准备过程中发生变化，请重新选择。";
    case SelectedFileError::invalid_read: return u8"文件读取顺序或分块大小无效。";
    case SelectedFileError::incomplete: return u8"文件内容尚未完整读取。";
    case SelectedFileError::invalid_scope:
    case SelectedFileError::expired:
    case SelectedFileError::clock_failure:
    case SelectedFileError::stopped:
    case SelectedFileError::invalid_token: return u8"文件令牌无效，请重新选择。";
  }
  return u8"文件访问失败，请重新选择。";
}
void FileFailure(flutter::MethodResult<Value>* result, SelectedFileError reason) {
  result->Error("file_access", FileMessage(reason));
}
Value DeviceValue(const Device& device) {
  return Value(Map{{Value("id"), Value(device.id)}, {Value("name"), Value(device.name)}});
}
Value SnapshotValue(const DiscoverySnapshot& snapshot) {
  List devices;
  for (const auto& device : snapshot.devices) {
    Map entry{{Value("id"), Value(device.id)}, {Value("name"), Value(device.name)},
              {Value("platform"), Value(device.platform)}};
    // Endpoint fields are present only while the peer is accepting connections,
    // matching the macOS dictionary and the Dart "connectable" gate.
    if (!device.host.empty()) entry[Value("host")] = Value(device.host);
    if (!device.port.empty()) entry[Value("port")] = Value(device.port);
    if (!device.key.empty()) entry[Value("key")] = Value(device.key);
    devices.emplace_back(std::move(entry));
  }
  Map value{{Value("state"), Value(snapshot.state)}, {Value("devices"), Value(devices)}};
  if (!snapshot.message.empty()) value[Value("message")] = Value(snapshot.message);
  return Value(value);
}
}
struct PlatformBridge::Impl {
  Impl(HWND window, std::wstring registry_key)
      : window(window), preferences(registry_key),
        security(registry_key), discovery(window), files(window), receiving(window, ReceiveOptions(registry_key)) {}
  HWND window;
  bool loaded = false, closed = false;
  UINT_PTR timer = 0;
  DevicePreferences preferences;
  ConnectionSecurity security;
  NativeDiscovery discovery;
  SourceBridge files;
  ReceiveBridge receiving;
  ControlPointerBridge pointer;
  ControlClipboardBridge clipboard{window};
  HWND drop_window = nullptr;
  ComPtr<FileDropTarget> drop_target;
  std::unique_ptr<FileDropSession> drop_session;
  std::unique_ptr<flutter::MethodChannel<Value>> drops;
  ComPtr<IFileOpenDialog> picker;
  std::unique_ptr<flutter::MethodChannel<Value>> methods;
  std::unique_ptr<flutter::EventChannel<Value>> events;
  std::unique_ptr<flutter::EventSink<Value>> sink;
};
namespace {
template <typename State>
void PickReceiveDirectory(std::shared_ptr<State> state,
                          std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (state->picker) { result->Error("resource_limit", "A file picker is already open."); return; }
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    result->Error("permission_denied", "Cannot open receiving folder picker."); return;
  }
  DWORD options = 0;
  if (FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                                 FOS_PATHMUSTEXIST | FOS_NODEREFERENCELINKS))) {
    result->Error("permission_denied", "Cannot open receiving folder picker."); return;
  }
  dialog->SetTitle(L"选择接收文件夹");
  dialog->SetOkButtonLabel(L"使用此文件夹");
  state->picker = dialog;
  const HRESULT shown = dialog->Show(state->window);
  state->picker.Reset();
  if (state->closed) { result->Error("closed", "Client closed."); return; }
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(); return; }
  if (FAILED(shown)) { result->Error("permission_denied", "Cannot select receiving folder."); return; }
  ComPtr<IShellItem> selected;
  wchar_t* raw = nullptr;
  if (FAILED(dialog->GetResult(&selected)) || !selected ||
      FAILED(selected->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw) {
    if (raw) CoTaskMemFree(raw);
    result->Error("permission_denied", "Cannot select receiving folder."); return;
  }
  std::wstring path(raw);
  CoTaskMemFree(raw);
  state->receiving.AcceptPickedDirectory(std::move(path), std::move(result));
}
template <typename State>
void PickFiles(std::shared_ptr<State> state,
               std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (state->picker) { FileFailure(result.get(), SelectedFileError::unavailable); return; }
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    FileFailure(result.get(), SelectedFileError::unavailable); return;
  }
  DWORD options = 0;
  if (FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
                                FOS_PATHMUSTEXIST | FOS_ALLOWMULTISELECT |
                                FOS_NODEREFERENCELINKS))) {
    FileFailure(result.get(), SelectedFileError::unavailable); return;
  }
  dialog->SetTitle(L"选择要准备的文件");
  dialog->SetOkButtonLabel(L"加入队列");
  state->picker = dialog;
  const HRESULT shown = dialog->Show(state->window);
  state->picker.Reset();
  if (state->closed) { result->Error("closed", "Client closed."); return; }
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(Value(List{})); return; }
  if (FAILED(shown)) { FileFailure(result.get(), SelectedFileError::unavailable); return; }
  ComPtr<IShellItemArray> selected;
  DWORD count = 0;
  if (FAILED(dialog->GetResults(&selected)) || !selected ||
      FAILED(selected->GetCount(&count))) {
    FileFailure(result.get(), SelectedFileError::unavailable); return;
  }
  if (count > SelectedFileStore::kMaximumFiles) {
    FileFailure(result.get(), SelectedFileError::limit); return;
  }
  std::vector<std::wstring> paths;
  paths.reserve(count);
  for (DWORD index = 0; index < count; ++index) {
    ComPtr<IShellItem> item;
    wchar_t* raw = nullptr;
    if (FAILED(selected->GetItemAt(index, &item)) || !item ||
        FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw) {
      if (raw) CoTaskMemFree(raw);
      FileFailure(result.get(), SelectedFileError::unavailable); return;
    }
    paths.emplace_back(raw);
    CoTaskMemFree(raw);
  }
  state->files.AcceptPickedFiles(std::move(paths), std::move(result));
}
}
PlatformBridge::PlatformBridge(flutter::BinaryMessenger* messenger, HWND window,
                               std::wstring registry_key)
    : impl_(std::make_shared<Impl>(window, std::move(registry_key))) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  impl_->methods = std::make_unique<flutter::MethodChannel<Value>>(messenger, "dev.sharehub.client/platform", codec);
  impl_->events = std::make_unique<flutter::EventChannel<Value>>(messenger, "dev.sharehub.client/discovery", codec);
  impl_->drops = std::make_unique<flutter::MethodChannel<Value>>(messenger, "dev.sharehub.client/file-drop", codec);
  const std::weak_ptr<Impl> weak = impl_;
  impl_->drop_session = std::make_unique<FileDropSession>(impl_->files,
      [weak](double x, double y, FileDropSession::Decision decision) {
        const auto state = weak.lock();
        if (!state || state->closed) { decision(false); return; }
        state->drops->InvokeMethod("locate", std::make_unique<Value>(Map{
            {Value("x"), Value(x)}, {Value("y"), Value(y)}}),
            std::make_unique<flutter::MethodResultFunctions<Value>>(
                [decision](const Value* answer) {
                  decision(answer && std::get_if<bool>(answer) && std::get<bool>(*answer));
                },
                [decision](const std::string&, const std::string&, const Value*) { decision(false); },
                [decision] { decision(false); }));
      },
      [weak](Value offer, FileDropSession::Decision decision) {
        const auto state = weak.lock();
        if (!state || state->closed) { decision(false); return; }
        state->drops->InvokeMethod("drop", std::make_unique<Value>(std::move(offer)),
            std::make_unique<flutter::MethodResultFunctions<Value>>(
                [decision](const Value* answer) {
                  decision(answer && std::get_if<bool>(answer) && std::get<bool>(*answer));
                },
                [decision](const std::string&, const std::string&, const Value*) { decision(false); },
                [decision] { decision(false); }));
      },
      [weak] {
        if (const auto state = weak.lock(); state && !state->closed)
          state->drops->InvokeMethod("error", nullptr);
      });
  impl_->drops->SetMethodCallHandler([weak](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto state = weak.lock();
    if (!state || state->closed) { result->Error("closed", "Client closed."); return; }
    if (call.arguments() && !std::holds_alternative<std::monostate>(*call.arguments())) {
      result->Error("invalid_arguments", "File drop listener takes no paths."); return;
    }
    if (call.method_name() == "listen") {
      if (!state->drop_window) { result->Error("unavailable", "File drop unavailable."); return; }
      state->drop_session->Listen(); result->Success();
    } else if (call.method_name() == "cancel") {
      state->drop_session->Cancel(); result->Success();
    } else { result->NotImplemented(); }
  });
  impl_->timer = SetTimer(window, kTimer, 1000, nullptr);
  impl_->discovery.on_change = [this](const DiscoverySnapshot& snapshot) {
    if (impl_->sink && !impl_->closed) impl_->sink->Success(SnapshotValue(snapshot));
  };
  impl_->events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
        impl_->sink = std::move(events);
        impl_->sink->Success(SnapshotValue(impl_->discovery.snapshot()));
        return nullptr;
      },
      [this](const Value*) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
        impl_->sink.reset(); impl_->discovery.Stop(); return nullptr;
      }));
  impl_->methods->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                                             std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (impl_->closed) { result->Error("closed", u8"客户端已关闭。"); return; }
    const auto& method = call.method_name();
    if (impl_->pointer.Handle(call, result)) return;
    if (impl_->clipboard.Handle(call, result)) return;
    if (method == "control.screenGeometry") {
      // Read-only local metadata. It neither creates a control owner nor
      // authorizes OS input; the owner must retain and recheck native identity.
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* id_value = args ? Field(*args, "sourceId") : nullptr;
      const auto* id = id_value ? std::get_if<std::string>(id_value) : nullptr;
      if (!args || args->size() != 1 || !id) {
        result->Error("invalid_arguments", "Screen source id required."); return;
      }
      const auto geometry = ResolveControlScreenGeometry(*id);
      if (!geometry) {
        result->Error("source_unavailable", "Screen source is no longer current."); return;
      }
      result->Success(Value(Map{
          {Value("sourceId"), Value(*id)},
          {Value("left"), Value(static_cast<int64_t>(geometry->left))},
          {Value("top"), Value(static_cast<int64_t>(geometry->top))},
          {Value("width"), Value(static_cast<int64_t>(geometry->width))},
          {Value("height"), Value(static_cast<int64_t>(geometry->height))},
          {Value("rotation"), Value(static_cast<int64_t>(geometry->rotation))}}));
      return;
    }
    if (method == "files.receive.directoryPick") {
      if (call.arguments() && !std::holds_alternative<std::monostate>(*call.arguments())) {
        result->Error("invalid_range", "Folder picker takes no path argument."); return;
      }
      PickReceiveDirectory(impl_, std::move(result));
      return;
    }
    if (impl_->receiving.Handle(call, result)) return;
    if (method == "files.pick") {
      PickFiles(impl_, std::move(result));
      return;
    }
    if (impl_->files.Handle(call, result)) return;
    if (method == "connection.identity") {
      // Protected-storage failure must be a hard error: an anonymous fallback
      // identity would silently break every saved peer.
      std::vector<uint8_t> seed;
      if (!impl_->security.LoadIdentitySeed(&seed)) {
        result->Error("identity_unavailable", u8"无法读取设备身份，请检查本机受保护存储。");
        return;
      }
      result->Success(Value(seed));
      return;
    }
    if (method == "connection.clock") {
      uint64_t micros = 0;
      if (!ConnectionSecurity::ContinuousMicros(&micros)) {
        result->Error("clock_unavailable", u8"系统连续时钟不可用，无法安全计期。");
        return;
      }
      result->Success(Value(static_cast<int64_t>(micros)));
      return;
    }
    if (method == "connection.advertise") {
      // A null port or key clears the endpoint, matching the macOS primitive.
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      std::optional<uint16_t> port;
      std::optional<std::string> key;
      if (args) {
        const auto* port_value = Field(*args, "port");
        const auto* key_value = Field(*args, "key");
        const auto number = port_value ? Integer(*port_value) : std::nullopt;
        const auto* text = key_value ? std::get_if<std::string>(key_value) : nullptr;
        if (number && *number >= 1 && *number <= 65535) {
          port = static_cast<uint16_t>(*number);
        }
        if (text) key = *text;
      }
      std::string hostname;
      if (!impl_->discovery.Advertise(port, key, &hostname)) {
        result->Error("discovery_failed", u8"无法发布连接入口，请检查局域网发现是否正常。");
        return;
      }
      result->Success(hostname.empty() ? Value() : Value(hostname));
      return;
    }
    if (method == "loadDevice" || method == "setDeviceName" || method == "startDiscovery") {
      if (!impl_->loaded) impl_->loaded = impl_->preferences.Load();
      if (!impl_->loaded) { result->Error("storage_failed", impl_->preferences.error()); return; }
    }
    if (method == "loadDevice") result->Success(DeviceValue(impl_->preferences.device()));
    else if (method == "setDeviceName") {
      const auto* name = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!name || !NormalizeName(*name)) {
        result->Error("invalid_name", u8"设备名称不能为空、包含控制字符或超过 128 字节。"); return;
      }
      if (!impl_->preferences.SetName(*name)) {
        result->Error("storage_failed", impl_->preferences.error()); return;
      }
      result->Success(DeviceValue(impl_->preferences.device()));
    } else if (method == "permissions") {
      // Capability to attempt desktop capture, not a guarantee capture succeeds.
      // Input injection is deliberately not implemented or authorized here.
      result->Success(Value(Map{{Value("screenRecording"), Value(true)}, {Value("accessibility"), Value(false)}}));
    } else if (method == "requestScreenRecording") result->Success(Value(true));
    else if (method == "openSettings") {
      const auto* permission = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      const wchar_t* uri = nullptr;
      if (permission && *permission == "localNetwork") uri = L"ms-settings:network-status";
      if (permission && *permission == "screenRecording") uri = L"ms-settings:privacy-graphicscaptureprogrammatic";
      const auto launched = uri ? reinterpret_cast<INT_PTR>(ShellExecuteW(impl_->window, L"open", uri, nullptr, nullptr, SW_SHOWNORMAL)) : 0;
      result->Success(Value(launched > 32));
    } else if (method == "startDiscovery") {
      if (!impl_->timer) { result->Error("discovery_failed", u8"无法创建发现刷新计时器，请重启应用。"); return; }
      const auto& device = impl_->preferences.device();
      if (!impl_->discovery.Start(device.id, device.name)) {
        result->Error("discovery_failed", impl_->discovery.snapshot().message); return;
      }
      result->Success();
    } else if (method == "stopDiscovery") { impl_->discovery.Stop(); result->Success(); }
    else result->NotImplemented();
  });
}
PlatformBridge::~PlatformBridge() { Close(); }
bool PlatformBridge::HandleMessage(UINT message, WPARAM wparam) {
  if (impl_->closed) return false;
  if (message == ReceiveBridge::kMessage) { impl_->receiving.Pump(); return true; }
  if (message == SourceBridge::kMessage) { impl_->files.Pump(); return true; }
  if (message == NativeDiscovery::kMessage) { impl_->discovery.Pump(); return true; }
  if (message == WM_TIMER && wparam == impl_->timer) {
    impl_->receiving.Pump(); impl_->files.Pump(); impl_->discovery.Pump(); impl_->discovery.Tick(); return true;
  }
  return false;
}
void PlatformBridge::CancelFilePicker() {
  impl_->drop_session->Cancel();
  if (impl_->picker) impl_->picker->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
}

void PlatformBridge::ConfigureFileDrop(HWND flutter_view) {
  if (impl_->closed || impl_->drop_window || !flutter_view) return;
  const std::weak_ptr<Impl> weak = impl_;
  impl_->drop_target.Attach(new FileDropTarget(
      [weak] {
        const auto state = weak.lock();
        return state && !state->closed && !state->picker && state->drop_session->ready();
      },
      [weak, flutter_view](std::vector<std::wstring> paths, POINTL screen) {
        const auto state = weak.lock();
        if (!state || state->closed) return false;
        POINT client{screen.x, screen.y};
        if (!ScreenToClient(flutter_view, &client)) return false;
        const UINT dpi = GetDpiForWindow(flutter_view);
        if (!dpi) return false;
        return state->drop_session->Accept(std::move(paths),
            client.x * 96.0 / dpi, client.y * 96.0 / dpi);
      }));
  if (SUCCEEDED(RegisterDragDrop(flutter_view, impl_->drop_target.Get())))
    impl_->drop_window = flutter_view;
  else impl_->drop_target.Reset();
}

void PlatformBridge::Close() {
  if (impl_->closed) return;
  impl_->closed = true;
  impl_->pointer.Close();
  impl_->clipboard.Close();
  if (impl_->drop_window) { RevokeDragDrop(impl_->drop_window); impl_->drop_window = nullptr; }
  impl_->drop_target.Reset();
  impl_->drop_session->Close();
  impl_->drops->SetMethodCallHandler(nullptr);
  if (impl_->picker) impl_->picker->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
  impl_->receiving.Close();
  impl_->files.Close();
  if (impl_->timer) { KillTimer(impl_->window, impl_->timer); impl_->timer = 0; }
  impl_->discovery.Close(); impl_->sink.reset();
  // Channels do not automatically unregister handlers when destroyed.
  impl_->events->SetStreamHandler(nullptr);
  impl_->methods->SetMethodCallHandler(nullptr);
}
}
