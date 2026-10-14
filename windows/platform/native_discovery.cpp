#include "native_discovery.h"
#include <windns.h>
#include <ws2tcpip.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

namespace share_hub {
namespace {
constexpr wchar_t kService[] = L"_sharehub-dev._tcp.local";
constexpr char kSuffix[] = "._sharehub-dev._tcp.local";
uint64_t Now() { return GetTickCount64() / 1000; }
std::wstring Wide(const std::string& text) {
  if (text.empty() || text.size() > 4096) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!size) return {};
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Utf8(const wchar_t* text) {
  if (!text) return {};
  const size_t length = wcsnlen_s(text, 1025);
  if (!length || length > 1024) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
  if (!size) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, static_cast<int>(length), result.data(), size, nullptr, nullptr);
  return result;
}
// The ".local" name peers resolve, matching the macOS local host name. UTF-8
// because it travels in a TXT record and is shown back as the "host:port"
// address. Empty means the platform refused to report a name.
std::string LocalHostname() {
  wchar_t name[256]{}; DWORD size = 256;
  if (!GetComputerNameExW(ComputerNameDnsHostname, name, &size)) return {};
  const auto text = Utf8(name);
  return text.empty() ? std::string{} : text + ".local";
}
std::optional<std::string> InstanceName(const wchar_t* text) {
  auto name = Utf8(text);
  if (!name.empty() && name.back() == '.') name.pop_back();
  if (name.size() <= sizeof(kSuffix) - 1 || name.size() > 253) return std::nullopt;
  for (char& c : name) {
    auto byte = static_cast<unsigned char>(c);
    if (byte < 32 || byte >= 127) return std::nullopt;
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
  }
  if (name.compare(name.size() - (sizeof(kSuffix) - 1), sizeof(kSuffix) - 1, kSuffix) != 0) return std::nullopt;
  return name;
}
// Runtime lookup lets unsupported Windows show a discovery error instead of
// preventing the entire application from loading.
struct Api {
  decltype(&DnsServiceConstructInstance) construct = nullptr;
  decltype(&DnsServiceFreeInstance) free_instance = nullptr;
  decltype(&DnsServiceRegister) register_service = nullptr;
  decltype(&DnsServiceDeRegister) deregister_service = nullptr;
  decltype(&DnsServiceBrowse) browse = nullptr;
  decltype(&DnsServiceBrowseCancel) cancel_browse = nullptr;
  decltype(&DnsServiceResolve) resolve = nullptr;
  decltype(&DnsServiceResolveCancel) cancel_resolve = nullptr;
  bool available = false;
  template <class T> static void Load(HMODULE module, const char* name, T& target) {
    const auto address = GetProcAddress(module, name);
    static_assert(sizeof(address) == sizeof(target));
    std::memcpy(&target, &address, sizeof(target));
  }
  Api() {
    auto module = LoadLibraryExW(L"dnsapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return;
    Load(module, "DnsServiceConstructInstance", construct);
    Load(module, "DnsServiceFreeInstance", free_instance);
    Load(module, "DnsServiceRegister", register_service);
    Load(module, "DnsServiceDeRegister", deregister_service);
    Load(module, "DnsServiceBrowse", browse);
    Load(module, "DnsServiceBrowseCancel", cancel_browse);
    Load(module, "DnsServiceResolve", resolve);
    Load(module, "DnsServiceResolveCancel", cancel_resolve);
    available = construct && free_instance && register_service && deregister_service &&
        browse && cancel_browse && resolve && cancel_resolve;
    // Retain module until process exit: callbacks may outlive a window.
  }
  static Api& Get() { static auto* api = new Api(); return *api; }
};
using Kind = DiscoveryEventKind;
struct PointerRecord { std::string instance; uint32_t ttl; };
struct WireTxt { std::string instance; TxtRecord txt; uint32_t ttl; };
struct WireAddress { std::string host; std::string address; uint32_t ttl; };
struct Event {
  Kind kind = Kind::Browse;
  uint64_t token = 0;
  DWORD status = 0;
  uintptr_t operation = 0;
  std::string instance;
  TxtRecord txt;
  // Fresh records from the browse callback itself (the wire, not the OS
  // resolver cache). The resolve path returned stale TXT for live peers, so
  // endpoint state and the numeric fallback address are driven by these.
  std::vector<PointerRecord> pointers;
  std::vector<WireTxt> wire_txt;
  std::vector<WireAddress> wire_addresses;
};
// Case-insensitive host key for matching A records to the advertised TXT host.
std::string HostKey(const std::string& value) {
  std::string key = value;
  if (!key.empty() && key.back() == '.') key.pop_back();
  for (char& c : key) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
  return key;
}
struct Mailbox {
  std::mutex mutex;
  HWND target = nullptr;
  bool closed = false;
  std::deque<Event> events;
  std::atomic<size_t> pending{0};
  std::atomic<bool> cleanup_error{false};
  void Post(Event event) {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed) return;
    if (events.size() >= 256) {
      events.clear(); const auto token = event.token;
      event = Event{}; event.kind = Kind::QueueOverflow; event.token = token; event.status = ERROR_BUFFER_OVERFLOW;
    }
    events.push_back(std::move(event));
    if (target) PostMessageW(target, NativeDiscovery::kMessage, 0, 0);
  }
};
struct Registration {
  std::mutex mutex;
  std::shared_ptr<Mailbox> mailbox;
  uint64_t token = 0;
  DNS_SERVICE_INSTANCE* instance = nullptr;
  bool registered = false;
  std::atomic<bool> stopping{false}, deregistering{false};
  ~Registration() { if (instance) Api::Get().free_instance(instance); }
};
struct Operation {
  uintptr_t number = 0;
  uint64_t token = 0;
  std::shared_ptr<Mailbox> mailbox;
  std::wstring query;
  std::shared_ptr<Registration> registration;
  bool deregistration = false;
  DNS_SERVICE_CANCEL cancel{};
  DNS_SERVICE_BROWSE_REQUEST browse{};
  DNS_SERVICE_RESOLVE_REQUEST resolve{};
  DNS_SERVICE_REGISTER_REQUEST registration_request{};
  Operation(const std::shared_ptr<Mailbox>& mailbox, uint64_t token)
      : token(token), mailbox(mailbox) { ++mailbox->pending; }
  ~Operation() { --mailbox->pending; }
};
// OS sees opaque increasing keys, never a window/this pointer. Request buffers
// remain alive until terminal callbacks. Callback races take shared ownership;
// no pointer to freed operation memory is dereferenced during lookup.
struct Operations {
  std::mutex mutex;
  uintptr_t next = 0;
  std::map<uintptr_t, std::shared_ptr<Operation>> active;
  static Operations& Get() { static auto* operations = new Operations(); return *operations; }
  void Add(const std::shared_ptr<Operation>& operation) {
    std::lock_guard<std::mutex> lock(mutex);
    operation->number = ++next; active[operation->number] = operation;
  }
  std::shared_ptr<Operation> Find(void* context, bool terminal) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it = active.find(reinterpret_cast<uintptr_t>(context));
    if (it == active.end()) return {};
    auto result = it->second;
    if (terminal) active.erase(it);
    return result;
  }
  void Remove(uintptr_t number) {
    std::lock_guard<std::mutex> lock(mutex); active.erase(number);
  }
};
void Post(const std::shared_ptr<Operation>& operation, Event event) {
  event.token = operation->token; event.operation = operation->number;
  operation->mailbox->Post(std::move(event));
}
void Deregister(const std::shared_ptr<Registration>& registration);
void WINAPI RegistrationComplete(DWORD status, void* context, DNS_SERVICE_INSTANCE* instance) {
  auto operation = Operations::Get().Find(context, true);
  if (!operation) { if (instance) Api::Get().free_instance(instance); return; }
  auto registration = operation->registration;
  if (operation->deregistration) {
    if (instance) Api::Get().free_instance(instance);
    if (status != ERROR_SUCCESS) {
      operation->mailbox->cleanup_error = true;
      Event event; event.kind = Kind::CleanupError; event.status = status; Post(operation, std::move(event));
    }
    return;
  }
  {
    std::lock_guard<std::mutex> lock(registration->mutex);
    registration->registered = status == ERROR_SUCCESS;
    // A conflicting registration may be renamed. Remove the actual instance.
    if (status == ERROR_SUCCESS && instance) {
      Api::Get().free_instance(registration->instance);
      registration->instance = instance; instance = nullptr;
    }
  }
  if (instance) Api::Get().free_instance(instance);
  Event event; event.kind = Kind::Registered; event.status = status; Post(operation, std::move(event));
  if (registration->stopping) Deregister(registration);
}
void Deregister(const std::shared_ptr<Registration>& registration) {
  {
    std::lock_guard<std::mutex> lock(registration->mutex);
    if (!registration->registered) return;
  }
  if (registration->deregistering.exchange(true)) return;
  auto box = registration->mailbox;
  auto operation = std::make_shared<Operation>(box, registration->token);
  operation->registration = registration; operation->deregistration = true;
  Operations::Get().Add(operation);
  auto& request = operation->registration_request;
  request.Version = DNS_QUERY_REQUEST_VERSION1;
  request.pServiceInstance = registration->instance;
  request.pRegisterCompletionCallback = RegistrationComplete;
  request.pQueryContext = reinterpret_cast<void*>(operation->number);
  auto status = Api::Get().deregister_service(&request, nullptr);
  if (status != DNS_REQUEST_PENDING) {
    Operations::Get().Remove(operation->number);
    if (status != ERROR_SUCCESS) {
      box->cleanup_error = true;
      Event event; event.kind = Kind::CleanupError; event.status = status; Post(operation, std::move(event));
    }
  }
}
void WINAPI BrowseComplete(DWORD status, void* context, DNS_RECORD* records) {
  auto operation = Operations::Get().Find(context, status == ERROR_CANCELLED);
  if (operation && status != ERROR_CANCELLED) {
    Event event; event.kind = Kind::Browse; event.status = status;
    size_t count = 0;
    for (auto* record = records; record && count++ < 256; record = record->pNext) {
      if (record->wType == DNS_TYPE_PTR) {
        auto instance = InstanceName(record->Data.PTR.pNameHost);
        if (instance) event.pointers.push_back({*instance, record->dwTtl});
        continue;
      }
      if (record->wType == static_cast<WORD>(16)) {  // DNS_TYPE_TXT
        // The browse callback carries the live advertisement itself: fresh TXT
        // arrives here even while DnsServiceResolve keeps serving a cached copy.
        auto instance = InstanceName(record->pName);
        if (!instance) continue;
        TxtRecord txt;
        bool malformed = false;
        const auto& data = record->Data.Txt;
        // Browse TXT strings are wide, unlike the resolve property list.
        for (DWORD i = 0; i < data.dwStringCount && !malformed; ++i) {
          const auto entry = Utf8(reinterpret_cast<const wchar_t*>(data.pStringArray[i]));
          const auto split = entry.find('=');
          if (split == std::string::npos) continue;
          const auto key = entry.substr(0, split);
          if (!IsAcceptedTxtKey(key)) continue;
          if (txt.count(key)) { malformed = true; break; }
          txt[key] = entry.substr(split + 1);
        }
        // A malformed record is ignored, never allowed to flush a healthy peer.
        if (!malformed) event.wire_txt.push_back({*instance, std::move(txt), record->dwTtl});
        continue;
      }
      if (record->wType == DNS_TYPE_A) {
        IN_ADDR value{};
        value.s_addr = record->Data.A.IpAddress;
        char text[INET_ADDRSTRLEN]{};
        const auto host = HostKey(Utf8(record->pName));
        if (!host.empty() && inet_ntop(AF_INET, &value, text, sizeof(text)))
          event.wire_addresses.push_back({host, text, record->dwTtl});
      }
    }
    Post(operation, std::move(event));
  }
  if (records) DnsRecordListFree(records, DnsFreeRecordList);
}
// Presence only: accept then immediately close without reading any input.
struct Listener {
  SOCKET socket = INVALID_SOCKET;
  uint16_t port = 0;
  std::atomic<bool> stopping{false};
  std::thread worker;
  bool Start() {
    socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) return false;
    BOOL exclusive = TRUE;
    setsockopt(socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
    sockaddr_in address{}; address.sin_family = AF_INET;
    if (bind(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || listen(socket, 8) != 0) return false;
    int size = sizeof(address);
    if (getsockname(socket, reinterpret_cast<sockaddr*>(&address), &size) != 0) return false;
    port = ntohs(address.sin_port);
    u_long nonblocking = 1;
    if (ioctlsocket(socket, FIONBIO, &nonblocking) != 0) return false;
    worker = std::thread([this] {
      while (!stopping) {
        fd_set readable; FD_ZERO(&readable); FD_SET(socket, &readable);
        timeval timeout{0, 100000};
        if (select(0, &readable, nullptr, nullptr, &timeout) > 0) {
          auto connection = accept(socket, nullptr, nullptr);
          if (connection != INVALID_SOCKET) closesocket(connection);
        }
      }
    });
    return true;
  }
  ~Listener() {
    stopping = true;
    if (worker.joinable()) worker.join();
    if (socket != INVALID_SOCKET) closesocket(socket);
  }
};
}
struct NativeDiscovery::Impl {
  explicit Impl(HWND target) : mailbox(std::make_shared<Mailbox>()) {
    mailbox->target = target; WSADATA data{}; winsock = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }
  ~Impl() { if (winsock) WSACleanup(); }
  DiscoveryModel model;
  std::shared_ptr<Mailbox> mailbox;
  std::shared_ptr<Registration> registration;
  std::shared_ptr<Operation> browser;
  // Latest A-record answers by host key, used for the numeric connect fallback.
  std::map<std::string, std::string> host_addresses;
  std::unique_ptr<Listener> listener;
  // Presence values and the advertised endpoint are kept so a TXT change can
  // rebuild the registration without the caller re-supplying the identity.
  std::string presence_id_, presence_name_;
  std::optional<uint16_t> advertise_port_;
  std::optional<std::string> advertise_key_;
  uint64_t last_browse = 0;
  bool winsock = false, closed = false;
  void CancelBrowser() {
    if (browser) {
      const auto status = Api::Get().cancel_browse(&browser->cancel);
      if (status != ERROR_SUCCESS) {
        mailbox->cleanup_error = true;
        Event event; event.kind = Kind::CleanupError; event.status = status;
        Post(browser, std::move(event));
      }
      browser.reset();
    }
  }
  void StopOperations() {
    CancelBrowser();
    host_addresses.clear();
    if (registration) { registration->stopping = true; Deregister(registration); registration.reset(); }
    listener.reset();
  }
  bool Browse() {
    auto operation = std::make_shared<Operation>(mailbox, model.generation());
    operation->query = kService; Operations::Get().Add(operation);
    auto& request = operation->browse;
    request.Version = DNS_QUERY_REQUEST_VERSION1; request.QueryName = operation->query.c_str();
    request.pBrowseCallback = BrowseComplete; request.pQueryContext = reinterpret_cast<void*>(operation->number);
    auto status = Api::Get().browse(&request, &operation->cancel);
    if (status != DNS_REQUEST_PENDING) { Operations::Get().Remove(operation->number); return false; }
    browser = operation; last_browse = Now(); model.Browsing(model.generation(), operation->number); return true;
  }
};
NativeDiscovery::NativeDiscovery(HWND target) : impl_(std::make_unique<Impl>(target)) {}
NativeDiscovery::~NativeDiscovery() { Close(); }
bool NativeDiscovery::Start(const std::string& id, const std::string& name) {
  Stop();
  const auto token = impl_->model.Start(id);
  auto fail = [&](const std::string& error) {
    impl_->StopOperations(); impl_->model.Fail(token, error); Emit(); return false;
  };
  const auto presence_id = NormalizeUuid(id), presence_name = NormalizeName(name);
  if (impl_->closed || !presence_id || !presence_name) return fail(u8"设备信息无效，无法开始发现。");
  impl_->presence_id_ = *presence_id; impl_->presence_name_ = *presence_name;
  if (!Api::Get().available) return fail(u8"此 Windows 缺少系统 DNS-SD 接口，请更新系统后重试。");
  if (!impl_->winsock || impl_->mailbox->pending > 128 || impl_->mailbox->cleanup_error)
    return fail(u8"网络组件尚未就绪或正在清理，请稍后重试。");
  impl_->listener = std::make_unique<Listener>();
  if (!impl_->listener->Start()) return fail(u8"无法启动设备发现监听器，请检查网络后重试。");
  wchar_t hostname[256]{}; DWORD size = 256;
  if (!GetComputerNameExW(ComputerNameDnsHostname, hostname, &size)) return fail(u8"无法读取本机网络名称。");
  std::wstring host = hostname; host += L".local";
  const auto wide_id = Wide(*presence_id), wide_name = Wide(*presence_name);
  std::wstring instance_name = wide_id + L"." + kService;
  std::vector<std::wstring> keys{L"v", L"id", L"name", L"platform"};
  std::vector<std::wstring> values{L"1", wide_id, wide_name, L"windows"};
  // The endpoint travels in TXT so peers offer "connect" only while we are
  // actually listening; it is absent whenever "允许连接" is off.
  if (impl_->advertise_port_ && impl_->advertise_key_) {
    keys.push_back(L"host"); values.push_back(host);
    keys.push_back(L"port"); values.push_back(std::to_wstring(*impl_->advertise_port_));
    keys.push_back(L"key"); values.push_back(Wide(*impl_->advertise_key_));
  }
  std::vector<PCWSTR> key_ptrs; key_ptrs.reserve(keys.size());
  for (const auto& item : keys) key_ptrs.push_back(item.c_str());
  std::vector<PCWSTR> value_ptrs; value_ptrs.reserve(values.size());
  for (const auto& item : values) value_ptrs.push_back(item.c_str());
  auto registration = std::make_shared<Registration>();
  registration->mailbox = impl_->mailbox; registration->token = token;
  registration->instance = Api::Get().construct(instance_name.c_str(), host.c_str(), nullptr, nullptr,
      impl_->listener->port, 0, 0, static_cast<DWORD>(key_ptrs.size()), key_ptrs.data(), value_ptrs.data());
  if (!registration->instance) return fail(u8"无法创建 DNS-SD 设备记录。");
  impl_->registration = registration;
  auto operation = std::make_shared<Operation>(impl_->mailbox, token);
  operation->registration = registration; Operations::Get().Add(operation);
  auto& request = operation->registration_request;
  request.Version = DNS_QUERY_REQUEST_VERSION1; request.pServiceInstance = registration->instance;
  request.pRegisterCompletionCallback = RegistrationComplete;
  request.pQueryContext = reinterpret_cast<void*>(operation->number);
  auto status = Api::Get().register_service(&request, &operation->cancel);
  if (status != DNS_REQUEST_PENDING) {
    Operations::Get().Remove(operation->number);
    return fail(u8"DNS-SD 广播启动失败（" + std::to_string(status) + u8"），请检查网络策略。");
  }
  Emit();
  if (!impl_->Browse()) return fail(u8"DNS-SD 浏览启动失败，请检查网络策略。");
  return true;
}
bool NativeDiscovery::Advertise(const std::optional<uint16_t>& port,
                                const std::optional<std::string>& key,
                                std::string* hostname) {
  const auto host = LocalHostname();
  if (host.empty()) return false;
  const bool valid = port && key && *port >= 1;
  std::optional<uint16_t> next_port;
  std::optional<std::string> next_key;
  if (valid) { next_port = port; next_key = key; }
  const bool changed =
      impl_->advertise_port_ != next_port || impl_->advertise_key_ != next_key;
  impl_->advertise_port_ = next_port;
  impl_->advertise_key_ = next_key;
  // Windows cannot update a TXT record in place, so the registration is rebuilt
  // when the endpoint changes. Only do it while discovery is live; a stopped run
  // picks the new endpoint up on its next Start.
  const auto state = snapshot().state;
  if (changed && !impl_->presence_id_.empty() &&
      (state == "searching" || state == "starting")) {
    if (!Start(impl_->presence_id_, impl_->presence_name_)) return false;
  }
  if (hostname) *hostname = host;
  return true;
}
void NativeDiscovery::Stop() { impl_->model.Stop(); impl_->StopOperations(); Emit(); }
void NativeDiscovery::Pump() {
  std::deque<Event> events;
  { std::lock_guard<std::mutex> lock(impl_->mailbox->mutex); events.swap(impl_->mailbox->events); }
  for (const auto& event : events) {
    if (impl_->closed) break;
    const auto disposition = impl_->model.ClassifyEvent(event.kind, event.token, event.operation);
    if (disposition == EventDisposition::MailboxFailure) {
      const auto token = impl_->model.generation(); impl_->StopOperations();
      const auto message = event.kind == Kind::CleanupError || impl_->mailbox->cleanup_error
          ? u8"发现服务未完全停止，请退出应用后重试。"
          : u8"发现事件队列已满，请检查网络后重新开启发现。";
      impl_->model.Fail(token, message); Emit(); continue;
    }
    if (disposition == EventDisposition::Ignore) continue;
    if (event.kind == Kind::Browse && !impl_->browser) continue;
    if (event.status != ERROR_SUCCESS) {
      impl_->StopOperations();
      impl_->model.Fail(event.token, u8"局域网发现失败（" + std::to_string(event.status) + u8"），请检查网络与防火墙后重试。");
    } else if (event.kind == Kind::Registered) impl_->model.Registered(event.token);
    else {
      // Wire-driven updates: fresh A answers first so a TXT in the same batch
      // can attach its numeric fallback, then goodbyes, then live TXT state.
      for (const auto& wire : event.wire_addresses) {
        if (wire.ttl == 0) impl_->host_addresses.erase(wire.host);
        else impl_->host_addresses[wire.host] = wire.address;
      }
      for (const auto& pointer : event.pointers) {
        if (pointer.ttl == 0) impl_->model.Remove(event.token, pointer.instance);
      }
      for (const auto& wire : event.wire_txt) {
        std::string address;
        const auto host = wire.txt.find("host");
        if (host != wire.txt.end()) {
          const auto found = impl_->host_addresses.find(HostKey(host->second));
          if (found != impl_->host_addresses.end()) address = found->second;
        }
        impl_->model.Update(event.token, wire.instance, wire.txt, wire.ttl, Now(), address);
      }
    }
    Emit();
  }
}
void NativeDiscovery::Tick() {
  if (impl_->closed || (snapshot().state != "searching" && snapshot().state != "starting")) return;
  impl_->model.Expire(Now());
  // Windows does not guarantee goodbye callbacks. Periodic enumeration and
  // bounded leases remove records after they disappear from discovery.
  if (impl_->browser && Now() - impl_->last_browse >= 30) {
    impl_->CancelBrowser();
    if (!impl_->Browse()) {
      auto token = impl_->model.generation(); impl_->StopOperations();
      impl_->model.Fail(token, u8"发现刷新失败，请检查网络后重新开启。");
    }
  }
  Emit();
}
void NativeDiscovery::Close() {
  if (impl_->closed) return;
  impl_->closed = true; on_change = nullptr;
  { std::lock_guard<std::mutex> lock(impl_->mailbox->mutex); impl_->mailbox->closed = true;
    impl_->mailbox->target = nullptr; impl_->mailbox->events.clear(); }
  Stop();
}
const DiscoverySnapshot& NativeDiscovery::snapshot() const { return impl_->model.snapshot(); }
bool NativeDiscovery::cleanup_pending() const { return impl_->mailbox->pending != 0 || impl_->mailbox->cleanup_error; }
void NativeDiscovery::Emit() { if (on_change) on_change(snapshot()); }
}  // namespace share_hub
