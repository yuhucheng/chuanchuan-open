#include "file_drop_session.h"
#include <flutter/method_result_functions.h>
#include <utility>

namespace share_hub {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
struct FileDropSession::State {
  SourceBridge* source;
  Offer offer;
  Locate locate;
  std::function<void()> error;
  bool listening = false, busy = false, closed = false;
  uint64_t generation = 0;
  List pending;

  void Release(const List& files) {
    if (!source) return;
    for (const auto& file : files) {
      const auto& token = std::get<Map>(file).at(Value("token"));
      std::unique_ptr<SourceBridge::Result> ignore =
          std::make_unique<flutter::MethodResultFunctions<Value>>(nullptr, nullptr, nullptr);
      source->Handle(flutter::MethodCall<Value>("files.release", std::make_unique<Value>(token)), ignore);
    }
  }
  void Finish(bool accepted) {
    if (!accepted) Release(pending);
    pending.clear();
    busy = false;
  }
};
FileDropSession::FileDropSession(SourceBridge& source, Locate locate, Offer offer, std::function<void()> error)
    : state_(std::make_shared<State>()) {
  state_->source = &source; state_->locate = std::move(locate);
  state_->offer = std::move(offer); state_->error = std::move(error);
}
FileDropSession::~FileDropSession() { Close(); }
void FileDropSession::Listen() { if (!state_->closed) state_->listening = true; }
void FileDropSession::Cancel() { state_->listening = false; ++state_->generation; }
bool FileDropSession::ready() const { return !state_->closed && state_->listening && !state_->busy; }
bool FileDropSession::Accept(std::vector<std::wstring> paths, double x, double y) {
  if (!ready()) return false;
  state_->busy = true;
  const auto generation = state_->generation;
  std::weak_ptr<State> weak = state_;
  auto located = std::make_shared<bool>(false);
  state_->locate(x, y, [weak, generation, x, y, located, paths = std::move(paths)](bool accepted) mutable {
    if (*located) return;
    *located = true;
    const auto owner = weak.lock();
    if (!owner || owner->closed) return;
    if (!accepted || !owner->listening || owner->generation != generation) {
      owner->busy = false; return;
    }
    owner->source->AcceptPickedFiles(std::move(paths),
      std::make_unique<flutter::MethodResultFunctions<Value>>(
          [weak, generation, x, y](const Value* value) {
            const auto state = weak.lock();
            if (!state || state->closed) return; // Source store closes on teardown.
            state->pending = std::get<List>(*value);
            if (!state->listening || generation != state->generation) { state->Finish(false); return; }
            auto decided = std::make_shared<bool>(false);
            state->offer(Value(Map{{Value("x"), Value(x)}, {Value("y"), Value(y)},
                                   {Value("files"), Value(state->pending)}}),
                [weak, decided](bool accepted) {
                  if (*decided) return;
                  *decided = true;
                  if (const auto current = weak.lock(); current && !current->closed)
                    current->Finish(accepted);
                });
          },
          [weak, generation](const std::string&, const std::string&, const Value*) {
            if (const auto state = weak.lock(); state && !state->closed) {
              state->busy = false;
              if (state->listening && generation == state->generation) state->error();
            }
          }, nullptr));
  });
  return true;
}
void FileDropSession::Close() {
  if (state_->closed) return;
  Cancel();
  state_->Finish(false);
  state_->closed = true;
  state_->source = nullptr;
  state_->offer = nullptr;
  state_->locate = nullptr;
  state_->error = nullptr;
}
}
