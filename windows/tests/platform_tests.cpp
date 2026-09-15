#include "discovery_model.h"
#include <iostream>
#include <string>
using namespace share_hub;
namespace {
int failures = 0;
int checks = 0;
void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) { std::cerr << "FAIL: " << label << '\n'; ++failures; }
}
const std::string local = "aaaaaaaa-1111-2222-3333-444444444444";
const std::string remote = "bbbbbbbb-1111-2222-3333-444444444444";
TxtRecord Record() { return {{"v", "1"}, {"id", remote}, {"name", u8"书房 Mac"}, {"platform", "macos"}}; }
void NamesAndRecords() {
  Check(NormalizeName(u8" \t书房 Windows\r\n") == u8"书房 Windows", "trim UTF-8 name");
  Check(NormalizeName(std::string(128, 'a')).has_value(), "128 bytes allowed");
  for (const auto& name : {std::string("  "), std::string("a\nb"), std::string(129, 'a'),
                          std::string("\xC0\xAF"), std::string("\xED\xA0\x80"),
                          std::string("a\0b", 3), std::string(u8"a\u202Eb")}) {
    Check(!NormalizeName(name), "invalid or control name rejected");
  }
  std::string multibyte;
  for (int i = 0; i < 43; ++i) multibyte += u8"中";
  Check(!NormalizeName(multibyte), "name limit uses UTF-8 bytes");
  Check(!NormalizeName(u8"a\u0600b"), "Arabic format control rejected like Mac");
  Check(!NormalizeName(u8"a\U000110BDb"), "supplementary format control rejected like Mac");
  Check(NormalizeUuid("AAAAAAAA-1111-2222-3333-444444444444") == local, "UUID canonicalized");
  Check(!NormalizeUuid("bad"), "invalid UUID rejected");
  auto parsed = ParseDevice(Record(), local);
  Check(parsed && parsed->id == remote && parsed->platform == "macos", "Mac TXT accepted");
  Check(!ParseDevice(Record(), "BBBBBBBB-1111-2222-3333-444444444444"), "self excluded case-insensitively");
  for (const auto& item : TxtRecord{{"v", "2"}, {"id", "bad"}, {"name", "\n"}, {"platform", "unknown"}}) {
    auto changed = Record(); changed[item.first] = item.second;
    Check(!ParseDevice(changed, local), "malformed TXT excluded");
  }
  auto missing = Record(); missing.erase("v");
  Check(!ParseDevice(missing, local), "missing version excluded");
}
void Lifecycle() {
  DiscoveryModel model;
  auto first = model.Start(local);
  Check(model.snapshot().state == "starting", "start observable");
  model.Registered(first);
  Check(model.snapshot().state == "starting", "browse readiness required");
  model.Browsing(first);
  Check(model.snapshot().state == "searching", "both sides ready");
  model.Update(first, "one", Record(), 2, 100);
  model.Update(first, "duplicate", Record(), 2, 100);
  Check(model.snapshot().devices.size() == 1, "deduplicate UUID across interfaces");
  model.Remove(first, "duplicate");
  Check(model.snapshot().devices.size() == 1, "one interface removal preserves other");
  model.Expire(102);
  Check(model.snapshot().devices.empty(), "TTL expiry removes offline peer");
  model.Update(first, "one", Record(), 10, 102);
  model.Update(first, "one", Record(), 0, 102);
  Check(model.snapshot().devices.empty(), "TTL zero removes peer");
  model.Update(first, "one", Record(), 10, 102);
  model.Stop(); model.Stop();
  Check(model.snapshot().state == "stopped" && model.snapshot().devices.empty(), "stop idempotent and clears");
  model.Update(first, "late", Record(), 50, 102);
  model.Fail(first, "late failure");
  Check(model.snapshot().state == "stopped" && model.snapshot().devices.empty(), "late callbacks ignored");
  auto second = model.Start(local);
  Check(second != first, "restart uses new generation");
  model.Fail(second, "network unavailable");
  model.Registered(second); model.Browsing(second);
  Check(model.snapshot().state == "failed" && model.snapshot().message == "network unavailable", "failure terminal until restart");
}
void ResolveInvalidation() {
  DiscoveryModel model;
  const auto token = model.Start(local);
  model.ResolveStarted(token, "one", 1);
  model.Remove(token, "one");  // TTL=0 arrives before the async resolve callback.
  model.Resolved(token, "one", 1, Record(), 120, 100);
  Check(model.snapshot().devices.empty(), "goodbye invalidates pending resolve");
  model.ResolveStarted(token, "one", 2);
  model.Resolved(token, "one", 1, Record(), 120, 100);
  Check(model.snapshot().devices.empty(), "superseded resolve cannot reintroduce peer");
  model.Resolved(token, "one", 2, Record(), 120, 100);
  Check(model.snapshot().devices.size() == 1, "fresh matching resolve still accepted");
}
void BrowseInvalidation() {
  DiscoveryModel model;
  const auto token = model.Start(local);
  model.Browsing(token, 1);
  Check(model.AcceptBrowse(token, 1), "active browser accepted");
  model.Browsing(token, 2);  // Periodic refresh keeps the discovery generation.
  Check(!model.AcceptBrowse(token, 1), "replaced browser cannot report results or failure");
  Check(model.AcceptBrowse(token, 2), "replacement browser accepted");
  model.Stop();
  Check(!model.AcceptBrowse(token, 2), "stop invalidates browser operation");
}
void MailboxFailureAcrossGenerations() {
  DiscoveryModel model;
  auto old = model.Start(local);
  model.Start(local);
  Check(model.ClassifyEvent(DiscoveryEventKind::QueueOverflow, old, 1) == EventDisposition::MailboxFailure,
        "old callback overflow cannot hide loss of current startup event");
  Check(model.ClassifyEvent(DiscoveryEventKind::CleanupError, old, 1) == EventDisposition::MailboxFailure,
        "cleanup failure survives generation change and queue overflow");
  Check(model.ClassifyEvent(DiscoveryEventKind::Registered, old, 1) == EventDisposition::Ignore,
        "ordinary late completion remains ignored");
}
}
int main() {
  NamesAndRecords(); Lifecycle(); ResolveInvalidation(); BrowseInvalidation(); MailboxFailureAcrossGenerations();
  std::cout << "native model checks=" << checks << " failures=" << failures << '\n';
  return failures ? 1 : 0;
}
