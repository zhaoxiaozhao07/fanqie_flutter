#include "reader_platform_bridge.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <Netlistmgr.h>
#include <powrprof.h>
#include <shellapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <memory>
#include <thread>
#include <vector>

#include "reader_window_state.h"

namespace {

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

std::string ArchitectureName() {
  SYSTEM_INFO info{};
  GetNativeSystemInfo(&info);
  switch (info.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64:
      return "x64";
    case PROCESSOR_ARCHITECTURE_ARM64:
      return "arm64";
    case PROCESSOR_ARCHITECTURE_INTEL:
      return "x86";
    default:
      return "unknown";
  }
}

// Adapter-type probing; never assumes Wi-Fi for unknown hardware, matching the
// conservative prefetch policy.
std::string AdapterKind(bool* any_up) {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer(size);
  ULONG retries = 4;
  ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                GAA_FLAG_SKIP_DNS_SERVER;
  PIP_ADAPTER_ADDRESSES adapters = nullptr;
  for (;;) {
    adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
    const ULONG status =
        GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, adapters, &size);
    if (status == NO_ERROR) break;
    if (status != ERROR_BUFFER_OVERFLOW || retries == 0) {
      *any_up = false;
      return "unknown";
    }
    buffer.resize(size);
    --retries;
  }
  bool wifi = false;
  bool ethernet = false;
  bool mobile = false;
  bool up = false;
  for (PIP_ADAPTER_ADDRESSES adapter = adapters; adapter != nullptr;
       adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp) continue;
    if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
    if (adapter->IfType == IF_TYPE_TUNNEL) continue;
    up = true;
    switch (adapter->IfType) {
      case IF_TYPE_IEEE80211:
        wifi = true;
        break;
      case IF_TYPE_ETHERNET_CSMACD:
        ethernet = true;
        break;
      case IF_TYPE_WWANPP:
      case IF_TYPE_WWANPP2:
        mobile = true;
        break;
      default:
        break;
    }
  }
  *any_up = up;
  if (wifi) return "wifi";
  if (ethernet) return "ethernet";
  if (mobile) return "mobile";
  return "unknown";
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

std::optional<std::string> OptionalStringArg(const flutter::EncodableMap& args,
                                             const char* key) {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<std::string>(*value)) {
    return std::get<std::string>(*value);
  }
  return std::nullopt;
}

double DoubleArg(const flutter::EncodableMap& args, const char* key,
                 double fallback = 0.0) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return fallback;
  if (std::holds_alternative<double>(*value)) return std::get<double>(*value);
  if (std::holds_alternative<int32_t>(*value)) {
    return static_cast<double>(std::get<int32_t>(*value));
  }
  if (std::holds_alternative<int64_t>(*value)) {
    return static_cast<double>(std::get<int64_t>(*value));
  }
  return fallback;
}

int64_t Int64Arg(const flutter::EncodableMap& args, const char* key,
                 int64_t fallback = 0) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return fallback;
  if (std::holds_alternative<int64_t>(*value)) return std::get<int64_t>(*value);
  if (std::holds_alternative<int32_t>(*value)) {
    return static_cast<int64_t>(std::get<int32_t>(*value));
  }
  return fallback;
}

bool BoolArg(const flutter::EncodableMap& args, const char* key,
             bool fallback = false) {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<bool>(*value)) {
    return std::get<bool>(*value);
  }
  return fallback;
}

constexpr uint64_t kMaxExternalFileBytes = 128ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxExternalStagedBytes = 512ULL * 1024ULL * 1024ULL;
constexpr size_t kMaxExternalFiles = 16;

std::wstring ToLowerWide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

bool AcceptsExternalFile(const std::filesystem::path& path) {
  const std::wstring ext = ToLowerWide(path.extension().wstring());
  return ext == L".txt" || ext == L".epub";
}

std::filesystem::path ExternalImportRoot() {
  wchar_t temp[MAX_PATH + 1]{};
  const DWORD len = GetTempPathW(MAX_PATH, temp);
  std::filesystem::path base =
      len > 0 ? std::filesystem::path(temp) : std::filesystem::temp_directory_path();
  return base / L"ReaderExternalImports";
}

}  // namespace

ReaderPlatformBridge::ReaderPlatformBridge(
    flutter::BinaryMessenger* messenger, std::function<Win32Window*()> window)
    : window_(std::move(window)),
      imports_(std::make_shared<ExternalImportState>()) {
  // The poster captures only the HWND: posting after destruction checks a
  // raw window handle instead of member state, and destroyed-window posts
  // are dropped by the message loop itself.
  const HWND task_hwnd = window_() ? window_()->GetHandle() : nullptr;
  if (task_hwnd != nullptr) {
    DragAcceptFiles(task_hwnd, TRUE);
  }
  post_main_ = [task_hwnd](std::function<void()> task) {
    if (task_hwnd == nullptr || !IsWindow(task_hwnd)) return;
    auto* boxed = new std::function<void()>(std::move(task));
    if (PostMessageW(task_hwnd, kPostTaskMessage, 0,
                     reinterpret_cast<LPARAM>(boxed)) == 0) {
      delete boxed;
    }
  };
  decoder_ = std::make_shared<ReaderTextDecoder>(post_main_);
  exporter_ = std::make_shared<ReaderFileExporter>(
      post_main_,
      [this] {
        Win32Window* window = window_();
        return window != nullptr && window->GetHandle() != nullptr &&
               IsWindowVisible(window->GetHandle()) != FALSE;
      },
      [this] { ShowMainWindow(); });
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.fanqie.fanqie_flutter/download",
      &flutter::StandardMethodCodec::GetInstance());
  playback_ = std::make_shared<ReaderPlayback>(
      post_main_, [this](const std::string& method,
                         const flutter::EncodableMap& payload) {
        if (channel_ != nullptr) {
          channel_->InvokeMethod(
              method, std::make_unique<flutter::EncodableValue>(payload));
        }
      });
  sqlite_ = std::make_unique<ReaderSqliteBridge>(messenger, post_main_);
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

bool ReaderPlatformBridge::HandleMessage(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CLOSE:
      BeginQuitHandshake(hwnd);
      return true;
    case WM_DROPFILES: {
      const HDROP drop = reinterpret_cast<HDROP>(wparam);
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      std::vector<std::wstring> paths;
      paths.reserve(count);
      for (UINT i = 0; i < count; ++i) {
        const UINT chars = DragQueryFileW(drop, i, nullptr, 0);
        if (chars == 0) continue;
        std::wstring buffer(chars + 1, L'\0');
        if (DragQueryFileW(drop, i, buffer.data(), chars + 1) > 0) {
          buffer.resize(chars);
          paths.push_back(std::move(buffer));
        }
      }
      DragFinish(drop);
      if (!paths.empty()) {
        EnqueueExternalFiles(paths);
        ShowMainWindow();
      }
      return true;
    }
    case WM_TIMER:
      if (wparam == kQuitTimerId && quit_pending_) {
        FinishQuitHandshake(false);
        return true;
      }
      return false;
    case WM_ACTIVATEAPP:
      window_activated_ = wparam != 0;
      RefreshPowerRequest();
      return false;
    case WM_APPCOMMAND:
      return playback_ != nullptr && playback_->HandleAppCommand(lparam);
    case WM_SIZE:
      if (wparam == SIZE_MINIMIZED) {
        window_minimized_ = true;
        ReleasePowerRequest();
      } else if (window_minimized_) {
        window_minimized_ = false;
        RefreshPowerRequest();
      }
      return false;
    case kCommitCloseMessage:
      SaveWindowStateAndClose(hwnd);
      return true;
    case kPostTaskMessage: {
      auto* boxed = reinterpret_cast<std::function<void()>*>(lparam);
      if (boxed != nullptr) {
        std::unique_ptr<std::function<void()>> owned(boxed);
        (*owned)();
      }
      return true;
    }
    default:
      return false;
  }
}

flutter::EncodableValue ReaderPlatformBridge::Capabilities() {
  Win32Window* window = window_();
  const HWND hwnd = window ? window->GetHandle() : nullptr;
  flutter::EncodableMap values;
  const int battery = QueryBatteryLevel();
  values[flutter::EncodableValue("tts")] = flutter::EncodableValue(true);
  values[flutter::EncodableValue("nativeSpeech")] =
      flutter::EncodableValue(ReaderPlayback::NativeSpeechAvailable());
  values[flutter::EncodableValue("mediaPlayback")] =
      flutter::EncodableValue(true);
  values[flutter::EncodableValue("secureStorage")] =
      flutter::EncodableValue(true);
  values[flutter::EncodableValue("audioOutput")] =
      flutter::EncodableValue(ReaderPlayback::HasOutputDevice());
  values[flutter::EncodableValue("windowBrightnessControl")] =
      flutter::EncodableValue(false);
  values[flutter::EncodableValue("volumeKeys")] = flutter::EncodableValue(false);
  values[flutter::EncodableValue("haptics")] = flutter::EncodableValue(false);
  values[flutter::EncodableValue("battery")] =
      flutter::EncodableValue(battery >= 0);
  values[flutter::EncodableValue("keepAwake")] = flutter::EncodableValue(true);
  values[flutter::EncodableValue("networkType")] =
      flutter::EncodableValue(true);
  values[flutter::EncodableValue("textDecoder")] = flutter::EncodableValue(true);
  values[flutter::EncodableValue("fileExport")] = flutter::EncodableValue(true);
  values[flutter::EncodableValue("fileImport")] = flutter::EncodableValue(true);
  values[flutter::EncodableValue("platform")] =
      flutter::EncodableValue("windows");
  values[flutter::EncodableValue("architecture")] =
      flutter::EncodableValue(ArchitectureName());
  values[flutter::EncodableValue("foreground")] = flutter::EncodableValue(
      hwnd != nullptr && GetForegroundWindow() == hwnd);
  values[flutter::EncodableValue("windowVisible")] =
      flutter::EncodableValue(hwnd != nullptr && IsWindowVisible(hwnd) != 0);
  return flutter::EncodableValue(values);
}

std::string ReaderPlatformBridge::QueryNetworkType() {
  // The Network List Manager knows real internet connectivity; adapter types
  // come from the IP helper table.
  Microsoft::WRL::ComPtr<INetworkListManager> manager;
  const HRESULT hr = CoCreateInstance(CLSID_NetworkListManager, nullptr,
                                      CLSCTX_ALL, IID_PPV_ARGS(&manager));
  if (SUCCEEDED(hr) && manager != nullptr) {
    VARIANT_BOOL connected = VARIANT_FALSE;
    if (SUCCEEDED(manager->get_IsConnectedToInternet(&connected)) &&
        connected != VARIANT_TRUE) {
      return "offline";
    }
  }
  bool any_up = false;
  const std::string kind = AdapterKind(&any_up);
  if (hr == S_OK && manager != nullptr) {
    return kind;  // Internet reachable: report the adapter kind.
  }
  // COM unavailable (rare service states): only "offline" is certain.
  return any_up ? kind : "offline";
}

int ReaderPlatformBridge::QueryBatteryLevel() {
  SYSTEM_POWER_STATUS status{};
  if (GetSystemPowerStatus(&status) == 0) return -1;
  if ((status.BatteryFlag & 128) != 0) return -1;  // No system battery.
  if (status.BatteryLifePercent == 255) return -1;
  return static_cast<int>(status.BatteryLifePercent);
}

void ReaderPlatformBridge::SetKeepScreenOn(bool enabled) {
  wants_display_awake_ = enabled;
  RefreshPowerRequest();
}

void ReaderPlatformBridge::RefreshPowerRequest() {
  ReleasePowerRequest();
  if (!wants_display_awake_ || !window_activated_ || window_minimized_) {
    return;
  }
  Win32Window* window = window_();
  const HWND hwnd = window ? window->GetHandle() : nullptr;
  if (hwnd == nullptr || GetForegroundWindow() != hwnd) {
    return;
  }
  REASON_CONTEXT reason{};
  reason.Version = POWER_REQUEST_CONTEXT_VERSION;
  reason.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  reason.Reason.SimpleReasonString = const_cast<PWSTR>(L"番茄Reader 阅读");
  HANDLE request = PowerCreateRequest(&reason);
  if (request == INVALID_HANDLE_VALUE) {
    return;
  }
  PowerSetRequest(request, PowerRequestDisplayRequired);
  PowerSetRequest(request, PowerRequestSystemRequired);
  power_request_ = request;
}

void ReaderPlatformBridge::ReleasePowerRequest() {
  if (power_request_ == nullptr) return;
  PowerClearRequest(power_request_, PowerRequestDisplayRequired);
  PowerClearRequest(power_request_, PowerRequestSystemRequired);
  CloseHandle(power_request_);
  power_request_ = nullptr;
}

void ReaderPlatformBridge::ShowMainWindow() {
  Win32Window* window = window_();
  if (window == nullptr) return;
  const HWND hwnd = window->GetHandle();
  if (hwnd == nullptr) return;
  if (IsIconic(hwnd)) {
    ShowWindowAsync(hwnd, SW_RESTORE);
  }
  SetForegroundWindow(hwnd);
  SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void ReaderPlatformBridge::BeginQuitHandshake(HWND hwnd) {
  if (quit_pending_) return;
  quit_pending_ = true;
  ReleasePowerRequest();
  // The Dart coordinator flushes reading state; a late or missing reply must
  // never strand the native termination.
  auto handler =
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* reply) {
            const bool allowed = reply != nullptr &&
                                 std::holds_alternative<bool>(*reply) &&
                                 std::get<bool>(*reply);
            FinishQuitHandshake(allowed);
          },
          nullptr, nullptr);
  channel_->InvokeMethod("onAppQuitRequested", nullptr, std::move(handler));
  SetTimer(hwnd, kQuitTimerId, 8000, nullptr);
}

void ReaderPlatformBridge::FinishQuitHandshake(bool allowed) {
  if (!quit_pending_) return;
  quit_pending_ = false;
  const HWND hwnd = window_() ? window_()->GetHandle() : nullptr;
  if (hwnd != nullptr) {
    KillTimer(hwnd, kQuitTimerId);
  }
  if (allowed) {
    if (hwnd != nullptr) {
      PostMessageW(hwnd, kCommitCloseMessage, 0, 0);
    }
    return;
  }
  ShowMainWindow();
  MessageBoxW(
      hwnd,
      L"请等待导入、恢复或阅读数据保存完成后重试。原数据与恢复日志不会被清除。",
      L"暂时无法退出", MB_OK | MB_ICONINFORMATION);
}

void ReaderPlatformBridge::SaveWindowStateAndClose(HWND hwnd) {
  if (playback_ != nullptr) {
    playback_->Release();
  }
  if (sqlite_ != nullptr) {
    sqlite_->Shutdown();
  }
  // Never persist the borderless full-screen geometry; restore the durable
  // normal placement first.
  if (Win32Window* window = window_(); window != nullptr &&
                                        window->IsFullScreen()) {
    window->ToggleFullScreen();
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (GetWindowPlacement(hwnd, &placement)) {
    reader_window_state::Save(hwnd, placement);
  }
  DestroyWindow(hwnd);
}

void ReaderPlatformBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap args =
      arguments == nullptr ? flutter::EncodableMap() : *arguments;

  const std::string& method = call.method_name();
  if (method == "getReaderCapabilities") {
    result->Success(Capabilities());
    return;
  }
  if (method == "readTtsSecret") {
    std::optional<std::string> secret;
    std::string error;
    if (!ReaderPlayback::ReadSecret(&secret, &error)) {
      result->Error("secureStorage", error);
      return;
    }
    if (secret.has_value()) {
      result->Success(flutter::EncodableValue(*secret));
    } else {
      result->Success();
    }
    return;
  }
  if (method == "writeTtsSecret") {
    const auto value = OptionalStringArg(args, "value");
    std::string error;
    if (!value.has_value() || !ReaderPlayback::WriteSecret(*value, &error)) {
      result->Error("secureStorage",
                    error.empty() ? "密钥未写入系统安全存储" : error);
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "readNamedSecret") {
    std::string key = StringArg(args, "key");
    while (!key.empty() && std::isspace(static_cast<unsigned char>(key.front()))) {
      key.erase(key.begin());
    }
    while (!key.empty() && std::isspace(static_cast<unsigned char>(key.back()))) {
      key.pop_back();
    }
    if (!ReaderPlayback::IsValidSecretKey(key)) {
      result->Success();
      return;
    }
    std::optional<std::string> secret;
    std::string error;
    if (!ReaderPlayback::ReadNamedSecret(key, &secret, &error)) {
      result->Error("secureStorage",
                    error.empty() ? "无法读取系统安全存储；未改写原密钥" : error);
      return;
    }
    if (secret.has_value()) {
      result->Success(flutter::EncodableValue(*secret));
    } else {
      result->Success();
    }
    return;
  }
  if (method == "writeNamedSecret") {
    std::string key = StringArg(args, "key");
    while (!key.empty() && std::isspace(static_cast<unsigned char>(key.front()))) {
      key.erase(key.begin());
    }
    while (!key.empty() && std::isspace(static_cast<unsigned char>(key.back()))) {
      key.pop_back();
    }
    const auto value = OptionalStringArg(args, "value");
    if (!ReaderPlayback::IsValidSecretKey(key) || !value.has_value()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    std::string error;
    if (!ReaderPlayback::WriteNamedSecret(key, *value, &error)) {
      result->Error("secureStorage",
                    error.empty() ? "密钥未写入系统安全存储" : error);
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "probeAudioDuration") {
    const std::string file_path = StringArg(args, "filePath");
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    const auto post_main = post_main_;
    std::thread([file_path, owned, post_main] {
      flutter::EncodableMap probed =
          ReaderPlayback::ProbeAudioDuration(file_path);
      post_main([owned, probed = std::move(probed)] {
        owned->Success(flutter::EncodableValue(probed));
      });
    }).detach();
    return;
  }
  if (method == "getFreeDiskBytes") {
    const std::string dir_path = StringArg(args, "path");
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    const auto post_main = post_main_;
    std::thread([dir_path, owned, post_main] {
      const int64_t free_bytes = ReaderPlayback::FreeDiskBytes(dir_path);
      post_main([owned, free_bytes] {
        owned->Success(flutter::EncodableValue(free_bytes));
      });
    }).detach();
    return;
  }
  if (method == "initNativeTts") {
    result->Success(
        flutter::EncodableValue(ReaderPlayback::NativeSpeechAvailable()));
    return;
  }
  if (method == "getNativeTtsVoices") {
    result->Success(flutter::EncodableValue(ReaderPlayback::Voices()));
    return;
  }
  if (method == "synthesizeNativeTtsToFile") {
    const std::string text = StringArg(args, "text");
    const double rate = DoubleArg(args, "rate", 1.0);
    const std::string voice_id = StringArg(args, "voiceId");
    const std::string output_path = StringArg(args, "outputPath");
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    const auto post_main = post_main_;
    std::thread([text, rate, voice_id, output_path, owned, post_main] {
      flutter::EncodableMap synth = ReaderPlayback::SynthesizeNativeTtsToFile(
          text, rate, voice_id, output_path);
      post_main([owned, synth = std::move(synth)] {
        owned->Success(flutter::EncodableValue(synth));
      });
    }).detach();
    return;
  }
  if (method == "speakNativeTts") {
    result->Success(flutter::EncodableValue(playback_->Speak(
        StringArg(args, "id"), StringArg(args, "text"),
        DoubleArg(args, "rate", 1.0), StringArg(args, "voice"))));
    return;
  }
  if (method == "playAudioFile") {
    result->Success(flutter::EncodableValue(playback_->Play(
        StringArg(args, "id"), StringArg(args, "filePath"),
        DoubleArg(args, "rate", 1.0), BoolArg(args, "preservePitch", true),
        std::max<int64_t>(0, Int64Arg(args, "startPositionMs", 0)))));
    return;
  }
  if (method == "preloadNextAudio") {
    result->Success(flutter::EncodableValue(playback_->PreloadNext(
        StringArg(args, "afterId"), StringArg(args, "id"),
        StringArg(args, "filePath"), DoubleArg(args, "rate", 1.0),
        BoolArg(args, "preservePitch", true),
        Int64Arg(args, "gapMs", 0))));
    return;
  }
  if (method == "clearPreloadedAudio") {
    playback_->ClearPreloaded();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setPlaybackRate") {
    result->Success(flutter::EncodableValue(playback_->SetPlaybackRate(
        DoubleArg(args, "rate", 1.0), BoolArg(args, "preservePitch", true))));
    return;
  }
  if (method == "getAudioPosition") {
    result->Success(flutter::EncodableValue(playback_->AudioPosition()));
    return;
  }
  if (method == "stopPlayback") {
    result->Success(
        flutter::EncodableValue(playback_->Stop(OptionalStringArg(args, "id"))));
    return;
  }
  if (method == "stopNativeTts") {
    result->Success(flutter::EncodableValue(playback_->StopNative()));
    return;
  }
  if (method == "stopAudio") {
    result->Success(flutter::EncodableValue(playback_->StopAudio()));
    return;
  }
  if (method == "pauseAudio") {
    result->Success(flutter::EncodableValue(
        playback_->PauseAudio(OptionalStringArg(args, "id"))));
    return;
  }
  if (method == "resumeAudio") {
    result->Success(flutter::EncodableValue(
        playback_->ResumeAudio(OptionalStringArg(args, "id"))));
    return;
  }
  if (method == "setAudioVolume") {
    result->Success(flutter::EncodableValue(
        playback_->SetVolume(DoubleArg(args, "volume", 1.0))));
    return;
  }
  if (method == "setSleepDeadline") {
    result->Success(flutter::EncodableValue(
        playback_->SetDeadline(Int64Arg(args, "milliseconds", 0))));
    return;
  }
  if (method == "getPlaybackState") {
    result->Success(flutter::EncodableValue(playback_->PlaybackState()));
    return;
  }
  if (method == "updateMediaPlaybackState") {
    playback_->UpdateMedia(StringArg(args, "title"),
                           StringArg(args, "subtitle"),
                           BoolArg(args, "isPlaying", false),
                           BoolArg(args, "isActive", false));
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "releasePlaybackService") {
    playback_->Release();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "getNetworkType") {
    result->Success(flutter::EncodableValue(QueryNetworkType()));
    return;
  }
  if (method == "getBatteryLevel") {
    result->Success(flutter::EncodableValue(QueryBatteryLevel()));
    return;
  }
  if (method == "setKeepScreenOn") {
    bool enabled = false;
    if (const auto* value = FindArg(args, "enabled");
        value != nullptr && std::holds_alternative<bool>(*value)) {
      enabled = std::get<bool>(*value);
    }
    SetKeepScreenOn(enabled);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "normalizeTextFile") {
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    decoder_->Normalize(
        args, [owned](const ReaderTextDecoder::Outcome& outcome) {
          if (outcome.ok) {
            flutter::EncodableMap value;
            value[flutter::EncodableValue("path")] =
                flutter::EncodableValue(outcome.path);
            value[flutter::EncodableValue("encoding")] =
                flutter::EncodableValue(outcome.encoding);
            owned->Success(flutter::EncodableValue(value));
          } else {
            owned->Error(outcome.error_code.c_str(),
                         outcome.error_message.c_str());
          }
        });
    return;
  }
  if (method == "cancelTextDecode") {
    decoder_->Cancel(StringArg(args, "id"));
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "saveExportFile") {
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    exporter_->SaveAs(
        args,
        [owned](const ReaderFileExporter::Outcome& outcome) {
          flutter::EncodableMap value;
          value[flutter::EncodableValue("status")] = flutter::EncodableValue(
              outcome.saved
                  ? "saved"
                  : (outcome.cancelled ? "cancelled" : "failed"));
          if (outcome.saved) {
            value[flutter::EncodableValue("path")] =
                flutter::EncodableValue(WideToUtf8(outcome.path));
          }
          if (!outcome.error.empty()) {
            value[flutter::EncodableValue("error")] =
                flutter::EncodableValue(outcome.error);
          }
          owned->Success(flutter::EncodableValue(value));
        });
    return;
  }
  if (method == "cancelExport") {
    exporter_->Cancel(StringArg(args, "id"));
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "commitDownloadFile") {
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    exporter_->CommitDownload(
        args,
        [owned](const ReaderFileExporter::Outcome& outcome) {
          flutter::EncodableMap value;
          value[flutter::EncodableValue("status")] = flutter::EncodableValue(
              outcome.saved
                  ? "saved"
                  : (outcome.cancelled ? "cancelled" : "failed"));
          if (outcome.saved) {
            value[flutter::EncodableValue("path")] =
                flutter::EncodableValue(WideToUtf8(outcome.path));
          }
          if (!outcome.error.empty()) {
            value[flutter::EncodableValue("error")] =
                flutter::EncodableValue(outcome.error);
          }
          owned->Success(flutter::EncodableValue(value));
        });
    return;
  }
  if (method == "pickDownloadDirectory") {
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
        result.release());
    exporter_->PickDirectory(
        [owned](const ReaderFileExporter::Outcome& outcome) {
          flutter::EncodableMap value;
          value[flutter::EncodableValue("status")] = flutter::EncodableValue(
              outcome.saved
                  ? "saved"
                  : (outcome.cancelled ? "cancelled" : "failed"));
          if (outcome.saved) {
            value[flutter::EncodableValue("path")] =
                flutter::EncodableValue(WideToUtf8(outcome.path));
          }
          if (!outcome.error.empty()) {
            value[flutter::EncodableValue("error")] =
                flutter::EncodableValue(outcome.error);
          }
          owned->Success(flutter::EncodableValue(value));
        });
    return;
  }
  if (method == "showMainWindow") {
    ShowMainWindow();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "takeExternalImports") {
    result->Success(flutter::EncodableValue(TakeExternalImports()));
    return;
  }
  if (method == "releaseExternalImport") {
    ReleaseExternalImport(StringArg(args, "id"));
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "externalImportsBusy") {
    result->Success(flutter::EncodableValue(ExternalImportsBusy()));
    return;
  }
  if (method == "setReaderCommandsEnabled") {
    bool enabled = false;
    if (const auto* value = FindArg(args, "enabled");
        value != nullptr && std::holds_alternative<bool>(*value)) {
      enabled = std::get<bool>(*value);
    }
    reader_commands_enabled_ = enabled;
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setReaderShortcuts") {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "requestQuit") {
    result->Success(flutter::EncodableValue(true));
    if (Win32Window* window = window_(); window != nullptr &&
                                        window->GetHandle() != nullptr) {
      PostMessageW(window->GetHandle(), WM_CLOSE, 0, 0);
    }
    return;
  }
  if (method == "toggleFullScreen") {
    Win32Window* window = window_();
    if (window == nullptr) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(window->ToggleFullScreen()));
    return;
  }
  if (method == "isFullScreen") {
    Win32Window* window = window_();
    result->Success(flutter::EncodableValue(
        window != nullptr && window->IsFullScreen()));
    return;
  }
#ifndef NDEBUG
  if (method == "stageTestExternalFiles") {
    std::vector<std::wstring> paths;
    if (const auto* list = FindArg(args, "paths");
        list != nullptr && std::holds_alternative<flutter::EncodableList>(*list)) {
      for (const auto& item : std::get<flutter::EncodableList>(*list)) {
        if (std::holds_alternative<std::string>(item)) {
          paths.push_back(Utf8ToWide(std::get<std::string>(item)));
        }
      }
    }
    EnqueueExternalFiles(paths);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setTestWindowSize") {
    Win32Window* window = window_();
    double width = 0;
    double height = 0;
    if (const auto* value = FindArg(args, "width");
        value != nullptr && std::holds_alternative<double>(*value)) {
      width = std::get<double>(*value);
    }
    if (const auto* value = FindArg(args, "height");
        value != nullptr && std::holds_alternative<double>(*value)) {
      height = std::get<double>(*value);
    }
    if (window != nullptr && window->GetHandle() != nullptr && width > 0 &&
        height > 0) {
      const HWND hwnd = window->GetHandle();
      const UINT dpi = GetDpiForWindow(hwnd);
      const double scale = dpi / 96.0;
      // Match the client area to the requested logical size, like macOS
      // setContentSize; the outer frame grows by the decoration.
      RECT frame{0, 0,
                 static_cast<LONG>(std::max(720.0 * scale, width * scale)),
                 static_cast<LONG>(std::max(520.0 * scale, height * scale))};
      const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (!AdjustWindowRect(&frame, static_cast<DWORD>(style), FALSE)) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      RECT outer{};
      GetWindowRect(hwnd, &outer);
      SetWindowPos(hwnd, nullptr, outer.left, outer.top,
                   frame.right - frame.left, frame.bottom - frame.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "getTestWindowState") {
    Win32Window* window = window_();
    const HWND hwnd = window ? window->GetHandle() : nullptr;
    flutter::EncodableMap state;
    RECT client{};
    if (hwnd != nullptr) {
      GetClientRect(hwnd, &client);
    }
    state[flutter::EncodableValue("visible")] = flutter::EncodableValue(
        hwnd != nullptr && IsWindowVisible(hwnd) != 0);
    state[flutter::EncodableValue("displayAssertion")] =
        flutter::EncodableValue(power_request_ != nullptr);
    state[flutter::EncodableValue("width")] =
        flutter::EncodableValue(static_cast<double>(client.right));
    state[flutter::EncodableValue("height")] =
        flutter::EncodableValue(static_cast<double>(client.bottom));
    state[flutter::EncodableValue("fullScreen")] = flutter::EncodableValue(
        window != nullptr && window->IsFullScreen());
    state[flutter::EncodableValue("minimized")] =
        flutter::EncodableValue(hwnd != nullptr && IsIconic(hwnd) != 0);
    state[flutter::EncodableValue("backingScaleFactor")] =
        flutter::EncodableValue(
            hwnd != nullptr ? GetDpiForWindow(hwnd) / 96.0 : 0.0);
    state[flutter::EncodableValue("applicationActive")] =
        flutter::EncodableValue(hwnd != nullptr &&
                                GetForegroundWindow() == hwnd);
    return result->Success(flutter::EncodableValue(state));
  }
  if (method == "setTestFullScreen") {
    Win32Window* window = window_();
    bool enabled = false;
    if (const auto* value = FindArg(args, "enabled");
        value != nullptr && std::holds_alternative<bool>(*value)) {
      enabled = std::get<bool>(*value);
    }
    if (window != nullptr && window->IsFullScreen() != enabled) {
      window->ToggleFullScreen();
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "hideTestWindow") {
    Win32Window* window = window_();
    if (window != nullptr && window->GetHandle() != nullptr) {
      ShowWindow(window->GetHandle(), SW_MINIMIZE);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
#endif
  result->NotImplemented();
}

void ReaderPlatformBridge::EnqueueExternalFiles(
    const std::vector<std::wstring>& paths) {
  const auto imports = imports_;
  const auto post_main = post_main_;
  auto notify_ready = [this, post_main] {
    post_main([this] {
      if (channel_ != nullptr) {
        channel_->InvokeMethod("onExternalImportsAvailable", nullptr);
      }
    });
  };

  size_t count = 0;
  for (const auto& raw_path : paths) {
    if (count >= kMaxExternalFiles) break;
    ++count;
    const std::filesystem::path source_path(raw_path);
    const std::wstring normalized_key = ToLowerWide(source_path.lexically_normal().wstring());
    std::string id;
    {
      std::lock_guard<std::mutex> lock(imports->mutex);
      bool duplicate = false;
      for (const auto& entry : imports->source_keys) {
        if (entry.second == normalized_key) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) continue;
      if (imports->source_keys.size() >= kMaxExternalFiles) {
        if (imports->pending.size() < kMaxExternalFiles) {
          flutter::EncodableMap limit_record;
          limit_record[flutter::EncodableValue("id")] =
              flutter::EncodableValue("limit_" + std::to_string(imports->next_id++));
          limit_record[flutter::EncodableValue("name")] =
              flutter::EncodableValue("批量导入");
          limit_record[flutter::EncodableValue("error")] = flutter::EncodableValue(
              "一次最多接收 16 个文件；暂存总量最多 512 MB，未接收的文件请稍后重试。");
          imports->pending.push_back(flutter::EncodableValue(limit_record));
          notify_ready();
        }
        break;
      }
      id = "ext_" + std::to_string(imports->next_id++);
      imports->source_keys[id] = normalized_key;
      imports->transfers.insert(id);
    }

    std::thread([imports, notify_ready, id, source_path] {
      flutter::EncodableMap record;
      record[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
      const std::wstring filename = source_path.filename().wstring();
      record[flutter::EncodableValue("name")] =
          flutter::EncodableValue(WideToUtf8(filename.empty() ? L"文件导入" : filename));

      std::wstring staged_dir;
      uint64_t staged_bytes = 0;
      std::string error;

      uint64_t limit = kMaxExternalFileBytes;
      {
        std::lock_guard<std::mutex> lock(imports->mutex);
        uint64_t used = 0;
        for (const auto& item : imports->staged_sizes) used += item.second;
        const uint64_t remaining =
            used < kMaxExternalStagedBytes ? (kMaxExternalStagedBytes - used) : 0;
        limit = std::min(kMaxExternalFileBytes, remaining);
      }

      if (!AcceptsExternalFile(source_path)) {
        error = "仅支持本地 TXT / EPUB 文件。";
      } else {
        const DWORD attrs = GetFileAttributesW(source_path.c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES ||
            (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
            (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
          error = "文件为空、不是普通文件或超过导入容量限制（单文件 128 MB）。";
        } else {
          HANDLE input = CreateFileW(
              source_path.c_str(), GENERIC_READ,
              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
              nullptr);
          if (input == INVALID_HANDLE_VALUE) {
            error = "无法读取所选文件。";
          } else {
            BY_HANDLE_FILE_INFORMATION info{};
            LARGE_INTEGER file_size{};
            if (!GetFileInformationByHandle(input, &info) ||
                (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                !GetFileSizeEx(input, &file_size) || file_size.QuadPart <= 0 ||
                static_cast<uint64_t>(file_size.QuadPart) > limit) {
              CloseHandle(input);
              error = "文件为空、不是普通文件或超过导入容量限制（单文件 128 MB）。";
            } else {
              const std::filesystem::path dir =
                  ExternalImportRoot() / Utf8ToWide(id);
              std::error_code ec;
              std::filesystem::create_directories(dir, ec);
              const std::filesystem::path pending_file = dir / L"source.pending";
              const std::filesystem::path target_file = dir / source_path.filename();
              HANDLE output = CreateFileW(
                  pending_file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
              if (output == INVALID_HANDLE_VALUE) {
                CloseHandle(input);
                std::filesystem::remove_all(dir, ec);
                error = "无法创建导入暂存文件。";
              } else {
                std::vector<char> buffer(64 * 1024);
                uint64_t copied = 0;
                bool ok = true;
                for (;;) {
                  DWORD read_bytes = 0;
                  if (!ReadFile(input, buffer.data(),
                                static_cast<DWORD>(buffer.size()), &read_bytes,
                                nullptr)) {
                    ok = false;
                    break;
                  }
                  if (read_bytes == 0) break;
                  copied += read_bytes;
                  if (copied > limit) {
                    ok = false;
                    break;
                  }
                  DWORD written = 0;
                  if (!WriteFile(output, buffer.data(), read_bytes, &written,
                                 nullptr) ||
                      written != read_bytes) {
                    ok = false;
                    break;
                  }
                }
                FlushFileBuffers(output);
                CloseHandle(output);
                CloseHandle(input);
                if (!ok ||
                    copied != static_cast<uint64_t>(file_size.QuadPart) ||
                    !MoveFileExW(pending_file.c_str(), target_file.c_str(),
                                 MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                  std::filesystem::remove_all(dir, ec);
                  error = "复制外部导入文件失败。";
                } else {
                  staged_dir = dir.wstring();
                  staged_bytes = copied;
                  record[flutter::EncodableValue("path")] =
                      flutter::EncodableValue(WideToUtf8(target_file.wstring()));
                }
              }
            }
          }
        }
      }

      if (!error.empty()) {
        record[flutter::EncodableValue("error")] =
            flutter::EncodableValue(error);
      }
      {
        std::lock_guard<std::mutex> lock(imports->mutex);
        imports->transfers.erase(id);
        if (!staged_dir.empty()) {
          imports->owned_dirs[id] = staged_dir;
          imports->staged_sizes[id] = staged_bytes;
        }
        imports->pending.push_back(flutter::EncodableValue(record));
      }
      notify_ready();
    }).detach();
  }
}

flutter::EncodableList ReaderPlatformBridge::TakeExternalImports() {
  std::lock_guard<std::mutex> lock(imports_->mutex);
  flutter::EncodableList out = std::move(imports_->pending);
  imports_->pending.clear();
  return out;
}

void ReaderPlatformBridge::ReleaseExternalImport(const std::string& id) {
  std::wstring dir;
  {
    std::lock_guard<std::mutex> lock(imports_->mutex);
    imports_->source_keys.erase(id);
    imports_->staged_sizes.erase(id);
    const auto it = imports_->owned_dirs.find(id);
    if (it != imports_->owned_dirs.end()) {
      dir = it->second;
      imports_->owned_dirs.erase(it);
    }
  }
  if (!dir.empty()) {
    std::thread([dir] {
      std::error_code ec;
      std::filesystem::remove_all(std::filesystem::path(dir), ec);
    }).detach();
  }
}

bool ReaderPlatformBridge::ExternalImportsBusy() {
  std::lock_guard<std::mutex> lock(imports_->mutex);
  return !imports_->transfers.empty();
}
