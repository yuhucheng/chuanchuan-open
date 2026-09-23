#include "control_text_input.h"

#include <windows.h>

#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {
std::vector<wchar_t> received;
unsigned packet_keydowns = 0;
unsigned physical_keydowns = 0;
unsigned ascii_keydowns = 0;
unsigned f24_keydowns = 0;
unsigned system_packet_keydowns = 0;
unsigned system_chars = 0;
unsigned injected_hook_packets = 0;
unsigned injected_hook_physical = 0;
HWND probe_window = nullptr;
unsigned hook_target_foreground = 0;
unsigned hook_other_foreground = 0;
unsigned hook_target_focus = 0;
unsigned hook_next_consumed = 0;

LRESULT CALLBACK KeyboardHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION &&
      (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
    const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    if ((key->flags & LLKHF_INJECTED) != 0) {
      const HWND foreground = GetForegroundWindow();
      if (foreground == probe_window) {
        ++hook_target_foreground;
        GUITHREADINFO info{};
        info.cbSize = sizeof(info);
        const DWORD thread = GetWindowThreadProcessId(foreground, nullptr);
        if (thread && GetGUIThreadInfo(thread, &info) &&
            info.hwndFocus == probe_window) {
          ++hook_target_focus;
        }
      } else {
        ++hook_other_foreground;
      }
      if (key->vkCode == VK_PACKET) ++injected_hook_packets;
      if (key->vkCode == VK_F24) ++injected_hook_physical;
    }
  }
  const LRESULT next = CallNextHookEx(nullptr, code, message, data);
  if (code == HC_ACTION &&
      (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) &&
      (reinterpret_cast<const KBDLLHOOKSTRUCT*>(data)->flags & LLKHF_INJECTED) != 0 &&
      next != 0) {
    ++hook_next_consumed;
  }
  return next;
}

std::string ObjectName(HANDLE object) {
  if (!object) return "unavailable";
  wchar_t name[256]{};
  DWORD required = 0;
  if (!GetUserObjectInformationW(object, UOI_NAME, name, sizeof(name),
                                 &required)) {
    return "error:" + std::to_string(GetLastError());
  }
  const std::wstring value(name);
  std::string ascii;
  for (const wchar_t unit : value) {
    ascii.push_back(unit <= 0x7f ? static_cast<char>(unit) : '?');
  }
  return ascii;
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (message == WM_CHAR) {
    received.push_back(static_cast<wchar_t>(wparam));
    return 0;
  }
  if (message == WM_SYSCHAR) ++system_chars;
  if (message == WM_KEYDOWN && wparam == VK_PACKET) ++packet_keydowns;
  if (message == WM_KEYDOWN && wparam != VK_PACKET) ++physical_keydowns;
  if (message == WM_KEYDOWN && wparam == 'A') ++ascii_keydowns;
  if (message == WM_KEYDOWN && wparam == VK_F24) ++f24_keydowns;
  if (message == WM_SYSKEYDOWN && wparam == VK_PACKET) {
    ++system_packet_keydowns;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void Pump() {
  MSG message{};
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}
}  // namespace

int main(int argc, char** argv) {
  const bool worker_mode = argc == 2 && std::string(argv[1]) == "--worker";
  const bool no_hook_mode = argc == 2 && std::string(argv[1]) == "--no-hook";
  DWORD process_session = 0;
  const bool session_known = ProcessIdToSessionId(
      GetCurrentProcessId(), &process_session) != 0;
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW klass{};
  klass.hInstance = instance;
  klass.lpfnWndProc = WindowProc;
  klass.lpszClassName = L"ShareHubControlTextProbe";
  if (!RegisterClassW(&klass)) return 1;
  const HWND window = CreateWindowExW(
      0, klass.lpszClassName, L"Share Hub input verification",
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 420, 180,
      nullptr, nullptr, instance, nullptr);
  if (!window) return 1;
  probe_window = window;
  const HWND prior_foreground = GetForegroundWindow();
  ShowWindow(window, SW_SHOW);
  UpdateWindow(window);
  const DWORD current_thread = GetCurrentThreadId();
  const std::string thread_desktop = ObjectName(GetThreadDesktop(current_thread));
  const HDESK input_desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  const std::string active_desktop = ObjectName(input_desktop);
  if (input_desktop) CloseDesktop(input_desktop);
  const std::string window_station = ObjectName(GetProcessWindowStation());
  const DWORD console_session = WTSGetActiveConsoleSessionId();
  const DWORD foreground_thread = prior_foreground
      ? GetWindowThreadProcessId(prior_foreground, nullptr) : 0;
  const bool attached = foreground_thread && foreground_thread != current_thread &&
      AttachThreadInput(current_thread, foreground_thread, TRUE) != 0;
  const DWORD attach_error = attached ? ERROR_SUCCESS : GetLastError();
  BringWindowToTop(window);
  const bool foreground_requested = SetForegroundWindow(window) != 0;
  SetActiveWindow(window);
  SetFocus(window);
  if (attached) AttachThreadInput(current_thread, foreground_thread, FALSE);
  const auto focus_deadline = GetTickCount64() + 1500;
  while (GetForegroundWindow() != window && GetTickCount64() < focus_deadline) {
    Pump();
    Sleep(10);
  }
  if (GetForegroundWindow() != window) {
    const HWND actual_foreground = GetForegroundWindow();
    DWORD foreground_process = 0;
    if (actual_foreground) {
      GetWindowThreadProcessId(actual_foreground, &foreground_process);
    }
    DWORD foreground_session = 0;
    const bool foreground_session_known = foreground_process &&
        ProcessIdToSessionId(foreground_process, &foreground_session) != 0;
    DestroyWindow(window);
    std::cout << "SKIPPED: dedicated test window could not obtain focus; "
              << "requested=" << foreground_requested
              << " hadForeground=" << (prior_foreground != nullptr)
              << " actualForeground=" << (actual_foreground != nullptr)
              << " attached=" << attached
              << " attachError=" << attach_error
              << " sessionKnown=" << session_known
              << " session=" << process_session
              << " consoleSession=" << console_session
              << " station=" << window_station
              << " threadDesktop=" << thread_desktop
              << " inputDesktop=" << active_desktop
              << " foregroundSessionKnown=" << foreground_session_known
              << " foregroundSession=" << foreground_session << '\n';
    return 2;
  }

  // Verify this window's message queue independently of OS input injection.
  received.clear();
  const bool posted = PostMessageW(window, WM_CHAR, L'Z', 0) != 0;
  Pump();
  const bool pump_worked = posted && received.size() == 1 &&
      received.front() == L'Z';
  if (!pump_worked) {
    DestroyWindow(window);
    std::cout << "FAILED: dedicated window message pump is unavailable; "
              << "sessionKnown=" << session_known
              << " session=" << process_session << '\n';
    return 1;
  }
  received.clear();
  const bool posted_key = PostMessageW(window, WM_KEYDOWN, 'B', 1) != 0;
  Pump();
  const bool translation_worked = posted_key && !received.empty();
  GUITHREADINFO gui{};
  gui.cbSize = sizeof(gui);
  const bool gui_known = GetGUIThreadInfo(current_thread, &gui) != 0;
  const bool gui_focus = gui_known && gui.hwndFocus == window;
  const bool gui_active = gui_known && gui.hwndActive == window;

  // A leading BOM, Chinese, LF, ASCII, and a supplementary scalar. The
  // fixture is static and never contains private user input.
  const HHOOK keyboard_hook = no_hook_mode ? nullptr : SetWindowsHookExW(
      WH_KEYBOARD_LL, KeyboardHook, instance, 0);
  const DWORD hook_error = keyboard_hook || no_hook_mode
      ? ERROR_SUCCESS : GetLastError();
  const std::wstring expected = L"\ufeff\u4e2d\u6587\nA\U0001F600";
  received.clear();
  LASTINPUTINFO before_input{};
  before_input.cbSize = sizeof(before_input);
  const bool before_input_known = GetLastInputInfo(&before_input) != 0;
  const DWORD before_tick = GetTickCount();
  const bool alt_held = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  const bool ctrl_held = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool shift_held = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  share_hub::ControlInjectionResult status;
  if (worker_mode) {
    std::atomic<bool> done{false};
    std::thread sender([&] {
      share_hub::ControlTextInput input;
      status = input.Submit(expected);
      done.store(true);
    });
    while (!done.load()) { Pump(); Sleep(1); }
    sender.join();
  } else {
    share_hub::ControlTextInput input;
    status = input.Submit(expected);
  }
  const bool still_foreground = GetForegroundWindow() == window;
  const bool still_focused = GetFocus() == window;
  const auto deadline = GetTickCount64() + 2000;
  while (received.size() < expected.size() && GetTickCount64() < deadline) {
    Pump();
    Sleep(5);
  }
  const bool matched = received.size() == expected.size() &&
      std::wstring(received.begin(), received.end()) == expected;
  const unsigned original_chars = static_cast<unsigned>(received.size());
  bool ascii_unicode_accepted = false;
  unsigned ascii_unicode_chars = 0;
  if (!matched && GetForegroundWindow() == window) {
    received.clear();
    share_hub::ControlTextInput ascii_input;
    ascii_unicode_accepted =
        ascii_input.Submit(L"A") == share_hub::ControlInjectionResult::accepted;
    const auto ascii_deadline = GetTickCount64() + 300;
    while (GetTickCount64() < ascii_deadline) { Pump(); Sleep(5); }
    ascii_unicode_chars = static_cast<unsigned>(received.size());
  }
  UINT diagnostic_inserted = 0;
  UINT physical_ascii_inserted = 0;
  unsigned physical_ascii_chars = 0;
  LASTINPUTINFO last_input{};
  last_input.cbSize = sizeof(last_input);
  const bool last_input_known = GetLastInputInfo(&last_input) != 0;
  const DWORD after_tick = GetTickCount();
  if (!matched && GetForegroundWindow() == window) {
    INPUT diagnostic[2]{};
    diagnostic[0].type = INPUT_KEYBOARD;
    diagnostic[0].ki.wVk = VK_F24;
    diagnostic[1] = diagnostic[0];
    diagnostic[1].ki.dwFlags = KEYEVENTF_KEYUP;
    diagnostic_inserted = SendInput(2, diagnostic, sizeof(INPUT));
    const auto diagnostic_deadline = GetTickCount64() + 300;
    while (GetTickCount64() < diagnostic_deadline) { Pump(); Sleep(5); }
    received.clear();
    INPUT ascii_physical[2]{};
    ascii_physical[0].type = INPUT_KEYBOARD;
    ascii_physical[0].ki.wVk = 'A';
    ascii_physical[1] = ascii_physical[0];
    ascii_physical[1].ki.dwFlags = KEYEVENTF_KEYUP;
    physical_ascii_inserted = SendInput(2, ascii_physical, sizeof(INPUT));
    const auto ascii_physical_deadline = GetTickCount64() + 300;
    while (GetTickCount64() < ascii_physical_deadline) { Pump(); Sleep(5); }
    physical_ascii_chars = static_cast<unsigned>(received.size());
  }
  if (keyboard_hook) UnhookWindowsHookEx(keyboard_hook);
  DestroyWindow(window);
  if (prior_foreground && IsWindow(prior_foreground)) {
    SetForegroundWindow(prior_foreground);
  }
  if (status != share_hub::ControlInjectionResult::accepted) {
    std::cout << "FAILED: SendInput did not accept all Unicode events\n";
    return 1;
  }
  if (!matched) {
    std::cout << "FAILED: dedicated window did not receive exact WM_CHAR units; "
              << original_chars << " of " << expected.size() << " received, "
              << packet_keydowns << " packet keydowns; foreground="
              << still_foreground << " focus=" << still_focused
              << " diagnosticInserted=" << diagnostic_inserted
              << " physicalAsciiInserted=" << physical_ascii_inserted
              << " physicalAsciiChars=" << physical_ascii_chars
              << " physicalKeydowns=" << physical_keydowns
              << " asciiKeydowns=" << ascii_keydowns
              << " f24Keydowns=" << f24_keydowns
              << " pumpWorked=" << pump_worked
              << " translationWorked=" << translation_worked
              << " guiKnown=" << gui_known
              << " guiFocus=" << gui_focus
              << " guiActive=" << gui_active
              << " sessionKnown=" << session_known
              << " session=" << process_session
              << " consoleSession=" << console_session
              << " station=" << window_station
              << " threadDesktop=" << thread_desktop
              << " inputDesktop=" << active_desktop
              << " beforeInputKnown=" << before_input_known
              << " beforeInputTick=" << before_input.dwTime
              << " beforeTick=" << before_tick
              << " afterTick=" << after_tick
              << " lastInputKnown=" << last_input_known
              << " lastInputTick=" << last_input.dwTime
              << " keyboardHook=" << (keyboard_hook != nullptr)
              << " hookError=" << hook_error
              << " hookPackets=" << injected_hook_packets
              << " hookF24=" << injected_hook_physical
              << " hookTargetForeground=" << hook_target_foreground
              << " hookTargetFocus=" << hook_target_focus
              << " hookOtherForeground=" << hook_other_foreground
              << " hookNextConsumed=" << hook_next_consumed
              << " workerMode=" << worker_mode
              << " noHookMode=" << no_hook_mode
              << " systemPackets=" << system_packet_keydowns
              << " systemChars=" << system_chars
              << " asciiUnicodeAccepted=" << ascii_unicode_accepted
              << " asciiUnicodeChars=" << ascii_unicode_chars
              << " altHeld=" << alt_held
              << " ctrlHeld=" << ctrl_held
              << " shiftHeld=" << shift_held << '\n';
    return 1;
  }
  std::cout << "PASSED: dedicated window received exact WM_CHAR units ("
            << received.size() << ")\n";
  return 0;
}
