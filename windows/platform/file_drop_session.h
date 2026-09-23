#ifndef SHARE_HUB_FILE_DROP_SESSION_H_
#define SHARE_HUB_FILE_DROP_SESSION_H_
#include "source_bridge.h"

namespace share_hub {
// Owns one asynchronous OS offer until Dart explicitly takes the capabilities.
// All methods and callbacks run on the platform thread, just like SourceBridge::Pump.
class FileDropSession {
 public:
  using Decision = std::function<void(bool)>;
  using Offer = std::function<void(flutter::EncodableValue, Decision)>;
  using Locate = std::function<void(double, double, Decision)>;
  FileDropSession(SourceBridge& source, Locate locate, Offer offer, std::function<void()> error);
  ~FileDropSession();
  void Listen();
  void Cancel();
  bool ready() const;
  bool Accept(std::vector<std::wstring> paths, double x, double y);
  void Close();
 private:
  struct State;
  std::shared_ptr<State> state_;
};
}
#endif
