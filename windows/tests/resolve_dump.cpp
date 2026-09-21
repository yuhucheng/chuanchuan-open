// Authoritative diagnostic for one question: what does Windows dnsapi actually
// hand back for a remote instance's TXT record? It calls DnsServiceBrowse and
// DnsServiceResolve directly, bypassing our model/whitelist/parser entirely, and
// prints dwPropertyCount plus every key/value verbatim (with byte lengths).
//
// This separates "the peer never published host/port/key" from "our parser
// dropped them" from "dnsapi never delivered them", which the app-level probe and
// the raw multicast sniffer cannot distinguish on their own.
//
// Usage: resolve_dump.exe [seconds]   (default 12)
#include <winsock2.h>
#include <windows.h>
#include <windns.h>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {
constexpr wchar_t kService[] = L"_sharehub-dev._tcp.local";

std::string Utf8(const wchar_t* text) {
  if (!text) return "<null>";
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return "<invalid>";
  std::string result(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
  return result;
}

struct Api {
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
    Load(module, "DnsServiceBrowse", browse);
    Load(module, "DnsServiceBrowseCancel", cancel_browse);
    Load(module, "DnsServiceResolve", resolve);
    Load(module, "DnsServiceResolveCancel", cancel_resolve);
    available = browse && cancel_browse && resolve && cancel_resolve;
  }
  static Api& Get() { static auto* api = new Api(); return *api; }
};

// Request buffers must outlive their callbacks; this is a short-lived tool, so
// leaking them until process exit is deliberate and safe.
struct ResolveRequest {
  DNS_SERVICE_RESOLVE_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};
};

// Raw TXT answer for the instance, bypassing the cache. This separates
// "the peer answered with four keys" from "DnsServiceResolve dropped three".
void DumpTxt(const wchar_t* name) {
  DNS_RECORD* records = nullptr;
  const auto status = DnsQuery_W(name, static_cast<WORD>(16), DNS_QUERY_BYPASS_CACHE, nullptr, &records, nullptr);
  std::cout << "  direct TXT query status=" << status << '\n';
  if (status != 0) return;
  for (auto* record = records; record; record = record->pNext) {
    if (record->wType != static_cast<WORD>(16)) continue;
    const auto& data = record->Data.Txt;
    std::cout << "    string_count=" << data.dwStringCount << "  ttl=" << record->dwTtl << '\n';
    for (DWORD i = 0; i < data.dwStringCount; ++i) {
      const auto* bytes = reinterpret_cast<const char*>(data.pStringArray[i]);
      std::cout << "      [" << i << "] \"" << bytes << "\"\n";
    }
  }
  if (records) DnsRecordListFree(records, DnsFreeRecordList);
}

void WINAPI ResolveComplete(DWORD status, void* context, DNS_SERVICE_INSTANCE* instance) {
  (void)context;
  std::cout << "\n=== resolve callback ===\n";
  std::cout << "status=" << status << '\n';
  if (status != ERROR_SUCCESS || !instance) {
    std::cout << "no instance\n";
    return;
  }
  std::cout << "instance=" << Utf8(instance->pszInstanceName) << '\n';
  std::cout << "host=" << Utf8(instance->pszHostName) << "  port=" << instance->wPort
            << "  ipv4=" << instance->ip4Address << '\n';
  std::cout << "dwPropertyCount=" << instance->dwPropertyCount << '\n';
  if (!instance->keys || !instance->values) {
    std::cout << "keys/values null\n";
    return;
  }
  const DWORD count = instance->dwPropertyCount;
  for (DWORD i = 0; i < count; ++i) {
    const auto* key = instance->keys[i];
    const auto* value = instance->values[i];
    const size_t key_length = key ? wcslen(key) : 0;
    const size_t value_length = value ? wcslen(value) : 0;
    std::cout << "  [" << i << "] key=\"" << Utf8(key) << "\" (len " << key_length
              << ") value=\"" << Utf8(value) << "\" (len " << value_length << ")\n";
  }
  DumpTxt(instance->pszInstanceName);
}

void WINAPI BrowseComplete(DWORD status, void* context, DNS_RECORD* records) {
  (void)context;
  std::cout << "\n=== browse callback === status=" << status << '\n';
  if (status != ERROR_SUCCESS) return;
  for (auto* record = records; record; record = record->pNext) {
    if (record->wType != DNS_TYPE_PTR) continue;
    const auto* instance = record->Data.PTR.pNameHost;
    std::cout << "PTR " << Utf8(instance) << "  ttl=" << record->dwTtl << '\n';
    auto* operation = new ResolveRequest();
    operation->request.Version = DNS_QUERY_REQUEST_VERSION1;
    operation->request.QueryName = record->Data.PTR.pNameHost;
    operation->request.pResolveCompletionCallback = ResolveComplete;
    operation->request.pQueryContext = nullptr;
    const auto resolve_status = Api::Get().resolve(&operation->request, &operation->cancel);
    std::cout << "  resolve issued status=" << resolve_status << '\n';
  }
}
}

int main(int argc, char** argv) {
  int seconds = 12;
  if (argc > 1) seconds = std::atoi(argv[1]);
  if (seconds < 1) seconds = 1;

  if (!Api::Get().available) {
    std::cerr << "dnsapi service functions unavailable\n";
    return 1;
  }

  static DNS_SERVICE_CANCEL cancel{};
  static DNS_SERVICE_BROWSE_REQUEST request{};
  request.Version = DNS_QUERY_REQUEST_VERSION1;
  request.QueryName = kService;
  request.pBrowseCallback = BrowseComplete;
  request.pQueryContext = nullptr;

  const auto status = Api::Get().browse(&request, &cancel);
  std::cout << "browse issued status=" << status << '\n';
  if (status != DNS_REQUEST_PENDING) return 1;

  Sleep(static_cast<DWORD>(seconds) * 1000);
  Api::Get().cancel_browse(&cancel);
  Sleep(500);
  return 0;
}
