#include "control_pointer_input.h"
#include "control_text_input.h"

#include <windows.h>

#include <cmath>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

// Manual, interactive acceptance probe. It injects only while this owned
// window has foreground focus; the executable is intentionally not in CTest.

namespace {

HWND target = nullptr;
unsigned moves = 0;
unsigned button_down = 0;
unsigned button_up = 0;
unsigned wheel = 0;
unsigned key_down = 0;
unsigned key_up = 0;
std::vector<wchar_t> characters;

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (window == target) {
    switch (message) {
      case WM_MOUSEMOVE: ++moves; break;
      case WM_LBUTTONDOWN: ++button_down; break;
      case WM_LBUTTONUP: ++button_up; break;
      case WM_MOUSEWHEEL:
        if (GET_WHEEL_DELTA_WPARAM(wparam) == WHEEL_DELTA) ++wheel;
        break;
      case WM_KEYDOWN:
        if (wparam == 'A') ++key_down;
        break;
      case WM_KEYUP:
        if (wparam == 'A') ++key_up;
        break;
      case WM_CHAR: characters.push_back(static_cast<wchar_t>(wparam)); break;
      default: break;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void PumpFor(DWORD milliseconds) {
  const ULONGLONG until = GetTickCount64() + milliseconds;
  MSG message{};
  do {
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Sleep(5);
  } while (GetTickCount64() < until);
}

bool Accepted(share_hub::ControlInjectionResult result) {
  return result == share_hub::ControlInjectionResult::accepted;
}

}  // namespace

int main() {
  if (!SetProcessDpiAwarenessContext(
          DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
    std::cout << "SKIPPED: per-monitor DPI awareness unavailable\n";
    return 2;
  }
  std::optional<share_hub::ControlScreenGeometry> source;
  for (DWORD index = 0; index < 256; ++index) {
    source = share_hub::ResolveControlScreenGeometry(std::to_string(index));
    if (source) break;
  }
  if (!source || source->width < 500 || source->height < 400) {
    std::cout << "SKIPPED: no usable attached screen\n";
    return 2;
  }

  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW klass{};
  klass.hInstance = instance;
  klass.lpfnWndProc = WindowProc;
  klass.lpszClassName = L"ShareHubControlInputLiveProbe";
  if (!RegisterClassW(&klass)) return 1;
  const int left = source->left + static_cast<int>(source->width / 2) - 220;
  const int top = source->top + static_cast<int>(source->height / 2) - 150;
  const HWND window = CreateWindowExW(
      WS_EX_TOPMOST, klass.lpszClassName, L"Share Hub input verification",
      WS_OVERLAPPEDWINDOW, left, top, 440, 300, nullptr, nullptr, instance,
      nullptr);
  if (!window) return 1;
  target = window;
  const HWND prior = GetForegroundWindow();
  ShowWindow(window, SW_SHOW);
  UpdateWindow(window);
  BringWindowToTop(window);
  SetForegroundWindow(window);
  SetActiveWindow(window);
  SetFocus(window);
  PumpFor(500);
  if (GetForegroundWindow() != window || GetFocus() != window) {
    DestroyWindow(window);
    std::cout << "SKIPPED: dedicated window did not obtain foreground focus\n";
    return 2;
  }

  RECT bounds{};
  if (!GetClientRect(window, &bounds)) {
    DestroyWindow(window);
    return 1;
  }
  POINT center{(bounds.right - bounds.left) / 2,
               (bounds.bottom - bounds.top) / 2};
  ClientToScreen(window, &center);
  const double x = static_cast<double>(center.x - source->left) /
                   static_cast<double>(source->width - 1);
  const double y = static_cast<double>(center.y - source->top) /
                   static_cast<double>(source->height - 1);
  share_hub::ControlPointerInput pointer(*source);
  share_hub::ControlTextInput text;
  const auto target_ready = [&] {
    return GetForegroundWindow() == window && GetFocus() == window;
  };

  moves = 0;
  const bool moved = target_ready() && Accepted(pointer.Move(x, y));
  PumpFor(200);
  POINT cursor{};
  GetCursorPos(&cursor);
  const bool cursor_matched =
      std::abs(cursor.x - center.x) <= 2 &&
      std::abs(cursor.y - center.y) <= 2 && moves > 0;

  const bool clicked_down = target_ready() && Accepted(pointer.Button(
      x, y, share_hub::ControlPointerButton::primary, true));
  PumpFor(100);
  const bool clicked_up = Accepted(pointer.ReleaseButton(
      share_hub::ControlPointerButton::primary));
  PumpFor(100);
  const bool clicked = clicked_down && clicked_up &&
                       button_down > 0 && button_up > 0;

  const bool scrolled = target_ready() &&
                        Accepted(pointer.Wheel(x, y, 0, 120));
  PumpFor(150);
  const bool wheel_received = scrolled && wheel > 0;

  const bool pressed = target_ready() && Accepted(pointer.Key(0x04, true));
  PumpFor(100);
  const bool released = Accepted(pointer.ReleaseKey(0x04));
  PumpFor(100);
  const bool key_received = pressed && released && key_down > 0 && key_up > 0;

  characters.clear();
  const std::wstring expected = L"\u4e2d\u6587\nA";
  const bool submitted = target_ready() && Accepted(text.Submit(expected));
  PumpFor(300);
  const bool text_received = submitted &&
      std::wstring(characters.begin(), characters.end()) == expected;
  text.ReleasePending();
  pointer.ReleaseKey(0x04);
  pointer.ReleaseButton(share_hub::ControlPointerButton::primary);

  const bool foreground_retained = GetForegroundWindow() == window;
  const UINT dpi = GetDpiForWindow(window);
  DestroyWindow(window);
  target = nullptr;
  if (prior && IsWindow(prior)) SetForegroundWindow(prior);

  std::cout << "screen=" << source->source_index << " origin=" << source->left
            << ',' << source->top << " size=" << source->width << 'x'
            << source->height << " rotation=" << source->rotation
            << " dpi=" << dpi << " move=" << (moved && cursor_matched)
            << " button=" << clicked << " wheel=" << wheel_received
            << " key=" << key_received << " text=" << text_received
            << " foreground=" << foreground_retained
            << " moveAccepted=" << moved << " cursor=" << cursor.x << ','
            << cursor.y << " expected=" << center.x << ',' << center.y
            << " messages=" << moves << ',' << button_down << ','
            << button_up << ',' << wheel << ',' << key_down << ','
            << key_up << ',' << characters.size()
            << " injectAccepted=" << clicked_down << ',' << clicked_up
            << ',' << scrolled << ',' << pressed << ',' << released
            << ',' << submitted << '\n';
  return moved && cursor_matched && clicked && wheel_received &&
                 key_received && text_received && foreground_retained
      ? 0 : 1;
}
