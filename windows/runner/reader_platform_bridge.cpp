#include "reader_platform_bridge.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <Netlistmgr.h>
#include <powrprof.h>
#include <wrl/client.h>

#include <algorithm>
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

}  // namespace

ReaderPlatformBridge::ReaderPlatformBridge(
    flutter::BinaryMessenger* messenger, std::function<Win32Window*()> window)
    : window_(std::move(window)) {
  // The poster captures only the HWND: posting after destruction checks a
  // raw window handle instead of member state, and destroyed-window posts
  // are dropped by the message loop itself.
  const HWND task_hwnd = window_() ? window_()->GetHandle() : nullptr;
  const auto post_main = [task_hwnd](std::function<void()> task) {
    if (task_hwnd == nullptr || !IsWindow(task_hwnd)) return;
    auto* boxed = new std::function<void()>(std::move(task));
    if (PostMessageW(task_hwnd, kPostTaskMessage, 0,
                     reinterpret_cast<LPARAM>(boxed)) == 0) {
      delete boxed;
    }
  };
  decoder_ = std::make_shared<ReaderTextDecoder>(post_main);
  exporter_ = std::make_shared<ReaderFileExporter>(
      post_main,
      [this] {
        Win32Window* window = window_();
        return window != nullptr && window->GetHandle() != nullptr &&
               IsWindowVisible(window->GetHandle()) != FALSE;
      },
      [this] { ShowMainWindow(); });
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.fanqie.fanqie_flutter/download",
      &flutter::StandardMethodCodec::GetInstance());
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
  values[flutter::EncodableValue("tts")] = flutter::EncodableValue(false);
  values[flutter::EncodableValue("mediaPlayback")] =
      flutter::EncodableValue(false);
  values[flutter::EncodableValue("secureStorage")] =
      flutter::EncodableValue(false);
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
