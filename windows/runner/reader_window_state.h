#ifndef RUNNER_READER_WINDOW_STATE_H_
#define RUNNER_READER_WINDOW_STATE_H_

#include <windows.h>

#include <optional>
#include <string>

// Persists the normal (non-fullscreen) window placement under
// %APPDATA%\com.fanqie\FanqieReader so the app survives ZIP relocations.
// The file format is "left top right bottom maximized" in workspace pixels.
namespace reader_window_state {

std::wstring AppStateDirectory();
std::optional<WINDOWPLACEMENT> Load();
void Save(HWND window, const WINDOWPLACEMENT& normal_placement);

}  // namespace reader_window_state

#endif  // RUNNER_READER_WINDOW_STATE_H_
