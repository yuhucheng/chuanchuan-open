#include "discovery_model.h"
#include <algorithm>
#include <cctype>
#include <tuple>

namespace share_hub {
namespace {
struct Scalar { uint32_t value; size_t offset; };
bool Whitespace(uint32_t c) {
  return (c >= 9 && c <= 13) || c == 32 || c == 0x85 || c == 0xA0 ||
      c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
      c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}
bool Control(uint32_t c) {
  // Match Foundation's controlCharacters (Cc + Cf), using Unicode 16.0:
  // https://www.unicode.org/Public/16.0.0/ucd/extracted/DerivedGeneralCategory.txt
  return c < 32 || (c >= 0x7F && c <= 0x9F) || c == 0xAD ||
      (c >= 0x600 && c <= 0x605) || c == 0x61C || c == 0x6DD || c == 0x70F ||
      (c >= 0x890 && c <= 0x891) || c == 0x8E2 || c == 0x180E ||
      (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) ||
      (c >= 0x2060 && c <= 0x2064) || (c >= 0x2066 && c <= 0x206F) ||
      c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB) || c == 0x110BD ||
      c == 0x110CD || (c >= 0x13430 && c <= 0x1343F) ||
      (c >= 0x1BCA0 && c <= 0x1BCA3) || (c >= 0x1D173 && c <= 0x1D17A) ||
      c == 0xE0001 || (c >= 0xE0020 && c <= 0xE007F);
}
std::optional<std::vector<Scalar>> Decode(const std::string& value) {
  std::vector<Scalar> result;
  for (size_t i = 0; i < value.size();) {
    const size_t start = i;
    const auto first = static_cast<unsigned char>(value[i++]);
    uint32_t cp = 0, minimum = 0;
    size_t extra = 0;
    if (first < 0x80) cp = first;
    else if (first >= 0xC2 && first <= 0xDF) { cp = first & 0x1F; extra = 1; minimum = 0x80; }
    else if (first >= 0xE0 && first <= 0xEF) { cp = first & 0x0F; extra = 2; minimum = 0x800; }
    else if (first >= 0xF0 && first <= 0xF4) { cp = first & 0x07; extra = 3; minimum = 0x10000; }
    else return std::nullopt;
    if (extra > value.size() - i) return std::nullopt;
    for (size_t j = 0; j < extra; ++j) {
      auto next = static_cast<unsigned char>(value[i++]);
      if ((next & 0xC0) != 0x80) return std::nullopt;
      cp = (cp << 6) | (next & 0x3F);
    }
    if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return std::nullopt;
    result.push_back({cp, start});
  }
  return result;
}
}
std::optional<std::string> NormalizeName(const std::string& value) {
  // Bound decoding even when a caller passes an untrusted method argument.
  if (value.size() > 4096) return std::nullopt;
  auto scalars = Decode(value);
  if (!scalars) return std::nullopt;
  size_t first = 0, last = scalars->size();
  while (first < last && Whitespace((*scalars)[first].value)) ++first;
  while (last > first && Whitespace((*scalars)[last - 1].value)) --last;
  if (first == last) return std::nullopt;
  for (size_t i = first; i < last; ++i) if (Control((*scalars)[i].value)) return std::nullopt;
  const auto begin = (*scalars)[first].offset;
  const auto end = last == scalars->size() ? value.size() : (*scalars)[last].offset;
  if (end - begin > 128) return std::nullopt;
  return value.substr(begin, end - begin);
}
std::optional<std::string> NormalizeUuid(const std::string& value) {
  if (value.size() != 36) return std::nullopt;
  std::string result = value;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return std::nullopt; }
    else {
      const auto c = static_cast<unsigned char>(value[i]);
      if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return std::nullopt;
      result[i] = static_cast<char>(std::tolower(c));
    }
  }
  return result;
}
std::optional<Device> ParseDevice(const TxtRecord& record, const std::string& local_id) {
  for (const auto* key : {"v", "id", "name", "platform"}) if (!record.count(key)) return std::nullopt;
  if (record.at("v") != "1") return std::nullopt;
  auto id = NormalizeUuid(record.at("id"));
  auto name = NormalizeName(record.at("name"));
  auto local = NormalizeUuid(local_id);
  const auto& platform = record.at("platform");
  if (!id || !name || (local && *id == *local) || record.at("name").size() > 128 ||
      (platform != "macos" && platform != "windows" && platform != "android")) return std::nullopt;
  // Names received from peers retain their spelling, matching the Mac contract.
  auto raw = Decode(record.at("name"));
  for (const auto& c : *raw) if (Control(c.value)) return std::nullopt;
  Device device{*id, record.at("name"), platform};
  // Mirror the macOS endpoint gate exactly: a partial or malformed
  // advertisement stays discoverable but not connectable, so it can never be
  // offered as a verified endpoint.
  const auto host_field = record.find("host");
  const auto port_field = record.find("port");
  const auto key_field = record.find("key");
  if (host_field != record.end() && port_field != record.end() && key_field != record.end()) {
    const auto& hostname = host_field->second;
    const auto& text = port_field->second;
    bool digits = !text.empty() && text.size() <= 5;
    uint32_t number = 0;
    for (const char c : text) {
      if (c < '0' || c > '9') { digits = false; break; }
      number = number * 10 + static_cast<uint32_t>(c - '0');
    }
    if (digits && number >= 1 && number <= 65535 &&
        hostname.size() >= 6 && hostname.size() <= 253 &&
        hostname.compare(hostname.size() - 6, 6, ".local") == 0 &&
        key_field->second.size() == 44) {
      device.host = hostname; device.port = text; device.key = key_field->second;
    }
  }
  return device;
}
uint64_t DiscoveryModel::Start(const std::string& local_id) {
  Stop(); local_id_ = local_id; snapshot_.state = "starting"; return generation_;
}
void DiscoveryModel::Stop() {
  ++generation_; registered_ = browsing_ = false; browser_request_ = 0;
  entries_.clear(); resolve_requests_.clear(); snapshot_ = DiscoverySnapshot{};
}
void DiscoveryModel::Registered(uint64_t token) { if (token == generation_) { registered_ = true; Ready(); } }
void DiscoveryModel::Browsing(uint64_t token, uintptr_t request) {
  if (token == generation_) { browser_request_ = request; browsing_ = true; Ready(); }
}
bool DiscoveryModel::AcceptBrowse(uint64_t token, uintptr_t request) const {
  return token == generation_ && request != 0 && request == browser_request_;
}
EventDisposition DiscoveryModel::ClassifyEvent(DiscoveryEventKind kind, uint64_t token, uintptr_t request) const {
  // A mailbox failure affects the current run even when an old callback caused
  // it: overflow may have discarded the current registration completion.
  if (kind == DiscoveryEventKind::QueueOverflow || kind == DiscoveryEventKind::CleanupError) return EventDisposition::MailboxFailure;
  if (token != generation_) return EventDisposition::Ignore;
  if (kind == DiscoveryEventKind::Browse && !AcceptBrowse(token, request)) return EventDisposition::Ignore;
  return EventDisposition::Handle;
}
void DiscoveryModel::Fail(uint64_t token, const std::string& message) {
  if (token != generation_) return;
  Stop(); snapshot_.state = "failed"; snapshot_.message = message;
}
void DiscoveryModel::Update(uint64_t token, const std::string& instance, const TxtRecord& record,
                            uint32_t ttl, uint64_t now) {
  if (token != generation_ || snapshot_.state == "stopped" || snapshot_.state == "failed") return;
  if (ttl == 0) { Remove(token, instance); return; }
  auto device = ParseDevice(record, local_id_);
  if (!device) { Remove(token, instance); return; }
  if (!entries_.count(instance) && entries_.size() >= 128) return;
  // A bounded lease prevents hostile records from keeping a peer forever.
  entries_[instance] = {*device, now + std::min<uint32_t>(ttl, 120)};
  Rebuild();
}
void DiscoveryModel::Remove(uint64_t token, const std::string& instance) {
  if (token != generation_) return;
  resolve_requests_.erase(instance); entries_.erase(instance); Rebuild();
}
void DiscoveryModel::ResolveStarted(uint64_t token, const std::string& instance, uintptr_t request) {
  if (token != generation_ || (!resolve_requests_.count(instance) && resolve_requests_.size() >= 128)) return;
  resolve_requests_[instance] = request;
}
void DiscoveryModel::Resolved(uint64_t token, const std::string& instance, uintptr_t request,
                              const TxtRecord& record, uint32_t ttl, uint64_t now) {
  auto pending = resolve_requests_.find(instance);
  if (token != generation_ || pending == resolve_requests_.end() || pending->second != request) return;
  resolve_requests_.erase(pending);
  Update(token, instance, record, ttl, now);
}
void DiscoveryModel::Expire(uint64_t now) {
  for (auto it = entries_.begin(); it != entries_.end();) {
    if (it->second.expires <= now) it = entries_.erase(it); else ++it;
  }
  Rebuild();
}
void DiscoveryModel::Rebuild() {
  std::map<std::string, Device> unique;
  for (const auto& item : entries_) unique[item.second.device.id] = item.second.device;
  snapshot_.devices.clear();
  for (const auto& item : unique) snapshot_.devices.push_back(item.second);
  std::sort(snapshot_.devices.begin(), snapshot_.devices.end(), [](const Device& a, const Device& b) {
    return std::tie(a.name, a.id) < std::tie(b.name, b.id);
  });
}
void DiscoveryModel::Ready() {
  if (registered_ && browsing_) { snapshot_.state = "searching"; snapshot_.message.clear(); }
}
}
