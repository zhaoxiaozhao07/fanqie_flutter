#ifndef RUNNER_READER_PLAYBACK_H_
#define RUNNER_READER_PLAYBACK_H_

#include <Windows.h>

#include <flutter/encodable_value.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

// Windows DPAPI secret storage and native SAPI/MCI audio playback matching the
// macOS ReaderPlayback contract.
class ReaderPlayback : public std::enable_shared_from_this<ReaderPlayback> {
 public:
  using EmitCallback =
      std::function<void(const std::string&, const flutter::EncodableMap&)>;
  using PostMainCallback = std::function<void(std::function<void()>)>;

  ReaderPlayback(PostMainCallback post_main, EmitCallback emit);
  ~ReaderPlayback();

  static bool HasOutputDevice();
  static bool NativeSpeechAvailable();
  static flutter::EncodableList Voices();

  static bool WriteSecret(const std::string& value, std::string* error_out);
  static bool ReadSecret(std::optional<std::string>* value_out,
                         std::string* error_out);

  bool Speak(const std::string& id, const std::string& text, double rate,
             const std::string& voice_id);
  bool Play(const std::string& id, const std::string& file_path);
  bool Stop(const std::optional<std::string>& id = std::nullopt);
  bool StopNative();
  bool StopAudio();
  bool PauseAudio(const std::optional<std::string>& id);
  bool ResumeAudio(const std::optional<std::string>& id);
  bool SetVolume(double value);
  bool SetDeadline(int64_t milliseconds);
  flutter::EncodableMap PlaybackState();
  void UpdateMedia(const std::string& title, const std::string& subtitle,
                   bool playing, bool active);
  void Release();

  // Handles WM_APPCOMMAND media keys when media playback is active.
  bool HandleAppCommand(LPARAM lparam);

 private:
  bool ValidateAudioFile(const std::wstring& path) const;
  void CloseMci();
  int64_t QueryMciPositionMs() const;
  bool IsMciPlaying() const;

  PostMainCallback post_main_;
  EmitCallback emit_;

  mutable std::mutex mutex_;
  std::string current_id_;
  uint64_t token_generation_ = 0;
  bool native_ = false;
  bool paused_ = false;
  bool mci_open_ = false;
  double volume_ = 1.0;
  int64_t sleep_deadline_ = 0;
  uint64_t sleep_generation_ = 0;
  bool media_active_ = false;
  bool media_playing_ = false;
  HANDLE speech_stop_event_ = nullptr;
};

#endif  // RUNNER_READER_PLAYBACK_H_
