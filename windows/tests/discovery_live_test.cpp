#include "native_discovery.h"
#include <objbase.h>
#include <chrono>
#include <iostream>
#include <thread>
using namespace share_hub;
namespace {
std::string NewId() {
  GUID guid{}; if (FAILED(CoCreateGuid(&guid))) return {};
  wchar_t text[40]{}; StringFromGUID2(guid, text, 40);
  std::string value;
  for (int i = 1; i < 37; ++i) value.push_back(static_cast<char>(text[i]));
  return *NormalizeUuid(value);
}
bool Contains(const NativeDiscovery& service, const std::string& id) {
  for (const auto& device : service.snapshot().devices) if (device.id == id) return true;
  return false;
}
template <class Predicate>
bool Wait(NativeDiscovery& left, NativeDiscovery& right, int seconds, Predicate predicate) {
  auto until = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  do {
    left.Pump(); right.Pump(); left.Tick(); right.Tick();
    if (predicate()) return true;
    if (left.snapshot().state == "failed" || right.snapshot().state == "failed") {
      std::cerr << "discovery error: " << left.snapshot().message << " " << right.snapshot().message << '\n';
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  } while (std::chrono::steady_clock::now() < until);
  return false;
}
}
int main() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const auto a = NewId(), b = NewId();
  NativeDiscovery left, right;
  auto phase = std::chrono::steady_clock::now();
  auto elapsed = [&] { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - phase).count(); };
  if (!left.Start(a, u8"原生测试 A") || !right.Start(b, u8"原生测试 B")) {
    std::cerr << "FAIL: native start: " << left.snapshot().message << " " << right.snapshot().message << '\n'; return 1;
  }
  if (!Wait(left, right, 30, [&] { return Contains(left, b) && Contains(right, a); })) {
    std::cerr << "FAIL: two native DNS-SD instances did not discover each other\n"; return 1;
  }
  if (Contains(left, a) || Contains(right, b)) { std::cerr << "FAIL: self discovery\n"; return 1; }
  std::cout << "PASS: two native instances with UTF-8 TXT discovered; self filtered; discovery_ms=" << elapsed() << std::endl;
  phase = std::chrono::steady_clock::now();
  if (!Wait(left, right, 40, [&] { return elapsed() >= 35000; }) || !Contains(left, b) || !Contains(right, a)) {
    std::cerr << "FAIL: discovery did not survive a periodic browse refresh\n"; return 1;
  }
  std::cout << "PASS: both peers retained across browse refresh; observation_ms=" << elapsed() << std::endl;
  phase = std::chrono::steady_clock::now();
  right.Stop();
  if (!Wait(left, right, 135, [&] { return !Contains(left, b); })) {
    std::cerr << "FAIL: stopped advertiser remained beyond bounded lease\n"; return 1;
  }
  std::cout << "PASS: stopped peer removed; removal_ms=" << elapsed() << std::endl;
  phase = std::chrono::steady_clock::now();
  left.Stop(); right.Stop();
  if (!Wait(left, right, 15, [&] { return !left.cleanup_pending() && !right.cleanup_pending(); })) {
    std::cerr << "FAIL: DNS-SD asynchronous operations did not clean up\n"; return 1;
  }
  std::cout << "PASS: all active DNS-SD operations cleaned; cleanup_ms=" << elapsed() << std::endl;
  // Stop while registration is pending; late completion must deregister safely.
  left.Start(a, "pending-stop"); left.Stop();
  if (!Wait(left, right, 15, [&] { return !left.cleanup_pending(); })) {
    std::cerr << "FAIL: pending registration cleanup\n"; return 1;
  }
  if (!left.snapshot().devices.empty() || left.snapshot().state != "stopped") {
    std::cerr << "FAIL: late callback changed stopped state\n"; return 1;
  }
  left.Close(); right.Close(); CoUninitialize();
  std::cout << "PASS: repeated stop, pending stop and callback cleanup\n";
  return 0;
}
