#ifndef RUNNER_READER_PLAYBACK_H_
#define RUNNER_READER_PLAYBACK_H_

#include <Windows.h>
#include <flutter/encodable_value.h>
#include <mfmediaengine.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

// Windows 原生 DPAPI 命名安全存储、SAPI 系统朗读与双 IMFMediaEngine
// 沉浸式无缝切段音频播放引擎（与 Android / macOS 通道契约完全对齐）。
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

  static bool IsValidSecretKey(const std::string& key);
  static bool WriteSecret(const std::string& value, std::string* error_out);
  static bool ReadSecret(std::optional<std::string>* value_out,
                         std::string* error_out);
  static bool WriteNamedSecret(const std::string& key, const std::string& value,
                               std::string* error_out);
  static bool ReadNamedSecret(const std::string& key,
                              std::optional<std::string>* value_out,
                              std::string* error_out);

  // 通过 Media Foundation SourceReader 校验音频可解码性与真实时长（支持 .tmp）。
  static flutter::EncodableMap ProbeAudioDuration(const std::string& file_path);

  // 查询目标路径所在文件系统的真实剩余磁盘空间字节数，失败返回 -1。
  static int64_t FreeDiskBytes(const std::string& raw_path);

  bool Speak(const std::string& id, const std::string& text, double rate,
             const std::string& voice_id);
  bool Play(const std::string& id, const std::string& file_path,
            double rate = 1.0, bool preserve_pitch = true,
            int64_t start_position_ms = 0);
  bool PreloadNext(const std::string& after_id, const std::string& id,
                   const std::string& file_path, double rate = 1.0,
                   bool preserve_pitch = true, int64_t gap_ms = 0);
  void ClearPreloaded();

  bool Stop(const std::optional<std::string>& id = std::nullopt);
  bool StopNative();
  bool StopAudio();
  bool PauseAudio(const std::optional<std::string>& id);
  bool ResumeAudio(const std::optional<std::string>& id);
  bool SetVolume(double value);
  bool SetPlaybackRate(double rate, bool preserve_pitch = true);
  bool SetDeadline(int64_t milliseconds);
  flutter::EncodableMap AudioPosition();
  flutter::EncodableMap PlaybackState();
  void UpdateMedia(const std::string& title, const std::string& subtitle,
                   bool playing, bool active);
  void Release();

  // 响应系统多媒体按键事件。
  bool HandleAppCommand(LPARAM lparam);

  // 供内部 MediaEngine 事件回调（主线程）调用。
  void OnEngineEventMain(uint64_t slot_id, DWORD event, DWORD_PTR param1,
                         DWORD param2);

 private:
  struct EngineSlot {
    uint64_t slot_id = 0;
    Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
    std::string token_id;
    int64_t start_position_ms = 0;
    int64_t duration_hint_ms = 0;
    bool can_play = false;
    bool start_requested = false;
    bool started = false;
  };

  static bool ValidateAudioFile(const std::wstring& path);
  static bool ReadAudioBytes(const std::wstring& path,
                             std::vector<uint8_t>* bytes_out,
                             bool* is_wav_out);

  std::unique_ptr<EngineSlot> CreateEngineSlot(
      const std::string& token_id, const std::vector<uint8_t>& bytes,
      bool is_wav, double rate, int64_t start_position_ms);
  void ShutdownSlot(std::unique_ptr<EngineSlot>* slot);
  void ApplyRateToSlot(const std::unique_ptr<EngineSlot>& slot, double rate);
  void ApplyVolumeToSlot(const std::unique_ptr<EngineSlot>& slot,
                         double volume);
  bool TryAdvanceToPreloaded(const std::string& completed_id);
  void CommitTransition(uint64_t transition_gen,
                        const std::string& completed_id,
                        const std::string& target_id);
  int64_t QueryActivePositionMs() const;
  int64_t QueryActiveDurationMs() const;
  bool IsActiveEnginePlaying() const;

  PostMainCallback post_main_;
  EmitCallback emit_;
  bool mf_started_ = false;

  mutable std::mutex mutex_;
  std::string current_id_;
  uint64_t token_generation_ = 0;
  uint64_t next_slot_id_ = 1;
  uint64_t preload_generation_ = 0;
  uint64_t transition_generation_ = 0;
  bool native_ = false;
  bool paused_ = false;
  double volume_ = 1.0;
  double playback_rate_ = 1.0;
  bool preserve_pitch_ = true;
  int64_t sleep_deadline_ = 0;
  uint64_t sleep_generation_ = 0;
  bool media_active_ = false;
  bool media_playing_ = false;
  HANDLE speech_stop_event_ = nullptr;

  // 以下 IMFMediaEngine 槽位仅在 Win32 主线程操作。
  std::unique_ptr<EngineSlot> active_slot_;
  std::unique_ptr<EngineSlot> next_slot_;
  std::string next_after_id_;
  int64_t next_gap_ms_ = 0;
  std::unique_ptr<EngineSlot> pending_transition_slot_;
};

#endif  // RUNNER_READER_PLAYBACK_H_
