#include "reader_playback.h"

#include <ShlObj.h>
#include <mmsystem.h>
#include <sapi.h>
#include <wincrypt.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cwctype>
#include <filesystem>
#include <future>
#include <regex>
#include <thread>

namespace {

constexpr uint64_t kMaxAudioBytes = 16ULL * 1024ULL * 1024ULL;
constexpr size_t kMaxSecretBytes = 8192;

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return std::string();
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
  if (size <= 0) return std::wstring();
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), size);
  return out;
}

std::wstring ToLowerWide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

std::filesystem::path SecretFilePath() {
  PWSTR raw = nullptr;
  std::filesystem::path base;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw)) &&
      raw != nullptr) {
    base = std::filesystem::path(raw);
    CoTaskMemFree(raw);
  } else {
    wchar_t temp[MAX_PATH + 1]{};
    GetTempPathW(MAX_PATH, temp);
    base = std::filesystem::path(temp);
  }
  return base / L"com.fanqie" / L"FanqieReader" / L"tts_secret.dpapi";
}

std::vector<std::filesystem::path> AllowedAudioRoots() {
  std::vector<std::filesystem::path> roots;
  wchar_t temp[MAX_PATH + 1]{};
  if (GetTempPathW(MAX_PATH, temp) > 0) {
    std::error_code ec;
    roots.push_back(std::filesystem::weakly_canonical(temp, ec));
  }
  PWSTR local_appdata = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                     &local_appdata)) &&
      local_appdata != nullptr) {
    std::error_code ec;
    roots.push_back(std::filesystem::weakly_canonical(local_appdata, ec));
    CoTaskMemFree(local_appdata);
  }
  return roots;
}

std::wstring ReadRegString(HKEY key, const wchar_t* value_name) {
  DWORD type = 0;
  DWORD bytes = 0;
  if (RegQueryValueExW(key, value_name, nullptr, &type, nullptr, &bytes) !=
          ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) || bytes < sizeof(wchar_t)) {
    return L"";
  }
  std::wstring buffer(bytes / sizeof(wchar_t), L'\0');
  if (RegQueryValueExW(key, value_name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(buffer.data()),
                       &bytes) != ERROR_SUCCESS) {
    return L"";
  }
  while (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  return buffer;
}

std::string LcidHexToTag(const std::wstring& hex_lcid) {
  try {
    const LCID lcid = static_cast<LCID>(std::stoul(hex_lcid, nullptr, 16));
    wchar_t name[LOCALE_NAME_MAX_LENGTH]{};
    if (LCIDToLocaleName(lcid, name, LOCALE_NAME_MAX_LENGTH, 0) > 0) {
      return WideToUtf8(name);
    }
  } catch (...) {
  }
  if (ToLowerWide(hex_lcid) == L"804") return "zh-CN";
  if (ToLowerWide(hex_lcid) == L"409") return "en-US";
  return WideToUtf8(hex_lcid);
}

struct VoiceEntry {
  std::string id;
  std::string name;
  std::string language;
};

std::vector<VoiceEntry> EnumerateSapiVoices() {
  std::vector<VoiceEntry> list;
  const wchar_t* roots[] = {
      L"SOFTWARE\\Microsoft\\Speech\\Voices\\Tokens",
      L"SOFTWARE\\Microsoft\\Speech_OneCore\\Voices\\Tokens",
  };
  for (const wchar_t* root_subkey : roots) {
    HKEY tokens_key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, root_subkey, 0, KEY_READ,
                      &tokens_key) != ERROR_SUCCESS) {
      continue;
    }
    DWORD index = 0;
    wchar_t subkey_name[256]{};
    DWORD subkey_len = 256;
    while (RegEnumKeyExW(tokens_key, index++, subkey_name, &subkey_len, nullptr,
                         nullptr, nullptr, nullptr) == ERROR_SUCCESS) {
      HKEY voice_key = nullptr;
      if (RegOpenKeyExW(tokens_key, subkey_name, 0, KEY_READ, &voice_key) ==
          ERROR_SUCCESS) {
        std::wstring desc = ReadRegString(voice_key, nullptr);
        std::wstring lang_hex;
        HKEY attrs_key = nullptr;
        if (RegOpenKeyExW(voice_key, L"Attributes", 0, KEY_READ, &attrs_key) ==
            ERROR_SUCCESS) {
          const std::wstring attr_name = ReadRegString(attrs_key, L"Name");
          if (!attr_name.empty()) desc = attr_name;
          lang_hex = ReadRegString(attrs_key, L"Language");
          RegCloseKey(attrs_key);
        }
        RegCloseKey(voice_key);
        const std::string id = WideToUtf8(subkey_name);
        if (!id.empty() &&
            std::none_of(list.begin(), list.end(),
                         [&](const VoiceEntry& e) { return e.id == id; })) {
          list.push_back(VoiceEntry{
              id,
              WideToUtf8(desc.empty() ? std::wstring(subkey_name) : desc),
              lang_hex.empty() ? "zh-CN" : LcidHexToTag(lang_hex),
          });
        }
      }
      subkey_len = 256;
      if (list.size() >= 500) break;
    }
    RegCloseKey(tokens_key);
    if (list.size() >= 500) break;
  }
  return list;
}

}  // namespace

ReaderPlayback::ReaderPlayback(PostMainCallback post_main, EmitCallback emit)
    : post_main_(std::move(post_main)), emit_(std::move(emit)) {
  speech_stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

ReaderPlayback::~ReaderPlayback() {
  Release();
  if (speech_stop_event_ != nullptr) {
    CloseHandle(speech_stop_event_);
    speech_stop_event_ = nullptr;
  }
}

bool ReaderPlayback::HasOutputDevice() { return waveOutGetNumDevs() > 0; }

bool ReaderPlayback::NativeSpeechAvailable() {
  return !EnumerateSapiVoices().empty();
}

flutter::EncodableList ReaderPlayback::Voices() {
  flutter::EncodableList out;
  for (const auto& voice : EnumerateSapiVoices()) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("id")] = flutter::EncodableValue(voice.id);
    map[flutter::EncodableValue("name")] = flutter::EncodableValue(voice.name);
    map[flutter::EncodableValue("language")] =
        flutter::EncodableValue(voice.language);
    map[flutter::EncodableValue("quality")] = flutter::EncodableValue(1);
    out.push_back(flutter::EncodableValue(map));
  }
  return out;
}

bool ReaderPlayback::WriteSecret(const std::string& value,
                                 std::string* error_out) {
  if (value.size() > kMaxSecretBytes) {
    if (error_out) *error_out = "密钥长度超过限制";
    return false;
  }
  const std::filesystem::path target = SecretFilePath();
  std::error_code ec;
  if (value.empty()) {
    std::filesystem::remove(target, ec);
    return true;
  }
  std::filesystem::create_directories(target.parent_path(), ec);
  DATA_BLOB input{};
  input.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(value.data()));
  input.cbData = static_cast<DWORD>(value.size());
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"FanqieReaderTTS", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    if (error_out) *error_out = "密钥未写入系统安全存储";
    return false;
  }
  const std::filesystem::path pending =
      target.parent_path() / L"tts_secret.pending";
  HANDLE file = CreateFileW(pending.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    LocalFree(output.pbData);
    if (error_out) *error_out = "无法创建安全存储文件";
    return false;
  }
  DWORD written = 0;
  const bool ok =
      WriteFile(file, output.pbData, output.cbData, &written, nullptr) != 0 &&
      written == output.cbData;
  FlushFileBuffers(file);
  CloseHandle(file);
  LocalFree(output.pbData);
  if (!ok ||
      !MoveFileExW(pending.c_str(), target.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    std::filesystem::remove(pending, ec);
    if (error_out) *error_out = "密钥未写入系统安全存储";
    return false;
  }
  return true;
}

bool ReaderPlayback::ReadSecret(std::optional<std::string>* value_out,
                                std::string* error_out) {
  const std::filesystem::path target = SecretFilePath();
  const DWORD attrs = GetFileAttributesW(target.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    *value_out = std::nullopt;
    return true;
  }
  HANDLE file = CreateFileW(
      target.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    if (error_out) *error_out = "无法读取系统安全存储；未改写原密钥";
    return false;
  }
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 64 * 1024) {
    CloseHandle(file);
    if (error_out) *error_out = "无法读取系统安全存储；未改写原密钥";
    return false;
  }
  std::vector<BYTE> encrypted(static_cast<size_t>(size.QuadPart));
  DWORD read_bytes = 0;
  const bool read_ok = ReadFile(file, encrypted.data(),
                                static_cast<DWORD>(encrypted.size()),
                                &read_bytes, nullptr) != 0 &&
                       read_bytes == encrypted.size();
  CloseHandle(file);
  if (!read_ok) {
    if (error_out) *error_out = "无法读取系统安全存储；未改写原密钥";
    return false;
  }
  DATA_BLOB input{};
  input.pbData = encrypted.data();
  input.cbData = static_cast<DWORD>(encrypted.size());
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    if (error_out) *error_out = "无法读取系统安全存储；未改写原密钥";
    return false;
  }
  std::string secret(reinterpret_cast<const char*>(output.pbData),
                     output.cbData);
  LocalFree(output.pbData);
  if (secret.size() > kMaxSecretBytes) {
    if (error_out) *error_out = "无法读取系统安全存储；未改写原密钥";
    return false;
  }
  *value_out = std::move(secret);
  return true;
}

bool ReaderPlayback::ValidateAudioFile(const std::wstring& raw_path) const {
  if (raw_path.empty()) return false;
  const std::filesystem::path path(raw_path);
  const std::string filename = WideToUtf8(path.filename().wstring());
  static const std::regex kPattern(
      "^tts_[0-9]+-[0-9]+-[0-9]+-[0-9]+\\.(mp3|wav)$", std::regex::icase);
  if (!std::regex_match(filename, kPattern)) return false;

  const DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES ||
      (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }

  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info{};
  LARGE_INTEGER size{};
  const bool valid_handle =
      GetFileInformationByHandle(handle, &info) != 0 &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
      GetFileSizeEx(handle, &size) != 0 && size.QuadPart > 12 &&
      static_cast<uint64_t>(size.QuadPart) <= kMaxAudioBytes;
  CloseHandle(handle);
  if (!valid_handle) return false;

  std::error_code ec;
  const std::wstring canonical_file =
      ToLowerWide(std::filesystem::weakly_canonical(path, ec).wstring());
  if (ec) return false;
  for (const auto& root : AllowedAudioRoots()) {
    std::wstring canonical_root = ToLowerWide(root.wstring());
    if (!canonical_root.empty() && canonical_root.back() != L'\\') {
      canonical_root.push_back(L'\\');
    }
    if (canonical_file.rfind(canonical_root, 0) == 0) {
      return true;
    }
  }
  return false;
}

void ReaderPlayback::CloseMci() {
  if (mci_open_) {
    mciSendStringW(L"stop fanqie_tts", nullptr, 0, nullptr);
    mciSendStringW(L"close fanqie_tts", nullptr, 0, nullptr);
    mci_open_ = false;
  }
}

int64_t ReaderPlayback::QueryMciPositionMs() const {
  if (!mci_open_) return 0;
  wchar_t buffer[64]{};
  if (mciSendStringW(L"status fanqie_tts position", buffer, 64, nullptr) != 0) {
    return 0;
  }
  try {
    return std::stoll(buffer);
  } catch (...) {
    return 0;
  }
}

bool ReaderPlayback::IsMciPlaying() const {
  if (!mci_open_) return false;
  wchar_t buffer[64]{};
  if (mciSendStringW(L"status fanqie_tts mode", buffer, 64, nullptr) != 0) {
    return false;
  }
  return ToLowerWide(buffer) == L"playing";
}

bool ReaderPlayback::Speak(const std::string& id, const std::string& text,
                           double rate, const std::string& voice_id) {
  const std::wstring wide_text = Utf8ToWide(text);
  bool non_whitespace = false;
  for (wchar_t ch : wide_text) {
    if (!std::iswspace(ch)) {
      non_whitespace = true;
      break;
    }
  }
  if (id.empty() || id.size() > 512 || !non_whitespace ||
      wide_text.size() > 4096 || !std::isfinite(rate) || !HasOutputDevice() ||
      !NativeSpeechAvailable()) {
    return false;
  }

  Stop();
  uint64_t generation = 0;
  double current_volume = 1.0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_id_ = id;
    generation = ++token_generation_;
    native_ = true;
    paused_ = false;
    current_volume = volume_;
    if (speech_stop_event_ != nullptr) {
      ResetEvent(speech_stop_event_);
    }
  }

  const auto self = shared_from_this();
  const HANDLE stop_event = speech_stop_event_;
  std::thread([self, id, wide_text, rate, current_volume, generation,
               stop_event] {
    const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool completed = false;
    {
      Microsoft::WRL::ComPtr<ISpVoice> voice;
      if (SUCCEEDED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
                                     IID_PPV_ARGS(&voice))) &&
          voice != nullptr) {
        voice->SetVolume(
            static_cast<USHORT>(std::clamp(current_volume * 100.0, 0.0, 100.0)));
        const long sapi_rate = static_cast<long>(
            std::clamp(std::round((rate - 1.0) * 6.0), -10.0, 10.0));
        voice->SetRate(sapi_rate);
        if (SUCCEEDED(voice->Speak(wide_text.c_str(),
                                   SPF_ASYNC | SPF_IS_NOT_XML, nullptr))) {
          HANDLE complete_event = voice->SpeakCompleteEvent();
          HANDLE handles[2] = {complete_event, stop_event};
          const DWORD count = (stop_event != nullptr) ? 2 : 1;
          const DWORD waited =
              WaitForMultipleObjects(count, handles, FALSE, INFINITE);
          if (waited == WAIT_OBJECT_0) {
            completed = true;
          } else {
            voice->Speak(nullptr, SPF_PURGEBEFORESPEAK, nullptr);
          }
        }
      }
    }
    if (SUCCEEDED(co_hr)) {
      CoUninitialize();
    }
    self->post_main_([self, id, generation, completed] {
      bool should_emit = false;
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        if (self->token_generation_ == generation && self->current_id_ == id) {
          self->current_id_.clear();
          self->native_ = false;
          self->paused_ = false;
          should_emit = true;
        }
      }
      if (should_emit) {
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
        self->emit_(completed ? "onTtsComplete" : "onTtsError", payload);
      }
    });
  }).detach();
  return true;
}

bool ReaderPlayback::Play(const std::string& id, const std::string& file_path) {
  const std::wstring wide_path = Utf8ToWide(file_path);
  if (id.empty() || id.size() > 512 || !ValidateAudioFile(wide_path) ||
      !HasOutputDevice()) {
    return false;
  }

  Stop();
  const std::wstring open_cmd = L"open \"" + wide_path + L"\" alias fanqie_tts";
  if (mciSendStringW(open_cmd.c_str(), nullptr, 0, nullptr) != 0) {
    return false;
  }
  mci_open_ = true;
  mciSendStringW(L"set fanqie_tts time format milliseconds", nullptr, 0,
                 nullptr);
  wchar_t len_buf[64]{};
  int64_t duration_ms = 0;
  if (mciSendStringW(L"status fanqie_tts length", len_buf, 64, nullptr) == 0) {
    try {
      duration_ms = std::stoll(len_buf);
    } catch (...) {
      duration_ms = 0;
    }
  }
  if (duration_ms <= 0 || duration_ms > 1800 * 1000) {
    CloseMci();
    return false;
  }

  const int mci_vol =
      static_cast<int>(std::clamp(std::round(volume_ * 1000.0), 0.0, 1000.0));
  const std::wstring vol_cmd =
      L"setaudio fanqie_tts volume to " + std::to_wstring(mci_vol);
  mciSendStringW(vol_cmd.c_str(), nullptr, 0, nullptr);

  if (mciSendStringW(L"play fanqie_tts", nullptr, 0, nullptr) != 0) {
    CloseMci();
    return false;
  }

  uint64_t generation = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_id_ = id;
    generation = ++token_generation_;
    native_ = false;
    paused_ = false;
  }

  const auto self = shared_from_this();
  std::thread([self, id, generation] {
    for (;;) {
      std::this_thread::sleep_for(std::chrono::milliseconds(60));
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        if (self->token_generation_ != generation || self->current_id_ != id) {
          return;
        }
      }
      std::promise<bool> done_promise;
      auto done_future = done_promise.get_future();
      self->post_main_([self, id, generation, &done_promise] {
        bool active = false;
        bool is_paused = false;
        {
          std::lock_guard<std::mutex> lock(self->mutex_);
          active =
              self->token_generation_ == generation && self->current_id_ == id;
          is_paused = self->paused_;
        }
        if (!active) {
          done_promise.set_value(true);
          return;
        }
        if (is_paused) {
          done_promise.set_value(false);
          return;
        }
        wchar_t mode_buf[64]{};
        if (mciSendStringW(L"status fanqie_tts mode", mode_buf, 64, nullptr) !=
            0) {
          self->CloseMci();
          {
            std::lock_guard<std::mutex> lock(self->mutex_);
            self->current_id_.clear();
          }
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
          self->emit_("onAudioError", payload);
          done_promise.set_value(true);
          return;
        }
        const std::wstring mode = ToLowerWide(mode_buf);
        if (mode == L"stopped") {
          self->CloseMci();
          {
            std::lock_guard<std::mutex> lock(self->mutex_);
            self->current_id_.clear();
          }
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
          self->emit_("onAudioComplete", payload);
          done_promise.set_value(true);
          return;
        }
        done_promise.set_value(false);
      });
      if (done_future.wait_for(std::chrono::seconds(2)) !=
              std::future_status::ready ||
          done_future.get()) {
        return;
      }
    }
  }).detach();

  return true;
}

bool ReaderPlayback::Stop(const std::optional<std::string>& id) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (id.has_value() && !id->empty() && current_id_ != *id) {
      return false;
    }
    current_id_.clear();
    ++token_generation_;
    native_ = false;
    paused_ = false;
    if (speech_stop_event_ != nullptr) {
      SetEvent(speech_stop_event_);
    }
  }
  CloseMci();
  return true;
}

bool ReaderPlayback::StopNative() {
  bool is_native = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    is_native = native_;
  }
  return is_native ? Stop() : true;
}

bool ReaderPlayback::StopAudio() {
  bool is_native = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    is_native = native_;
  }
  return is_native ? true : Stop();
}

bool ReaderPlayback::PauseAudio(const std::optional<std::string>& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (native_ || current_id_.empty() || !mci_open_ ||
      (id.has_value() && !id->empty() && *id != current_id_)) {
    return false;
  }
  if (mciSendStringW(L"pause fanqie_tts", nullptr, 0, nullptr) != 0) {
    return false;
  }
  paused_ = true;
  return true;
}

bool ReaderPlayback::ResumeAudio(const std::optional<std::string>& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (native_ || current_id_.empty() || !mci_open_ ||
      (id.has_value() && !id->empty() && *id != current_id_)) {
    return false;
  }
  if (mciSendStringW(L"resume fanqie_tts", nullptr, 0, nullptr) != 0) {
    return false;
  }
  paused_ = false;
  return true;
}

bool ReaderPlayback::SetVolume(double value) {
  if (!std::isfinite(value) || value < 0.0 || value > 1.0) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  volume_ = value;
  if (mci_open_) {
    const int mci_vol =
        static_cast<int>(std::clamp(std::round(volume_ * 1000.0), 0.0, 1000.0));
    const std::wstring vol_cmd =
        L"setaudio fanqie_tts volume to " + std::to_wstring(mci_vol);
    mciSendStringW(vol_cmd.c_str(), nullptr, 0, nullptr);
  }
  return true;
}

bool ReaderPlayback::SetDeadline(int64_t milliseconds) {
  if (milliseconds < 0) return false;
  uint64_t sleep_gen = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sleep_deadline_ = milliseconds;
    sleep_gen = ++sleep_generation_;
  }
  if (milliseconds == 0) return true;
  const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::system_clock::now().time_since_epoch())
                          .count();
  const int64_t delay_ms = std::max<int64_t>(0, milliseconds - now_ms);
  if (delay_ms > (86400LL + 1LL) * 1000LL) {
    std::lock_guard<std::mutex> lock(mutex_);
    sleep_deadline_ = 0;
    return false;
  }
  const auto self = shared_from_this();
  std::thread([self, milliseconds, delay_ms, sleep_gen] {
    std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
    self->post_main_([self, milliseconds, sleep_gen] {
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        if (self->sleep_generation_ != sleep_gen ||
            self->sleep_deadline_ != milliseconds) {
          return;
        }
        self->sleep_deadline_ = 0;
      }
      self->Stop();
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("deadline")] =
          flutter::EncodableValue(milliseconds);
      self->emit_("onAudioSleepTimer", payload);
    });
  }).detach();
  return true;
}

flutter::EncodableMap ReaderPlayback::PlaybackState() {
  std::lock_guard<std::mutex> lock(mutex_);
  const bool playing =
      !current_id_.empty() && !paused_ && (native_ ? true : IsMciPlaying());
  flutter::EncodableMap state;
  state[flutter::EncodableValue("id")] =
      current_id_.empty() ? flutter::EncodableValue()
                          : flutter::EncodableValue(current_id_);
  state[flutter::EncodableValue("playing")] = flutter::EncodableValue(playing);
  state[flutter::EncodableValue("native")] = flutter::EncodableValue(native_);
  state[flutter::EncodableValue("paused")] = flutter::EncodableValue(paused_);
  state[flutter::EncodableValue("volume")] = flutter::EncodableValue(volume_);
  state[flutter::EncodableValue("deadline")] =
      flutter::EncodableValue(sleep_deadline_);
  state[flutter::EncodableValue("position_ms")] =
      flutter::EncodableValue(native_ ? 0LL : QueryMciPositionMs());
  return state;
}

void ReaderPlayback::UpdateMedia(const std::string& title,
                                 const std::string& subtitle, bool playing,
                                 bool active) {
  (void)title;
  (void)subtitle;
  std::lock_guard<std::mutex> lock(mutex_);
  media_active_ = active;
  media_playing_ = active && playing;
}

void ReaderPlayback::Release() {
  Stop();
  SetDeadline(0);
  UpdateMedia("", "", false, false);
}

bool ReaderPlayback::HandleAppCommand(LPARAM lparam) {
  bool active = false;
  bool playing = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active = media_active_;
    playing = media_playing_;
  }
  if (!active) return false;
  const short cmd = GET_APPCOMMAND_LPARAM(lparam);
  const char* method = nullptr;
  switch (cmd) {
    case APPCOMMAND_MEDIA_PLAY:
      if (!playing) method = "onMediaPlay";
      break;
    case APPCOMMAND_MEDIA_PAUSE:
      if (playing) method = "onMediaPause";
      break;
    case APPCOMMAND_MEDIA_PLAY_PAUSE:
      method = playing ? "onMediaPause" : "onMediaPlay";
      break;
    case APPCOMMAND_MEDIA_NEXTTRACK:
      method = "onMediaNext";
      break;
    case APPCOMMAND_MEDIA_PREVIOUSTRACK:
      method = "onMediaPrev";
      break;
    case APPCOMMAND_MEDIA_STOP:
      method = "onMediaStop";
      break;
    default:
      break;
  }
  if (method == nullptr) return false;
  emit_(method, flutter::EncodableMap());
  return true;
}
