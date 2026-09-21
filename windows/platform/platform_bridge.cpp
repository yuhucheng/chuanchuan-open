#include "platform_bridge.h"
#include "connection_security.h"
#include "device_preferences.h"
#include "native_discovery.h"
#include "selected_file_store.h"
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
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
        security(std::move(registry_key)), discovery(window) {}
  HWND window;
  bool loaded = false, closed = false;
  UINT_PTR timer = 0;
  DevicePreferences preferences;
  ConnectionSecurity security;
  NativeDiscovery discovery;
  SelectedFileStore files;
  ComPtr<IFileOpenDialog> picker;
  std::unique_ptr<flutter::MethodChannel<Value>> methods;
  std::unique_ptr<flutter::EventChannel<Value>> events;
  std::unique_ptr<flutter::EventSink<Value>> sink;
};
namespace {
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
  if (state->closed) return;
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(Value(List{})); return; }
  if (FAILED(shown)) { FileFailure(result.get(), SelectedFileError::unavailable); return; }
  ComPtr<IShellItemArray> selected;
  DWORD count = 0;
  if (FAILED(dialog->GetResults(&selected)) || !selected ||
      FAILED(selected->GetCount(&count))) {
    FileFailure(result.get(), SelectedFileError::unavailable); return;
  }
  if (count > SelectedFileStore::kMaximumFiles - state->files.count()) {
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
  try {
    List output;
    for (const auto& file : state->files.AddPickerPaths(paths)) {
      output.emplace_back(Map{{Value("token"), Value(file.token)},
                              {Value("name"), Value(file.name)},
                              {Value("size"), Value(file.size)}});
    }
    result->Success(Value(output));
  } catch (const SelectedFileException& error) {
    FileFailure(result.get(), error.reason());
  }
}
}
PlatformBridge::PlatformBridge(flutter::BinaryMessenger* messenger, HWND window,
                               std::wstring registry_key)
    : impl_(std::make_shared<Impl>(window, std::move(registry_key))) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  impl_->methods = std::make_unique<flutter::MethodChannel<Value>>(messenger, "dev.sharehub.client/platform", codec);
  impl_->events = std::make_unique<flutter::EventChannel<Value>>(messenger, "dev.sharehub.client/discovery", codec);
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
    if (method == "files.pick") {
      PickFiles(impl_, std::move(result));
      return;
    }
    if (method == "files.read" || method == "files.finish" || method == "files.release") {
      try {
        if (method == "files.read") {
          const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
          const auto* token_value = args ? Field(*args, "token") : nullptr;
          const auto* offset_value = args ? Field(*args, "offset") : nullptr;
          const auto* length_value = args ? Field(*args, "length") : nullptr;
          const auto* token = token_value ? std::get_if<std::string>(token_value) : nullptr;
          const auto offset = offset_value ? Integer(*offset_value) : std::nullopt;
          const auto length = length_value ? Integer(*length_value) : std::nullopt;
          if (!token || !offset || !length || *length < 0 || *length > INT_MAX) {
            FileFailure(result.get(), SelectedFileError::invalid_read); return;
          }
          result->Success(Value(impl_->files.Read(*token, *offset, static_cast<int>(*length))));
        } else {
          const auto* token = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
          if (!token) { FileFailure(result.get(), SelectedFileError::invalid_token); return; }
          if (method == "files.finish") impl_->files.Finish(*token);
          else impl_->files.Release(*token);
          result->Success();
        }
      } catch (const SelectedFileException& error) {
        FileFailure(result.get(), error.reason());
      }
      return;
    }
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
  if (message == NativeDiscovery::kMessage) { impl_->discovery.Pump(); return true; }
  if (message == WM_TIMER && wparam == impl_->timer) { impl_->discovery.Pump(); impl_->discovery.Tick(); return true; }
  return false;
}
void PlatformBridge::CancelFilePicker() {
  if (impl_->picker) impl_->picker->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
}

void PlatformBridge::Close() {
  if (impl_->closed) return;
  impl_->closed = true;
  if (impl_->picker) impl_->picker->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
  impl_->files.Shutdown();
  if (impl_->timer) { KillTimer(impl_->window, impl_->timer); impl_->timer = 0; }
  impl_->discovery.Close(); impl_->sink.reset();
  // Channels do not automatically unregister handlers when destroyed.
  impl_->events->SetStreamHandler(nullptr);
  impl_->methods->SetMethodCallHandler(nullptr);
}
}
