#ifndef SHARE_HUB_DISCOVERY_MODEL_H_
#define SHARE_HUB_DISCOVERY_MODEL_H_

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace share_hub {
using TxtRecord = std::map<std::string, std::string>;
struct Device {
  std::string id, name, platform;
  // Advertised connection endpoint, present only while the peer accepts
  // connections: host is the ".local" name, port the TCP port, key the peer's
  // Ed25519 public key. Empty means discoverable but not connectable, so the UI
  // never offers a connection the peer cannot answer.
  std::string host, port, key;
};
struct DiscoverySnapshot {
  std::string state = "stopped";
  std::vector<Device> devices;
  std::string message;
};
enum class DiscoveryEventKind { Registered, Browse, Resolved, CleanupError, QueueOverflow };
enum class EventDisposition { Ignore, Handle, MailboxFailure };
std::optional<std::string> NormalizeName(const std::string& value);
std::optional<std::string> NormalizeUuid(const std::string& value);
std::optional<Device> ParseDevice(const TxtRecord& record, const std::string& local_id);

// TXT keys in the shared discovery contract, matching the macOS browser which
// reads the same seven. Advertising and parsing must agree on this set: dropping
// "host"/"port"/"key" from the parser leaves a peer that every other platform
// treats as connectable permanently non-connectable here.
inline bool IsAcceptedTxtKey(const std::string& key) {
  return key == "v" || key == "id" || key == "name" || key == "platform" ||
      key == "host" || key == "port" || key == "key";
}

// Main-thread state; token checks make callbacks from a previous run harmless.
class DiscoveryModel {
 public:
  uint64_t Start(const std::string& local_id);
  void Stop();
  void Registered(uint64_t token);
  void Browsing(uint64_t token, uintptr_t request = 1);
  bool AcceptBrowse(uint64_t token, uintptr_t request) const;
  EventDisposition ClassifyEvent(DiscoveryEventKind kind, uint64_t token, uintptr_t request) const;
  void Fail(uint64_t token, const std::string& message);
  void Update(uint64_t token, const std::string& instance, const TxtRecord& record,
              uint32_t ttl, uint64_t now);
  void ResolveStarted(uint64_t token, const std::string& instance, uintptr_t request);
  void Resolved(uint64_t token, const std::string& instance, uintptr_t request,
                const TxtRecord& record, uint32_t ttl, uint64_t now);
  void Remove(uint64_t token, const std::string& instance);
  void Expire(uint64_t now);
  const DiscoverySnapshot& snapshot() const { return snapshot_; }
  uint64_t generation() const { return generation_; }
 private:
  struct Entry { Device device; uint64_t expires; };
  void Rebuild();
  void Ready();
  uint64_t generation_ = 0;
  uintptr_t browser_request_ = 0;
  bool registered_ = false, browsing_ = false;
  std::string local_id_;
  std::map<std::string, Entry> entries_;
  std::map<std::string, uintptr_t> resolve_requests_;
  DiscoverySnapshot snapshot_;
};
}  // namespace share_hub
#endif
