#ifndef RUNNER_READER_FILE_EXPORTER_H_
#define RUNNER_READER_FILE_EXPORTER_H_

#include <Windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <vector>

// Serialized native save flows. "Save as" uses IFileSaveDialog and commits
// through same-directory staging plus ReplaceFileW (existing file) or
// MoveFileExW (new file); cancellation never truncates an existing file.
// Direct download commits pick a unique numbered name in the configured
// output directory instead of popping a dialog at the end of a task.
class ReaderFileExporter {
 public:
  struct Outcome {
    bool saved = false;
    bool cancelled = false;
    std::wstring path;
    std::string error;
  };
  using Finish = std::function<void(const Outcome&)>;

  ReaderFileExporter(
      std::function<void(std::function<void()>)> post_main,
      std::function<bool()> window_visible,
      std::function<void()> ensure_window)
      : post_main_(std::move(post_main)),
        window_visible_(std::move(window_visible)),
        ensure_window_(std::move(ensure_window)) {}

  // args: id, filePath, fileName, mimeType.
  void SaveAs(const flutter::EncodableMap& args, Finish result);

  // Cancels a queued, dialog-active or copying export request.
  void Cancel(const std::string& id);

  // args: id, sourcePath, directory, fileName. Returns the committed path.
  void CommitDownload(const flutter::EncodableMap& args, Finish result);

  // Native folder picker for the download output directory; cancelled when
  // the user closes the dialog.
  void PickDirectory(Finish result);

 private:
  struct Request {
    std::string id;
    std::wstring source;
    std::wstring name;
    std::string mime;
    Finish result;
  };

  bool IsCancelled(const std::string& id);
  void MarkCancelled(const std::string& id);
  void FinishRequest(Request request, const Outcome& outcome);
  void PresentNext();
  void RunCopy(const std::string& id, const std::wstring& source,
               const std::wstring& destination, bool allow_overwrite,
               Finish result);

  std::function<void(std::function<void()>)> post_main_;
  std::function<bool()> window_visible_;
  std::function<void()> ensure_window_;
  std::mutex lock_;
  std::set<std::string> cancelled_;
  std::vector<Request> queue_;
  std::string active_id_;
};

#endif  // RUNNER_READER_FILE_EXPORTER_H_
