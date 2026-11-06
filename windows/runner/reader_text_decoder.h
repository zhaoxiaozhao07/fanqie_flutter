#ifndef RUNNER_READER_TEXT_DECODER_H_
#define RUNNER_READER_TEXT_DECODER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>

// Chunked, strictly validated text transcoding for local book imports.
// Mirrors the Android/macOS contract: BOM detection, strict UTF-8 first, then
// GB18030 (GBK-compatible) and finally Big5 in automatic mode; cross-chunk
// multibyte sequences are retained between bounded reads; cancellation never
// publishes a partial file. All results are delivered on the platform thread.
//
// Worker threads keep the decoder alive through shared_ptr, so a window
// destroyed mid-import never touches freed state; late replies are dropped
// by the HWND-guarded main-thread poster.
class ReaderTextDecoder : public std::enable_shared_from_this<ReaderTextDecoder> {
 public:
  struct Outcome {
    bool ok = false;
    std::string path;      // UTF-8 normalized temporary file (on success).
    std::string encoding;  // Selected encoding name (on success).
    std::string error_code;     // TEXT_DECODE / IMPORT_CANCELLED.
    std::string error_message;  // User-facing Chinese message.
  };
  using Finish = std::function<void(const Outcome&)>;

  // |post_main| marshals a callable onto the platform (STA) thread; it must
  // stay callable even after this object is destroyed.
  explicit ReaderTextDecoder(
      std::function<void(std::function<void()>)> post_main)
      : post_main_(std::move(post_main)) {}

  // args: id, path, encoding ("auto" or one of the supported names).
  void Normalize(const flutter::EncodableMap& args, Finish result);

  // Cancels a queued or running decode; late native replies are dropped.
  void Cancel(const std::string& id);

 private:
  bool IsCancelled(const std::string& id);
  void RememberPending(const std::string& id);
  void Forget(const std::string& id);

  std::function<void(std::function<void()>)> post_main_;
  std::mutex lock_;
  std::set<std::string> cancelled_;
  std::set<std::string> pending_;
};

#endif  // RUNNER_READER_TEXT_DECODER_H_
