#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>

#include "flutter_window.h"
#include "reader_window_state.h"
#include "utils.h"

namespace {

// Native single-instance guard: a second launch asks the first process to
// surface its window and exits instead of racing the same data directory.
constexpr wchar_t kShowExistingEvent[] =
    L"Local\\FanqieReader.SingleInstance.Show";

// Restores the reader window from a thread-pool callback in the first
// instance after the second instance signalled the named event.
VOID CALLBACK OnShowExisting(PVOID context, BOOLEAN timed_out) {
  if (timed_out) return;
  const HWND hwnd = reinterpret_cast<HWND>(context);
  if (hwnd == nullptr || !IsWindow(hwnd)) return;
  ShowWindowAsync(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE show_event =
      ::CreateEventW(nullptr, TRUE, FALSE, kShowExistingEvent);
  if (show_event != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::SetEvent(show_event);
    ::CloseHandle(show_event);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Restore the previous session's placement; first launches get the plan's
  // 1100x760 centered default, both bounded by the monitor work area.
  if (!window.Create(L"番茄Reader", reader_window_state::Load())) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  HANDLE wait_stop = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE wait_registered = nullptr;
  if (show_event != nullptr && wait_stop != nullptr) {
    ::RegisterWaitForSingleObject(
        &wait_registered, show_event, OnShowExisting,
        window.GetHandle(), INFINITE,
        WT_EXECUTEDEFAULT | WT_EXECUTEONLYONCE);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (wait_registered != nullptr) {
    ::UnregisterWaitEx(wait_registered, INVALID_HANDLE_VALUE);
  }
  if (wait_stop != nullptr) {
    ::CloseHandle(wait_stop);
  }
  if (show_event != nullptr) {
    ::CloseHandle(show_event);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
