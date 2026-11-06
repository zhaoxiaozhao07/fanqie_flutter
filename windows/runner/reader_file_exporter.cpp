#include "reader_file_exporter.h"
#include <thread>
namespace {
// Closes the thread's visible common-dialog window (#32770). IFileDialog has
// no programmatic Cancel on this SDK, but the save dialog owns our message
// loop while shown, so WM_CLOSE dismisses exactly the active panel.
BOOL CALLBACK CloseDialogWindow(HWND hwnd, LPARAM) {
  wchar_t class_name[32]{};
  if (IsWindowVisible(hwnd) && GetClassNameW(hwnd, class_name, 32) > 0 &&
      wcscmp(class_name, L"#32770") == 0) {
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
    return FALSE;  // Only one modal dialog can be active at a time.
  }
  return TRUE;
}
std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), size);
  return out;
}
std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), size,
                      nullptr, nullptr);
  return out;
}
struct CopyError : std::exception {
  enum class Kind { cancelled, invalidInput, failed } kind;
  explicit CopyError(Kind k) : kind(k) {}
};
constexpr size_t kCopyChunk = 64 * 1024;
const wchar_t* DefaultExtensionFor(const std::string& mime) {
  if (mime == "text/plain") return L"txt";
  if (mime == "text/markdown") return L"md";
  if (mime == "application/json") return L"json";
  if (mime == "application/zip") return L"zip";
  if (mime == "application/epub+zip") return L"epub";
  if (mime == "image/png") return L"png";
  if (mime == "image/jpeg") return L"jpg";
  return nullptr;
}
bool IsRegularFile(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA info{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
    return false;
  }
  return (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
         (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}
void ValidateRegularFile(const std::wstring& path) {
  if (!IsRegularFile(path)) {
    throw CopyError(CopyError::Kind::invalidInput);
  }
}
bool EnsureDirectory(const std::wstring& directory) {
  const DWORD attributes = GetFileAttributesW(directory.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES) {
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  }
  return CreateDirectoryW(directory.c_str(), nullptr) != 0;
}
std::wstring UniqueStagingPath(const std::wstring& destination) {
  GUID id{};
  if (CoCreateGuid(&id) != S_OK) {
    throw CopyError(CopyError::Kind::failed);
  }
  wchar_t name[64]{};
  StringFromGUID2(id, name, 64);
  std::wstring suffix;
  for (const wchar_t* c = name; *c != L'\0'; ++c) {
    if (*c != L'{' && *c != L'}') suffix.push_back(*c);
  }
  return destination + L".fanqie-" + suffix + L".tmp";
}
// Streaming copy into a same-directory staging file, then atomic commit:
// ReplaceFileW for an existing destination, MoveFileExW for a new one. A
// failure always leaves the previous file intact.
void CopyAndCommit(const std::wstring& source, const std::wstring& destination,
                   bool allow_overwrite,
                   const std::function<bool()>& cancelled) {
  ValidateRegularFile(source);
  const bool exists =
      GetFileAttributesW(destination.c_str()) != INVALID_FILE_ATTRIBUTES;
  if (exists) {
    if (!allow_overwrite || !IsRegularFile(destination)) {
      throw CopyError(CopyError::Kind::invalidInput);
    }
  }
  if (_wcsicmp(source.c_str(), destination.c_str()) == 0) {
    throw CopyError(CopyError::Kind::invalidInput);
  }
  const std::wstring staging = UniqueStagingPath(destination);
  HANDLE input = CreateFileW(source.c_str(), GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (input == INVALID_HANDLE_VALUE) {
    throw CopyError(CopyError::Kind::invalidInput);
  }
  try {
    HANDLE output =
        CreateFileW(staging.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) {
      throw CopyError(CopyError::Kind::failed);
    }
    try {
      std::vector<uint8_t> buffer(kCopyChunk);
      for (;;) {
        if (cancelled()) throw CopyError(CopyError::Kind::cancelled);
        DWORD read = 0;
        if (!ReadFile(input, buffer.data(), static_cast<DWORD>(buffer.size()),
                      &read, nullptr)) {
          throw CopyError(CopyError::Kind::failed);
        }
        if (read == 0) break;
        DWORD written = 0;
        if (!WriteFile(output, buffer.data(), read, &written, nullptr) ||
            written != read) {
          throw CopyError(CopyError::Kind::failed);
        }
      }
      if (!FlushFileBuffers(output)) {
        throw CopyError(CopyError::Kind::failed);
      }
    } catch (...) {
      CloseHandle(output);
      DeleteFileW(staging.c_str());
      throw;
    }
    CloseHandle(output);
    if (cancelled()) throw CopyError(CopyError::Kind::cancelled);
    if (exists) {
      // ReplaceFileW preserves the destination and its attributes on failure.
      if (!ReplaceFileW(destination.c_str(), staging.c_str(), nullptr,
                        REPLACEFILE_WRITE_THROUGH, nullptr, nullptr)) {
        throw CopyError(CopyError::Kind::failed);
      }
    } else if (!MoveFileExW(staging.c_str(), destination.c_str(),
                            MOVEFILE_WRITE_THROUGH)) {
      throw CopyError(CopyError::Kind::failed);
    }
  } catch (...) {
    CloseHandle(input);
    DeleteFileW(staging.c_str());
    throw;
  }
  CloseHandle(input);
}
// "name (2).txt", "name (3).txt"... never silently overwriting neighbours.
std::wstring UniqueNameIn(const std::wstring& directory,
                          const std::wstring& name) {
  if (GetFileAttributesW((directory + L"\\" + name).c_str()) ==
      INVALID_FILE_ATTRIBUTES) {
    return name;
  }
  const size_t dot = name.find_last_of(L'.');
  const std::wstring ext =
      (dot == std::wstring::npos || dot == 0) ? L"" : name.substr(dot);
  const std::wstring stem = name.substr(0, name.size() - ext.size());
  for (int counter = 2;; ++counter) {
    const std::wstring candidate =
        stem + L" (" + std::to_wstring(counter) + L")" + ext;
    if (GetFileAttributesW((directory + L"\\" + candidate).c_str()) ==
        INVALID_FILE_ATTRIBUTES) {
      return candidate;
    }
  }
}
const flutter::EncodableValue* FindArg(const flutter::EncodableMap& args,
                                       const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}
std::string StringArg(const flutter::EncodableMap& args, const char* key,
                      const std::string& fallback = "") {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<std::string>(*value)) {
    return std::get<std::string>(*value);
  }
  return fallback;
}
}  // namespace
bool ReaderFileExporter::IsCancelled(const std::string& id) {
  std::scoped_lock guard(lock_);
  return cancelled_.count(id) > 0;
}
void ReaderFileExporter::MarkCancelled(const std::string& id) {
  std::scoped_lock guard(lock_);
  cancelled_.insert(id);
}
void ReaderFileExporter::FinishRequest(Request request,
                                       const Outcome& outcome) {
  {
    std::scoped_lock guard(lock_);
    cancelled_.erase(request.id);
  }
  active_id_.clear();
  request.result(outcome);
  PresentNext();
}
void ReaderFileExporter::SaveAs(const flutter::EncodableMap& args,
                                Finish result) {
  Request request;
  request.id = StringArg(args, "id");
  if (request.id.empty()) {
    Outcome outcome;
    outcome.error = "导出请求缺少标识";
    result(outcome);
    return;
  }
  request.source = Utf8ToWide(StringArg(args, "filePath"));
  request.name = Utf8ToWide(StringArg(args, "fileName", "export.txt"));
  request.mime = StringArg(args, "mimeType", "text/plain");
  request.result = std::move(result);
  {
    std::scoped_lock guard(lock_);
    queue_.push_back(std::move(request));
  }
  PresentNext();
}
void ReaderFileExporter::Cancel(const std::string& id) {
  MarkCancelled(id);
  // Dismiss an active modal dialog on our platform thread; a queued request
  // reports cancellation when it is dequeued.
  if (active_id_ == id) {
    EnumThreadWindows(GetCurrentThreadId(), CloseDialogWindow, 0);
  }
}
void ReaderFileExporter::PresentNext() {
  Request request;
  {
    std::scoped_lock guard(lock_);
    if (active_id_.empty() && !queue_.empty()) {
      request = std::move(queue_.front());
      queue_.erase(queue_.begin());
      active_id_ = request.id;
    } else {
      return;
    }
  }
  if (IsCancelled(request.id)) {
    Outcome outcome;
    outcome.cancelled = true;
    FinishRequest(std::move(request), outcome);
    return;
  }
  try {
    ValidateRegularFile(request.source);
    ensure_window_();
    Microsoft::WRL::ComPtr<IFileDialog> dialog;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) {
      throw CopyError(CopyError::Kind::failed);
    }
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST |
                               FOS_OVERWRITEPROMPT | FOS_NOCHANGEDIR);
    dialog->SetTitle(L"保存导出文件");
    dialog->SetFileName(request.name.c_str());
    if (const wchar_t* extension = DefaultExtensionFor(request.mime)) {
      dialog->SetDefaultExtension(extension);
    }
    const HRESULT shown = dialog->Show(nullptr);
    if (FAILED(shown)) {
      Outcome outcome;
      if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        outcome.cancelled = true;
      } else {
        outcome.error = "无法打开保存对话框";
      }
      FinishRequest(std::move(request), outcome);
      return;
    }
    if (IsCancelled(request.id)) {
      Outcome outcome;
      outcome.cancelled = true;
      FinishRequest(std::move(request), outcome);
      return;
    }
    Microsoft::WRL::ComPtr<IShellItem> item;
    wchar_t* raw = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr &&
        SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) &&
        raw != nullptr) {
      const std::wstring destination(raw);
      CoTaskMemFree(raw);
      const std::string id = request.id;
      const std::wstring source = request.source;
      Finish finish = request.result;
      // The dialog slot stays occupied until the copy completes, matching the
      // macOS serialized-panel contract.
      RunCopy(id, source, destination, /*allow_overwrite=*/true,
              std::move(finish));
      return;
    }
    Outcome outcome;
    outcome.error = "系统未返回已保存文件的位置";
    FinishRequest(std::move(request), outcome);
  } catch (const CopyError& error) {
    Outcome outcome;
    outcome.error = error.kind == CopyError::Kind::invalidInput
                        ? "导出文件不可用"
                        : "文件保存失败，请检查权限与存储空间";
    FinishRequest(std::move(request), outcome);
  } catch (...) {
    Outcome outcome;
    outcome.error = "文件保存失败，请检查权限与存储空间";
    FinishRequest(std::move(request), outcome);
  }
}
void ReaderFileExporter::RunCopy(const std::string& id,
                                 const std::wstring& source,
                                 const std::wstring& destination,
                                 bool allow_overwrite, Finish result) {
  std::thread([this, id, source, destination, allow_overwrite,
               result = std::move(result)]() mutable {
    const auto cancelled = [this, &id] { return IsCancelled(id); };
    Outcome outcome;
    try {
      CopyAndCommit(source, destination, allow_overwrite, cancelled);
      outcome.saved = true;
      outcome.path = destination;
    } catch (const CopyError& error) {
      if (error.kind == CopyError::Kind::cancelled) {
        outcome.cancelled = true;
      } else if (error.kind == CopyError::Kind::invalidInput) {
        outcome.error = "导出文件不可用";
      } else {
        outcome.error = "文件保存失败，请检查权限与存储空间";
      }
    } catch (...) {
      outcome.error = "文件保存失败，请检查权限与存储空间";
    }
    post_main_([this, id, outcome = std::move(outcome),
                result = std::move(result)]() mutable {
      {
        std::scoped_lock guard(lock_);
        cancelled_.erase(id);
      }
      result(outcome);
      if (active_id_ == id) {
        active_id_.clear();
        PresentNext();
      }
    });
  }).detach();
}
void ReaderFileExporter::CommitDownload(const flutter::EncodableMap& args,
                                        Finish result) {
  const std::string id = StringArg(args, "id");
  std::wstring source = Utf8ToWide(StringArg(args, "sourcePath"));
  std::wstring directory = Utf8ToWide(StringArg(args, "directory"));
  std::wstring name = Utf8ToWide(StringArg(args, "fileName"));
  std::thread([this, id, source = std::move(source),
               directory = std::move(directory), name = std::move(name),
               result = std::move(result)]() mutable {
    const auto cancelled = [this, &id] { return IsCancelled(id); };
    Outcome outcome;
    try {
      if (cancelled()) throw CopyError(CopyError::Kind::cancelled);
      if (!EnsureDirectory(directory)) {
        outcome.error = "下载目录不可用，请重新选择保存位置";
      } else {
        const std::wstring file_name = UniqueNameIn(directory, name);
        const std::wstring destination = directory + L"\\" + file_name;
        CopyAndCommit(source, destination, /*allow_overwrite=*/false,
                      cancelled);
        outcome.saved = true;
        outcome.path = destination;
      }
    } catch (const CopyError& error) {
      if (error.kind == CopyError::Kind::cancelled) {
        outcome.cancelled = true;
      } else if (error.kind == CopyError::Kind::invalidInput) {
        outcome.error = "下载源文件不可用";
      } else {
        outcome.error = "文件保存失败，请检查权限与存储空间";
      }
    } catch (...) {
      outcome.error = "文件保存失败，请检查权限与存储空间";
    }
    post_main_([this, id, outcome = std::move(outcome),
                result = std::move(result)]() mutable {
      {
        std::scoped_lock guard(lock_);
        cancelled_.erase(id);
      }
      result(outcome);
    });
  }).detach();
}
void ReaderFileExporter::PickDirectory(Finish result) {
  Outcome outcome;
  try {
    ensure_window_();
    Microsoft::WRL::ComPtr<IFileDialog> dialog;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) {
      throw CopyError(CopyError::Kind::failed);
    }
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                               FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
    dialog->SetTitle(L"选择下载保存目录");
    const HRESULT shown = dialog->Show(nullptr);
    if (SUCCEEDED(shown)) {
      Microsoft::WRL::ComPtr<IShellItem> item;
      wchar_t* raw = nullptr;
      if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr &&
          SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) &&
          raw != nullptr) {
        outcome.saved = true;
        outcome.path = raw;
        CoTaskMemFree(raw);
      } else {
        outcome.error = "系统未返回所选目录";
      }
    } else if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      outcome.cancelled = true;
    } else {
      outcome.error = "无法打开目录选择对话框";
    }
  } catch (const CopyError&) {
    outcome.error = "无法打开目录选择对话框";
  } catch (...) {
    outcome.error = "无法打开目录选择对话框";
  }
  result(outcome);
}
// WideToUtf8 is used by the bridge when replying with committed paths.
std::string ReaderExporterWideToUtf8(const std::wstring& value) {
  return WideToUtf8(value);
}
