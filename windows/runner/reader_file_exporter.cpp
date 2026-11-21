#include "reader_file_exporter.h"
#include <thread>
namespace {
class DialogApartment {
 public:
  DialogApartment()
      : status_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED |
                                           COINIT_DISABLE_OLE1DDE)) {}
  ~DialogApartment() {
    if (SUCCEEDED(status_)) CoUninitialize();
  }
  HRESULT status() const { return status_; }

 private:
  HRESULT status_;
};

// The thread timer and dialog pointer belong exclusively to the dialog STA.
// Use a thread timer (no unrelated HWND) that Show's modal loop dispatches.
// A latched cancellation is retried until Show returns: unlike a single scan this
// also covers cancellation while the shell is still constructing the panel.
// No COM pointer or queue state is shared with the platform thread.
class DialogCancellation {
 public:
  DialogCancellation(IFileDialog* dialog, std::function<bool()> cancelled)
      : dialog_(dialog),
        cancelled_(std::move(cancelled)),
        previous_(current_) {
    current_ = this;
    timer_ = SetTimer(nullptr, 0, 25, TimerProc);
  }
  ~DialogCancellation() {
    if (timer_ != 0) KillTimer(nullptr, timer_);
    // KillTimer does not remove already queued WM_TIMER messages. Clear/restore
    // TLS before releasing the dialog: a late callback checks both context and
    // timer ID. Each worker has one panel and exits after its completion post.
    current_ = previous_;
  }
  DialogCancellation(const DialogCancellation&) = delete;
  DialogCancellation& operator=(const DialogCancellation&) = delete;
  bool ready() const { return timer_ != 0; }

 private:
  static void CALLBACK TimerProc(HWND, UINT, UINT_PTR timer, DWORD) {
    auto* context = current_;
    if (context != nullptr && context->timer_ == timer &&
        context->cancelled_()) {
      // IFileDialog::Close must be called on its own COM apartment.
      context->dialog_->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
      // Some shell versions acknowledge Close without unwinding Show when
      // called from a timer callback. Target only this COM dialog's own HWND,
      // retrying while it is being created; never enumerate arbitrary windows.
      Microsoft::WRL::ComPtr<IOleWindow> window;
      HWND hwnd = nullptr;
      if (SUCCEEDED(context->dialog_->QueryInterface(IID_PPV_ARGS(&window))) &&
          SUCCEEDED(window->GetWindow(&hwnd)) && hwnd != nullptr &&
          GetWindowThreadProcessId(hwnd, nullptr) == GetCurrentThreadId()) {
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
      }
    }
  }

  static thread_local DialogCancellation* current_;
  IFileDialog* const dialog_;
  const std::function<bool()> cancelled_;
  DialogCancellation* const previous_;
  UINT_PTR timer_ = 0;
};
thread_local DialogCancellation* DialogCancellation::current_ = nullptr;
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
bool IsReservedDeviceName(const std::wstring& stem) {
  static const wchar_t* kDevices[] = {
      L"CON",  L"PRN",  L"AUX",  L"NUL",  L"COM1", L"COM2", L"COM3",
      L"COM4", L"COM5", L"COM6", L"COM7", L"COM8", L"COM9", L"LPT1",
      L"LPT2", L"LPT3", L"LPT4", L"LPT5", L"LPT6", L"LPT7", L"LPT8",
      L"LPT9"};
  for (const wchar_t* device : kDevices) {
    if (_wcsicmp(stem.c_str(), device) == 0) return true;
  }
  return false;
}
}  // namespace

std::wstring ReaderFileExporter::SanitizeFileName(const std::wstring& name) {
  std::wstring cleaned;
  cleaned.reserve(name.size());
  for (const wchar_t c : name) {
    const bool forbidden = c < 0x20 || c == L'<' || c == L'>' || c == L':' ||
                           c == L'"' || c == L'/' || c == L'\\' ||
                           c == L'|' || c == L'?' || c == L'*';
    // Colons would create NTFS alternate data streams; keep one readable
    // replacement instead of silently dropping characters.
    cleaned.push_back(forbidden ? L'_' : c);
  }
  while (!cleaned.empty() &&
         (cleaned.back() == L'.' || cleaned.back() == L' ')) {
    cleaned.pop_back();
  }
  const size_t dot = cleaned.find_first_of(L'.');
  const std::wstring stem =
      cleaned.substr(0, dot == std::wstring::npos ? cleaned.size() : dot);
  if (stem.empty() || IsReservedDeviceName(stem)) {
    cleaned.insert(cleaned.begin(), L'_');
  }
  if (cleaned.empty()) cleaned = L"export.txt";
  return cleaned;
}
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
  request.name = SanitizeFileName(
      Utf8ToWide(StringArg(args, "fileName", "export.txt")));
  request.mime = StringArg(args, "mimeType", "text/plain");
  request.result = std::move(result);
  queue_.push_back(std::move(request));
  PresentNext();
}
void ReaderFileExporter::Cancel(const std::string& id) {
  // This channel handler never waits for Show. The dialog STA polls this
  // thread-safe latch, and copies continue using the same cancellation checks.
  MarkCancelled(id);
}
void ReaderFileExporter::PresentNext() {
  Request request;
  // Request queue and active slot are platform-thread-only, including the
  // completion that starts copying or presents the next serialized panel.
  if (!active_id_.empty() || queue_.empty()) return;
  request = std::move(queue_.front());
  queue_.erase(queue_.begin());
  active_id_ = request.id;
  if (IsCancelled(request.id)) {
    Outcome outcome;
    outcome.cancelled = true;
    FinishRequest(std::move(request), outcome);
    return;
  }
  try {
    ValidateRegularFile(request.source);
    ensure_window_();
  } catch (const CopyError& error) {
    Outcome outcome;
    outcome.error = error.kind == CopyError::Kind::invalidInput
                        ? "导出文件不可用"
                        : "文件保存失败，请检查权限与存储空间";
    FinishRequest(std::move(request), outcome);
    return;
  } catch (...) {
    Outcome outcome;
    outcome.error = "文件保存失败，请检查权限与存储空间";
    FinishRequest(std::move(request), outcome);
    return;
  }
  RunDialog(std::move(request));
}
void ReaderFileExporter::RunDialog(Request request) {
  auto self = shared_from_this();
  // Keep the callback available even if constructing the worker fails.
  auto pending = std::make_shared<Request>(std::move(request));
  try {
    std::thread([self, pending] {
      Outcome outcome;
      {
        // Destruction order: cancellation timer/TLS scope, dialog/items, then
        // CoUninitialize, all on this STA before posting any main completion.
        DialogApartment apartment;
        try {
          if (self->IsCancelled(pending->id)) {
            outcome.cancelled = true;
          } else {
            if (FAILED(apartment.status())) {
              throw CopyError(CopyError::Kind::failed);
            }
            Microsoft::WRL::ComPtr<IFileDialog> dialog;
            HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                          CLSCTX_INPROC_SERVER,
                                          IID_PPV_ARGS(&dialog));
            if (FAILED(hr)) throw CopyError(CopyError::Kind::failed);
            DWORD options = 0;
            dialog->GetOptions(&options);
            dialog->SetOptions(options | FOS_FORCEFILESYSTEM |
                                       FOS_PATHMUSTEXIST | FOS_OVERWRITEPROMPT |
                                       FOS_NOCHANGEDIR);
            dialog->SetTitle(L"保存导出文件");
            dialog->SetFileName(pending->name.c_str());
            if (const wchar_t* extension = DefaultExtensionFor(pending->mime)) {
              dialog->SetDefaultExtension(extension);
            }
            DialogCancellation cancellation(
                dialog.Get(), [self, pending] {
                  return self->IsCancelled(pending->id);
                });
            if (!cancellation.ready()) {
              throw CopyError(CopyError::Kind::failed);
            }
            // Recheck after COM/panel setup. Cancellation after this check is
            // observed by the STA timer inside Show, even before a HWND exists.
            const HRESULT shown =
                self->IsCancelled(pending->id)
                    ? HRESULT_FROM_WIN32(ERROR_CANCELLED)
                    : dialog->Show(nullptr);
            if (self->IsCancelled(pending->id) ||
                shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
              outcome.cancelled = true;
            } else if (FAILED(shown)) {
              outcome.error = "无法打开保存对话框";
            } else {
              Microsoft::WRL::ComPtr<IShellItem> item;
              wchar_t* raw = nullptr;
              if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr &&
                  SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) &&
                  raw != nullptr) {
                // This is a selection, NOT an authoritative saved outcome.
                outcome.path = raw;
              } else {
                outcome.error = "系统未返回已保存文件的位置";
              }
              if (raw != nullptr) CoTaskMemFree(raw);
            }
          }
        } catch (...) {
          outcome.error = "无法打开保存对话框";
        }
      }
      self->post_main_([self, pending, outcome = std::move(outcome)]() mutable {
        self->DialogCompleted(std::move(*pending), std::move(outcome));
      });
    }).detach();
  } catch (...) {
    Outcome outcome;
    outcome.error = "文件保存失败，请检查权限与存储空间";
    FinishRequest(std::move(*pending), outcome);
  }
}
void ReaderFileExporter::DialogCompleted(Request request, Outcome outcome) {
  // Platform-thread-only: no shell interface or dialog pointer crosses here.
  // Cancellation during handoff must prevent copy, not rewrite committed saved.
  if (IsCancelled(request.id)) {
    outcome = Outcome{};
    outcome.cancelled = true;
  }
  if (outcome.cancelled || !outcome.error.empty() || outcome.path.empty()) {
    FinishRequest(std::move(request), outcome);
    return;
  }
  // The dialog slot stays occupied until RunCopy's main completion.
  try {
    // Copy the finish into the worker, retaining this request's callback until
    // launch succeeds. A failed launch destroys its worker closure without
    // consuming the only callback or escaping the noexcept window handler.
    RunCopy(request.id, request.source, outcome.path,
            /*allow_overwrite=*/true, request.result);
  } catch (...) {
    Outcome failed;
    failed.error = "文件保存失败，请检查权限与存储空间";
    // No worker accepted the request: fail exactly once on main, erase its
    // cancellation latch, release the active slot and continue the queue.
    FinishRequest(std::move(request), failed);
  }
}
void ReaderFileExporter::RunCopy(const std::string& id,
                                 const std::wstring& source,
                                 const std::wstring& destination,
                                 bool allow_overwrite, Finish result) {
  auto self = shared_from_this();
  auto worker = [self, id, source, destination, allow_overwrite,
               result = std::move(result)]() mutable {
    const auto cancelled = [&self, &id] { return self->IsCancelled(id); };
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
    self->post_main_([self, id, outcome = std::move(outcome),
                      result = std::move(result)]() mutable {
      {
        std::scoped_lock guard(self->lock_);
        self->cancelled_.erase(id);
      }
      result(outcome);
      if (self->active_id_ == id) {
        self->active_id_.clear();
        self->PresentNext();
      }
    });
  };
  if (launch_copy_) {
    launch_copy_(std::move(worker));
  } else {
    std::thread(std::move(worker)).detach();
  }
}
void ReaderFileExporter::CommitDownload(const flutter::EncodableMap& args,
                                        Finish result) {
  const std::string id = StringArg(args, "id");
  std::wstring source = Utf8ToWide(StringArg(args, "sourcePath"));
  std::wstring directory = Utf8ToWide(StringArg(args, "directory"));
  std::wstring name =
      SanitizeFileName(Utf8ToWide(StringArg(args, "fileName")));
  auto self = shared_from_this();
  std::thread([self, id, source = std::move(source),
               directory = std::move(directory), name = std::move(name),
               result = std::move(result)]() mutable {
    const auto cancelled = [&self, &id] { return self->IsCancelled(id); };
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
    self->post_main_([self, id, outcome = std::move(outcome),
                      result = std::move(result)]() mutable {
      {
        std::scoped_lock guard(self->lock_);
        self->cancelled_.erase(id);
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
