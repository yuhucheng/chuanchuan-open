#include "platform_bridge.h"
#include "device_preferences.h"
#include "native_discovery.h"
#include <shellapi.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <utility>

namespace share_hub {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
constexpr UINT_PTR kTimer = 0x53484453;
Value DeviceValue(const Device& device) {
  return Value(Map{{Value("id"), Value(device.id)}, {Value("name"), Value(device.name)}});
}
Value SnapshotValue(const DiscoverySnapshot& snapshot) {
  List devices;
  for (const auto& device : snapshot.devices) {
    devices.emplace_back(Map{{Value("id"), Value(device.id)}, {Value("name"), Value(device.name)},
                             {Value("platform"), Value(device.platform)}});
  }
  Map value{{Value("state"), Value(snapshot.state)}, {Value("devices"), Value(devices)}};
  if (!snapshot.message.empty()) value[Value("message")] = Value(snapshot.message);
  return Value(value);
}
}
struct PlatformBridge::Impl {
  Impl(HWND window, std::wstring registry_key)
      : window(window), preferences(std::move(registry_key)), discovery(window) {}
  HWND window;
  bool loaded = false, closed = false;
  UINT_PTR timer = 0;
  DevicePreferences preferences;
  NativeDiscovery discovery;
  std::unique_ptr<flutter::MethodChannel<Value>> methods;
  std::unique_ptr<flutter::EventChannel<Value>> events;
  std::unique_ptr<flutter::EventSink<Value>> sink;
};
PlatformBridge::PlatformBridge(flutter::BinaryMessenger* messenger, HWND window,
                               std::wstring registry_key)
    : impl_(std::make_unique<Impl>(window, std::move(registry_key))) {
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
void PlatformBridge::Close() {
  if (impl_->closed) return;
  impl_->closed = true;
  if (impl_->timer) { KillTimer(impl_->window, impl_->timer); impl_->timer = 0; }
  impl_->discovery.Close(); impl_->sink.reset();
  // Channels do not automatically unregister handlers when destroyed.
  impl_->events->SetStreamHandler(nullptr);
  impl_->methods->SetMethodCallHandler(nullptr);
}
}
