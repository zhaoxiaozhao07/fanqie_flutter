#ifndef RUNNER_READER_PLATFORM_BRIDGE_H_
#define RUNNER_READER_PLATFORM_BRIDGE_H_

#include <Windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "reader_file_exporter.h"
#include "reader_playback.h"
#include "reader_sqlite_bridge.h"
#include "reader_text_decoder.h"
#include "win32_window.h"

// The Windows implementation of the shared "com.fanqie.fanqie_flutter/download"
// channel: capability negotiation, power/battery/network queries, background
// transcoding, native save flows, quit handshake and window integration.
// The Android wire contract is preserved unchanged.
class ReaderPlatformBridge {
 public:
  ReaderPlatformBridge(flutter::BinaryMessenger* messenger,
                       std::function<Win32Window*()> window);

  // Handles window messages that need native coordination (WM_CLOSE quit
  // handshake, activation/minimize power assertions, internal tasks).
  // Returns true when the message is fully consumed.
  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::EncodableValue Capabilities();
  std::string QueryNetworkType();
  int QueryBatteryLevel();

  // Display/system power request, only while the reader window is foreground.
  void SetKeepScreenOn(bool enabled);
  void RefreshPowerRequest();
  void ReleasePowerRequest();

  void BeginQuitHandshake(HWND hwnd);
  void FinishQuitHandshake(bool allowed);
  void SaveWindowStateAndClose(HWND hwnd);
  void ShowMainWindow();

  void EnqueueExternalFiles(const std::vector<std::wstring>& paths);
  flutter::EncodableList TakeExternalImports();
  void ReleaseExternalImport(const std::string& id);
  bool ExternalImportsBusy();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<Win32Window*()> window_;
  std::function<void(std::function<void()>)> post_main_;
  // Shared ownership: detached worker threads outlive the window during
  // shutdown without touching freed state.
  std::shared_ptr<ReaderTextDecoder> decoder_;
  std::shared_ptr<ReaderFileExporter> exporter_;
  std::shared_ptr<ReaderPlayback> playback_;
  std::unique_ptr<ReaderSqliteBridge> sqlite_;

  struct ExternalImportState {
    std::mutex mutex;
    flutter::EncodableList pending;
    std::map<std::string, std::wstring> owned_dirs;
    std::map<std::string, std::wstring> source_keys;
    std::map<std::string, uint64_t> staged_sizes;
    std::set<std::string> transfers;
    uint64_t next_id = 1;
  };
  std::shared_ptr<ExternalImportState> imports_;

  bool quit_pending_ = false;
  bool reader_commands_enabled_ = false;
  bool wants_display_awake_ = false;
  bool window_activated_ = true;
  bool window_minimized_ = false;
  HANDLE power_request_ = nullptr;

  static constexpr UINT kPostTaskMessage = WM_APP + 0x101;
  static constexpr UINT kCommitCloseMessage = WM_APP + 0x102;
  static constexpr UINT_PTR kQuitTimerId = 0x4641;
};

#endif  // RUNNER_READER_PLATFORM_BRIDGE_H_
