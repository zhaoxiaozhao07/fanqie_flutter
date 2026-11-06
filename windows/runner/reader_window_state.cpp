#include "reader_window_state.h"

#include <ShlObj.h>

#include <cstdio>
#include <cstdlib>

namespace reader_window_state {
namespace {

constexpr wchar_t kCompany[] = L"com.fanqie";
constexpr wchar_t kProduct[] = L"FanqieReader";
constexpr wchar_t kStateFile[] = L"window-state.txt";

std::wstring StateFilePath() {
  PWSTR roaming = nullptr;
  std::wstring directory;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                     &roaming)) &&
      roaming != nullptr) {
    directory = std::wstring(roaming) + L"\\" + kCompany + L"\\" + kProduct;
    CreateDirectoryW(directory.c_str(), nullptr);
    CoTaskMemFree(roaming);
    return directory + L"\\" + kStateFile;
  }
  if (roaming != nullptr) CoTaskMemFree(roaming);
  return std::wstring();
}

}  // namespace

std::wstring AppStateDirectory() {
  const std::wstring path = StateFilePath();
  const size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

std::optional<WINDOWPLACEMENT> Load() {
  const std::wstring path = StateFilePath();
  if (path.empty()) return std::nullopt;
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"r") != 0 || file == nullptr) {
    return std::nullopt;
  }
  long left = 0, top = 0, right = 0, bottom = 0, maximized = 0;
  const int fields = fwscanf_s(file, L"%ld %ld %ld %ld %ld", &left, &top,
                               &right, &bottom, &maximized);
  fclose(file);
  if (fields != 5 || right <= left || bottom <= top) {
    return std::nullopt;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  placement.flags = 0;
  placement.showCmd = maximized != 0 ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  placement.rcNormalPosition = RECT{static_cast<LONG>(left),
                                    static_cast<LONG>(top),
                                    static_cast<LONG>(right),
                                    static_cast<LONG>(bottom)};
  return placement;
}

void Save(HWND window, const WINDOWPLACEMENT& normal_placement) {
  const std::wstring path = StateFilePath();
  if (path.empty()) return;
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"w") != 0 || file == nullptr) {
    return;
  }
  const RECT& rect = normal_placement.rcNormalPosition;
  const long maximized =
      (normal_placement.showCmd == SW_SHOWMAXIMIZED || IsZoomed(window)) ? 1
                                                                         : 0;
  // Write plain ASCII numbers: the file must stay readable regardless of the
  // process code page.
  fwprintf_s(file, L"%ld %ld %ld %ld %ld\n", rect.left, rect.top, rect.right,
             rect.bottom, maximized);
  fclose(file);
}

}  // namespace reader_window_state
