// Dual-machine diagnostic. Browses the real LAN and prints every peer with the
// connection endpoint it advertises, so a silent peer (no endpoint published)
// can be told apart from a parser that drops the endpoint. With --advertise it
// also publishes its own endpoint, which lets a second copy verify the full
// cross-process advertise -> resolve path without a real peer.
// Usage: discovery_probe.exe [--advertise] [--seconds N] [--delay N] [report-path]
//   --seconds N  total observation window (default 25)
//   --delay N    settle seconds before advertising, to isolate the pending-
//                registration race from the endpoint rebuild
#include "native_discovery.h"
#include <objbase.h>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
using namespace share_hub;
namespace {
constexpr uint16_t kProbePort = 51999;
std::string NewId() {
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) return {};
  wchar_t text[40]{};
  StringFromGUID2(guid, text, 40);
  std::string value;
  for (int i = 1; i < 37; ++i) value.push_back(static_cast<char>(text[i]));
  return *NormalizeUuid(value);
}
std::string Describe(const Device& device) {
  std::ostringstream text;
  text << "platform=" << device.platform << "  id=" << device.id << "  name=" << device.name;
  if (device.host.empty()) {
    text << "  endpoint=none";
  } else {
    text << "  endpoint=" << device.host << ":" << device.port << "  key_length=" << device.key.size();
  }
  return text.str();
}
}
int main(int argc, char** argv) {
  bool advertise = false;
  int seconds = 25;
  int delay = 0;
  std::string report_path;
  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "--advertise") advertise = true;
    else if (argument == "--seconds" && i + 1 < argc) seconds = std::atoi(argv[++i]);
    else if (argument == "--delay" && i + 1 < argc) delay = std::atoi(argv[++i]);
    else report_path = argument;
  }
  if (seconds < 1) seconds = 1;
  if (delay < 0) delay = 0;
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const auto id = NewId();
  if (id.empty()) {
    std::cerr << "probe id generation failed\n";
    return 1;
  }
  NativeDiscovery probe;
  if (!probe.Start(id, "diagnostic-probe")) {
    std::cerr << "probe start failed: " << probe.snapshot().message << '\n';
    return 1;
  }
  std::ostringstream report;
  report << "self=" << id << '\n';
  const auto started = std::chrono::steady_clock::now();
  const auto deadline = started + std::chrono::seconds(seconds);
  const auto advertise_at = started + std::chrono::seconds(delay);
  bool advertised = false;
  while (std::chrono::steady_clock::now() < deadline) {
    probe.Pump();
    probe.Tick();
    if (advertise && !advertised && std::chrono::steady_clock::now() >= advertise_at) {
      advertised = true;
      report << "state_before_advertise=" << probe.snapshot().state << '\n';
      const std::string key(44, 'k');
      std::string host;
      if (!probe.Advertise(uint16_t{kProbePort}, key, &host)) {
        std::cerr << "probe advertise failed: " << probe.snapshot().message << '\n';
        return 1;
      }
      report << "self_endpoint=" << host << ":" << kProbePort << "  key_length=" << key.size() << '\n';
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  probe.Pump();
  probe.Tick();
  const auto& snapshot = probe.snapshot();
  report << "state=" << snapshot.state << "  peers=" << snapshot.devices.size() << '\n';
  if (!snapshot.message.empty()) report << "message=" << snapshot.message << '\n';
  for (const auto& device : snapshot.devices) report << Describe(device) << '\n';
  probe.Stop();
  probe.Close();
  const auto text = report.str();
  if (!report_path.empty()) std::ofstream(report_path, std::ios::binary) << text;
  std::cout << text;
  CoUninitialize();
  return 0;
}
