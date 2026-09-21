#ifndef RUNNER_EXIT_TRACE_H_
#define RUNNER_EXIT_TRACE_H_

#include <cstdio>
#include <stdlib.h>
#include <string>

#include <windows.h>

// Exit-path tracing shared by the runner windows. The Dart cleanup chain logs
// its steps to %TEMP%\share_hub_exit.log; this records the native half
// (requestExit result -> kExitApproved -> DestroyWindow -> WM_DESTROY ->
// PostQuitMessage) in %TEMP%\share_hub_native.log, so a quit hang can be
// attributed to an exact native or Dart step. Appends only; called solely on
// the quit path, never per-frame.
inline void TraceAppExit(const char* message) {
  wchar_t* temp = nullptr;
  size_t size = 0;
  if (_wdupenv_s(&temp, &size, L"TEMP") != 0 || !temp) return;
  const std::wstring path = std::wstring(temp) + L"\\share_hub_native.log";
  free(temp);
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"a") == 0 && file) {
    SYSTEMTIME now{};
    GetLocalTime(&now);
    fprintf(file, "%04u-%02u-%02uT%02u:%02u:%02u.%03u %s\n", now.wYear,
            now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
            now.wMilliseconds, message);
    fclose(file);
  }
}

#endif  // RUNNER_EXIT_TRACE_H_
