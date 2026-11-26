#include "reader_playback.h"

#include <ShlObj.h>
#include <audioclient.h>
#include <bcrypt.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmsystem.h>
#include <oleauto.h>
#include <sapi.h>
#include <shlwapi.h>
#include <wincrypt.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cwctype>
#include <filesystem>
#include <regex>
#include <thread>

namespace {

constexpr uint64_t kMaxAudioBytes = 16ULL * 1024ULL * 1024ULL;
constexpr size_t kMaxSecretBytes = 8192;
constexpr size_t kMaxSecretKeyBytes = 256;

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

// 使用 Windows CNG 计算 SHA-256 十六进制字符串，用于安全映射命名密钥槽位。
bool ComputeSha256Hex(const std::string& input, std::wstring* hex_out) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) !=
      0) {
    return false;
  }
  DWORD obj_len = 0;
  DWORD data_len = 0;
  if (BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&obj_len), sizeof(obj_len),
                        &data_len, 0) != 0) {
    BCryptCloseAlgorithmProvider(alg, 0);
    return false;
  }
  std::vector<UCHAR> hash_obj(obj_len);
  UCHAR digest[32]{};
  bool ok = false;
  if (BCryptCreateHash(alg, &hash, hash_obj.data(), obj_len, nullptr, 0, 0) ==
      0) {
    if (BCryptHashData(
            hash, reinterpret_cast<PUCHAR>(const_cast<char*>(input.data())),
            static_cast<ULONG>(input.size()), 0) == 0 &&
        BCryptFinishHash(hash, digest, sizeof(digest), 0) == 0) {
      static constexpr wchar_t kHex[] = L"0123456789abcdef";
      std::wstring out;
      out.reserve(64);
      for (UCHAR b : digest) {
        out.push_back(kHex[(b >> 4) & 0x0F]);
        out.push_back(kHex[b & 0x0F]);
      }
      *hex_out = std::move(out);
      ok = true;
    }
    BCryptDestroyHash(hash);
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

std::filesystem::path LocalAppDataRoot() {
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
  return base / L"com.fanqie" / L"FanqieReader";
}

std::filesystem::path SecretFilePath() {
  return LocalAppDataRoot() / L"tts_secret.dpapi";
}

bool WriteDpapiFile(const std::filesystem::path& target,
                    const std::string& value, std::string* error_out) {
  if (value.size() > kMaxSecretBytes) {
    if (error_out) *error_out = "密钥长度超过限制";
    return false;
  }
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
      target.parent_path() / (target.filename().wstring() + L".pending");
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

bool ReadDpapiFile(const std::filesystem::path& target,
                   std::optional<std::string>* value_out,
                   std::string* error_out) {
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

// 放行临时目录、LocalAppData 与 RoamingAppData（沉浸式音频缓存落于 AppData\Roaming）。
std::vector<std::filesystem::path> AllowedAudioRoots() {
  std::vector<std::filesystem::path> roots;
  wchar_t temp[MAX_PATH + 1]{};
  if (GetTempPathW(MAX_PATH, temp) > 0) {
    std::error_code ec;
    roots.push_back(std::filesystem::weakly_canonical(temp, ec));
  }
  const KNOWNFOLDERID folders[] = {
      FOLDERID_LocalAppData,
      FOLDERID_RoamingAppData,
  };
  for (const auto& fid : folders) {
    PWSTR raw = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(fid, 0, nullptr, &raw)) &&
        raw != nullptr) {
      std::error_code ec;
      roots.push_back(std::filesystem::weakly_canonical(raw, ec));
      CoTaskMemFree(raw);
    }
  }
  return roots;
}

// 魔数校验音频容器格式（支持 RIFF/WAVE 与 ID3/MP3 帧同步头）。
bool DetectAudioContainer(const std::vector<uint8_t>& bytes, bool* is_wav_out) {
  if (bytes.size() < 12) return false;
  if (bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' &&
      bytes[3] == 'F' && bytes[8] == 'W' && bytes[9] == 'A' &&
      bytes[10] == 'V' && bytes[11] == 'E') {
    *is_wav_out = true;
    return true;
  }
  if (bytes[0] == 'I' && bytes[1] == 'D' && bytes[2] == '3') {
    *is_wav_out = false;
    return true;
  }
  const size_t scan_limit = std::min<size_t>(bytes.size() - 4, 4096);
  for (size_t i = 0; i <= scan_limit; ++i) {
    if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
      const uint8_t version = (bytes[i + 1] >> 3) & 0x03;
      const uint8_t layer = (bytes[i + 1] >> 1) & 0x03;
      const uint8_t bitrate = (bytes[i + 2] >> 4) & 0x0F;
      const uint8_t sample_rate = (bytes[i + 2] >> 2) & 0x03;
      if (version != 1 && layer != 0 && bitrate != 0 && bitrate != 15 &&
          sample_rate != 3) {
        *is_wav_out = false;
        return true;
      }
    }
  }
  return false;
}

// 从内存字节创建附带 MIME 类型和虚拟文件名的 IMFByteStream（不占用磁盘句柄）。
bool CreateMemoryByteStream(const std::vector<uint8_t>& bytes, bool is_wav,
                            Microsoft::WRL::ComPtr<IMFByteStream>* stream_out) {
  if (bytes.empty() || bytes.size() > kMaxAudioBytes) return false;
  IStream* raw_mem = SHCreateMemStream(bytes.data(),
                                       static_cast<UINT>(bytes.size()));
  if (raw_mem == nullptr) return false;
  Microsoft::WRL::ComPtr<IStream> mem_stream;
  mem_stream.Attach(raw_mem);
  Microsoft::WRL::ComPtr<IMFByteStream> byte_stream;
  if (FAILED(MFCreateMFByteStreamOnStream(mem_stream.Get(), &byte_stream)) ||
      byte_stream == nullptr) {
    return false;
  }
  Microsoft::WRL::ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(byte_stream.As(&attrs)) && attrs != nullptr) {
    attrs->SetString(MF_BYTESTREAM_CONTENT_TYPE,
                     is_wav ? L"audio/wav" : L"audio/mpeg");
    attrs->SetString(MF_BYTESTREAM_ORIGIN_NAME,
                     is_wav ? L"audio.wav" : L"audio.mp3");
  }
  *stream_out = std::move(byte_stream);
  return true;
}

// 线程安全的 IMFMediaEngine 事件接收器，始终通过 post_main 回到主线程。
class MediaEngineNotify final : public IMFMediaEngineNotify {
 public:
  MediaEngineNotify(std::weak_ptr<ReaderPlayback> owner,
                    ReaderPlayback::PostMainCallback post_main,
                    uint64_t slot_id)
      : owner_(std::move(owner)),
        post_main_(std::move(post_main)),
        slot_id_(slot_id) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv_object) override {
    if (ppv_object == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFMediaEngineNotify)) {
      *ppv_object = static_cast<IMFMediaEngineNotify*>(this);
      AddRef();
      return S_OK;
    }
    *ppv_object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (count == 0) delete this;
    return count;
  }

  HRESULT STDMETHODCALLTYPE EventNotify(DWORD event, DWORD_PTR param1,
                                        DWORD param2) override {
    auto weak = owner_;
    const uint64_t sid = slot_id_;
    post_main_([weak, sid, event, param1, param2] {
      if (auto locked = weak.lock()) {
        locked->OnEngineEventMain(sid, event, param1, param2);
      }
    });
    return S_OK;
  }

 private:
  std::atomic<long> ref_count_{1};
  std::weak_ptr<ReaderPlayback> owner_;
  ReaderPlayback::PostMainCallback post_main_;
  uint64_t slot_id_;
};

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
  if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) {
    mf_started_ = true;
  }
}

ReaderPlayback::~ReaderPlayback() {
  Release();
  if (mf_started_) {
    MFShutdown();
    mf_started_ = false;
  }
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

bool ReaderPlayback::IsValidSecretKey(const std::string& key) {
  return !key.empty() && key.size() <= kMaxSecretKeyBytes &&
         key.find('\0') == std::string::npos;
}

bool ReaderPlayback::WriteSecret(const std::string& value,
                                 std::string* error_out) {
  return WriteDpapiFile(SecretFilePath(), value, error_out);
}

bool ReaderPlayback::ReadSecret(std::optional<std::string>* value_out,
                                std::string* error_out) {
  return ReadDpapiFile(SecretFilePath(), value_out, error_out);
}

bool ReaderPlayback::WriteNamedSecret(const std::string& key,
                                      const std::string& value,
                                      std::string* error_out) {
  if (!IsValidSecretKey(key)) {
    if (error_out) *error_out = "无效的安全存储槽位名称";
    return false;
  }
  std::wstring hash_hex;
  if (!ComputeSha256Hex(key, &hash_hex)) {
    if (error_out) *error_out = "无法计算安全存储槽位标识";
    return false;
  }
  const std::filesystem::path target =
      LocalAppDataRoot() / L"secrets" / (hash_hex + L".dpapi");
  return WriteDpapiFile(target, value, error_out);
}

bool ReaderPlayback::ReadNamedSecret(const std::string& key,
                                     std::optional<std::string>* value_out,
                                     std::string* error_out) {
  if (!IsValidSecretKey(key)) {
    *value_out = std::nullopt;
    return true;
  }
  std::wstring hash_hex;
  if (!ComputeSha256Hex(key, &hash_hex)) {
    if (error_out) *error_out = "无法计算安全存储槽位标识";
    return false;
  }
  const std::filesystem::path target =
      LocalAppDataRoot() / L"secrets" / (hash_hex + L".dpapi");
  return ReadDpapiFile(target, value_out, error_out);
}

bool ReaderPlayback::ReadAudioBytes(const std::wstring& path,
                                    std::vector<uint8_t>* bytes_out,
                                    bool* is_wav_out) {
  if (path.empty()) return false;
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
  const bool valid_meta =
      GetFileInformationByHandle(handle, &info) != 0 &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
      GetFileSizeEx(handle, &size) != 0 && size.QuadPart > 12 &&
      static_cast<uint64_t>(size.QuadPart) <= kMaxAudioBytes;
  if (!valid_meta) {
    CloseHandle(handle);
    return false;
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(size.QuadPart));
  DWORD total_read = 0;
  while (total_read < bytes.size()) {
    DWORD chunk = 0;
    if (!ReadFile(handle, bytes.data() + total_read,
                  static_cast<DWORD>(bytes.size() - total_read), &chunk,
                  nullptr) ||
        chunk == 0) {
      CloseHandle(handle);
      return false;
    }
    total_read += chunk;
  }
  CloseHandle(handle);

  bool is_wav = false;
  if (!DetectAudioContainer(bytes, &is_wav)) {
    return false;
  }
  *bytes_out = std::move(bytes);
  *is_wav_out = is_wav;
  return true;
}

flutter::EncodableMap ReaderPlayback::ProbeAudioDuration(
    const std::string& file_path) {
  auto invalid = []() {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("valid")] = flutter::EncodableValue(false);
    map[flutter::EncodableValue("durationMs")] = flutter::EncodableValue(0LL);
    return map;
  };
  const std::wstring wide_path = Utf8ToWide(file_path);
  std::vector<uint8_t> bytes;
  bool is_wav = false;
  if (!ReadAudioBytes(wide_path, &bytes, &is_wav)) {
    return invalid();
  }

  const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT mf_hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  int64_t duration_ms = 0;
  bool decoded_sample = false;

  if (SUCCEEDED(mf_hr)) {
    {
      Microsoft::WRL::ComPtr<IMFByteStream> byte_stream;
      Microsoft::WRL::ComPtr<IMFSourceReader> reader;
      if (CreateMemoryByteStream(bytes, is_wav, &byte_stream) &&
          SUCCEEDED(MFCreateSourceReaderFromByteStream(
              byte_stream.Get(), nullptr, &reader)) &&
          reader != nullptr) {
        // 强制输出 PCM 解码以验证音频内容真实完整而非伪造文件头。
        Microsoft::WRL::ComPtr<IMFMediaType> pcm_type;
        if (SUCCEEDED(MFCreateMediaType(&pcm_type)) &&
            SUCCEEDED(pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio)) &&
            SUCCEEDED(pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM)) &&
            SUCCEEDED(reader->SetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                nullptr, pcm_type.Get()))) {
          PROPVARIANT var{};
          PropVariantInit(&var);
          if (SUCCEEDED(reader->GetPresentationAttribute(
                  static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
                  MF_PD_DURATION, &var))) {
            if (var.vt == VT_UI8 && var.uhVal.QuadPart > 0) {
              duration_ms = static_cast<int64_t>(
                  std::llround(static_cast<double>(var.uhVal.QuadPart) / 10000.0));
            } else if (var.vt == VT_I8 && var.hVal.QuadPart > 0) {
              duration_ms = static_cast<int64_t>(
                  std::llround(static_cast<double>(var.hVal.QuadPart) / 10000.0));
            }
          }
          PropVariantClear(&var);

          // 若容器未提供总时长元数据则全量扫描样本累计时长，否则只需成功解码首包。
          const bool need_full_scan = duration_ms <= 0;
          LONGLONG accumulated_hns = 0;
          for (int i = 0; i < (need_full_scan ? 200000 : 32); ++i) {
            DWORD stream_index = 0;
            DWORD flags = 0;
            LONGLONG timestamp = 0;
            Microsoft::WRL::ComPtr<IMFSample> sample;
            const HRESULT rhr = reader->ReadSample(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
                &stream_index, &flags, &timestamp, &sample);
            if (FAILED(rhr)) {
              decoded_sample = false;
              break;
            }
            if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
              break;
            }
            if (sample != nullptr) {
              DWORD total_len = 0;
              if (SUCCEEDED(sample->GetTotalLength(&total_len)) &&
                  total_len > 0) {
                decoded_sample = true;
              }
              LONGLONG sample_dur = 0;
              if (SUCCEEDED(sample->GetSampleDuration(&sample_dur)) &&
                  sample_dur > 0) {
                accumulated_hns += sample_dur;
              }
              if (!need_full_scan && decoded_sample) {
                break;
              }
            }
          }
          if (need_full_scan && accumulated_hns > 0) {
            duration_ms = static_cast<int64_t>(
                std::llround(static_cast<double>(accumulated_hns) / 10000.0));
          }
        }
      }
    }
    MFShutdown();
  }
  if (SUCCEEDED(co_hr)) {
    CoUninitialize();
  }

  if (!decoded_sample || duration_ms <= 0 || duration_ms > 3600LL * 1000LL) {
    return invalid();
  }

  flutter::EncodableMap map;
  map[flutter::EncodableValue("valid")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("durationMs")] =
      flutter::EncodableValue(std::max<int64_t>(1, duration_ms));
  map[flutter::EncodableValue("mime")] =
      flutter::EncodableValue(is_wav ? "audio/wav" : "audio/mpeg");
  return map;
}

flutter::EncodableMap ReaderPlayback::SynthesizeNativeTtsToFile(
    const std::string& text, double rate, const std::string& voice_id,
    const std::string& output_path) {
  auto fail = [](const std::string& msg) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
    map[flutter::EncodableValue("error")] = flutter::EncodableValue(msg);
    return map;
  };
  if (text.empty() || output_path.empty()) {
    return fail("待合成文本或输出路径为空");
  }
  const std::wstring wide_text = Utf8ToWide(text);
  const std::wstring wide_path = Utf8ToWide(output_path);
  if (wide_text.empty() || wide_path.empty()) {
    return fail("文本或路径编码无效");
  }

  std::error_code ec;
  const std::filesystem::path target(wide_path);
  if (target.has_parent_path()) {
    std::filesystem::create_directories(target.parent_path(), ec);
  }
  std::filesystem::remove(target, ec);

  static const GUID kSpdfidWaveFormatEx = {
      0xC31ADBAE,
      0x527F,
      0x4FF5,
      {0xA2, 0x30, 0xF6, 0x2B, 0xB6, 0x1F, 0xF7, 0x0C},
  };

  const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool ok = false;
  std::string err = "Windows 系统语音离线合成失败";
  {
    Microsoft::WRL::ComPtr<ISpVoice> voice;
    Microsoft::WRL::ComPtr<ISpStream> stream;
    if (SUCCEEDED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
                                   IID_PPV_ARGS(&voice))) &&
        voice != nullptr &&
        SUCCEEDED(CoCreateInstance(CLSID_SpStream, nullptr, CLSCTX_ALL,
                                   IID_PPV_ARGS(&stream))) &&
        stream != nullptr) {
      WAVEFORMATEX wfx{};
      wfx.wFormatTag = WAVE_FORMAT_PCM;
      wfx.nChannels = 1;
      wfx.nSamplesPerSec = 22050;
      wfx.wBitsPerSample = 16;
      wfx.nBlockAlign = wfx.nChannels * (wfx.wBitsPerSample / 8);
      wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
      wfx.cbSize = 0;

      if (SUCCEEDED(stream->BindToFile(wide_path.c_str(), SPFM_CREATE_ALWAYS,
                                       &kSpdfidWaveFormatEx, &wfx, 0))) {
        const long sapi_rate = static_cast<long>(
            std::clamp(std::round((rate - 1.0) * 6.0), -10.0, 10.0));
        voice->SetRate(sapi_rate);
        voice->SetVolume(100);
        if (SUCCEEDED(voice->SetOutput(stream.Get(), TRUE)) &&
            SUCCEEDED(voice->Speak(wide_text.c_str(), SPF_IS_NOT_XML,
                                   nullptr))) {
          ok = true;
        }
        stream->Close();
      } else {
        err = "无法创建本地语音输出文件";
      }
    } else {
      err = "无法初始化 Windows SAPI 语音引擎";
    }
  }
  if (SUCCEEDED(co_hr)) {
    CoUninitialize();
  }

  if (!ok) {
    std::filesystem::remove(target, ec);
    return fail(err);
  }
  const uint64_t size = std::filesystem::file_size(target, ec);
  if (ec || size <= 44ULL) {
    std::filesystem::remove(target, ec);
    return fail("系统语音输出音频为空");
  }
  flutter::EncodableMap map;
  map[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("filePath")] =
      flutter::EncodableValue(output_path);
  return map;
}

int64_t ReaderPlayback::FreeDiskBytes(const std::string& raw_path) {
  std::string trimmed = raw_path;
  while (!trimmed.empty() &&
         std::isspace(static_cast<unsigned char>(trimmed.front()))) {
    trimmed.erase(trimmed.begin());
  }
  while (!trimmed.empty() &&
         std::isspace(static_cast<unsigned char>(trimmed.back()))) {
    trimmed.pop_back();
  }

  std::filesystem::path target;
  if (trimmed.empty()) {
    PWSTR raw = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                       &raw)) &&
        raw != nullptr) {
      target = std::filesystem::path(raw);
      CoTaskMemFree(raw);
    } else {
      wchar_t temp[MAX_PATH + 1]{};
      GetTempPathW(MAX_PATH, temp);
      target = std::filesystem::path(temp);
    }
  } else {
    target = std::filesystem::path(Utf8ToWide(trimmed));
  }

  std::error_code ec;
  while (!target.empty() && !std::filesystem::exists(target, ec)) {
    const auto parent = target.parent_path();
    if (parent == target) break;
    target = parent;
  }
  if (target.empty()) return -1;
  if (std::filesystem::is_regular_file(target, ec)) {
    target = target.parent_path();
  }
  ULARGE_INTEGER free_avail{};
  if (!GetDiskFreeSpaceExW(target.c_str(), &free_avail, nullptr, nullptr)) {
    return -1;
  }
  return static_cast<int64_t>(free_avail.QuadPart);
}

bool ReaderPlayback::ValidateAudioFile(const std::wstring& raw_path) {
  if (raw_path.empty()) return false;
  const std::filesystem::path path(raw_path);
  const std::string filename = WideToUtf8(path.filename().wstring());
  static const std::regex kPattern(
      "^(?:tts_[0-9]+-[0-9]+-[0-9]+-[0-9]+|[0-9a-f]{64}|immersive_preview_-?[0-9]+)\\.(mp3|wav)$",
      std::regex::icase);
  if (!std::regex_match(filename, kPattern)) return false;

  const DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES ||
      (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }

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

std::unique_ptr<ReaderPlayback::EngineSlot> ReaderPlayback::CreateEngineSlot(
    const std::string& token_id, const std::vector<uint8_t>& bytes, bool is_wav,
    double rate, int64_t start_position_ms) {
  if (!mf_started_) return nullptr;

  Microsoft::WRL::ComPtr<IMFMediaEngineClassFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      factory == nullptr) {
    return nullptr;
  }

  const uint64_t sid = next_slot_id_++;
  Microsoft::WRL::ComPtr<MediaEngineNotify> notify;
  notify.Attach(new MediaEngineNotify(weak_from_this(), post_main_, sid));

  Microsoft::WRL::ComPtr<IMFAttributes> attrs;
  if (FAILED(MFCreateAttributes(&attrs, 2)) || attrs == nullptr) {
    return nullptr;
  }
  attrs->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify.Get());
  attrs->SetUINT32(MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_Speech);

  Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
  if (FAILED(factory->CreateInstance(MF_MEDIA_ENGINE_AUDIOONLY, attrs.Get(),
                                     &engine)) ||
      engine == nullptr) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IMFMediaEngineEx> engine_ex;
  Microsoft::WRL::ComPtr<IMFByteStream> byte_stream;
  if (FAILED(engine.As(&engine_ex)) || engine_ex == nullptr ||
      !CreateMemoryByteStream(bytes, is_wav, &byte_stream)) {
    engine->Shutdown();
    return nullptr;
  }

  engine->SetAutoPlay(FALSE);
  engine->SetVolume(volume_);
  engine->SetDefaultPlaybackRate(rate);
  engine->SetPlaybackRate(rate);

  BSTR virtual_url = SysAllocString(is_wav ? L"audio.wav" : L"audio.mp3");
  const HRESULT src_hr =
      engine_ex->SetSourceFromByteStream(byte_stream.Get(), virtual_url);
  SysFreeString(virtual_url);
  if (FAILED(src_hr)) {
    engine->Shutdown();
    return nullptr;
  }

  auto slot = std::make_unique<EngineSlot>();
  slot->slot_id = sid;
  slot->engine = std::move(engine);
  slot->token_id = token_id;
  slot->start_position_ms = std::max<int64_t>(0, start_position_ms);
  return slot;
}

void ReaderPlayback::ShutdownSlot(std::unique_ptr<EngineSlot>* slot) {
  if (slot == nullptr || *slot == nullptr) return;
  auto owned = std::move(*slot);
  if (owned->engine != nullptr) {
    owned->engine->Pause();
    owned->engine->Shutdown();
    owned->engine.Reset();
  }
}

void ReaderPlayback::ApplyRateToSlot(const std::unique_ptr<EngineSlot>& slot,
                                     double rate) {
  if (slot == nullptr || slot->engine == nullptr) return;
  slot->engine->SetDefaultPlaybackRate(rate);
  slot->engine->SetPlaybackRate(rate);
}

void ReaderPlayback::ApplyVolumeToSlot(const std::unique_ptr<EngineSlot>& slot,
                                       double volume) {
  if (slot == nullptr || slot->engine == nullptr) return;
  slot->engine->SetVolume(volume);
}

int64_t ReaderPlayback::QueryActivePositionMs() const {
  if (active_slot_ == nullptr || active_slot_->engine == nullptr) return 0;
  const double sec = active_slot_->engine->GetCurrentTime();
  if (!std::isfinite(sec) || sec <= 0.0) return 0;
  return static_cast<int64_t>(std::llround(sec * 1000.0));
}

int64_t ReaderPlayback::QueryActiveDurationMs() const {
  if (active_slot_ == nullptr || active_slot_->engine == nullptr) return 0;
  const double sec = active_slot_->engine->GetDuration();
  if (std::isfinite(sec) && sec > 0.0 && sec <= 3600.0) {
    return static_cast<int64_t>(std::llround(sec * 1000.0));
  }
  return active_slot_->duration_hint_ms;
}

bool ReaderPlayback::IsActiveEnginePlaying() const {
  if (active_slot_ == nullptr || active_slot_->engine == nullptr) return false;
  if (paused_) return false;
  if (active_slot_->engine->IsEnded() != FALSE) return false;
  if (!active_slot_->started) {
    return active_slot_->start_requested;
  }
  return active_slot_->engine->IsPaused() == FALSE;
}

bool ReaderPlayback::Speak(const std::string& id, const std::string& text,
                           double rate, const std::string& voice_id) {
  (void)voice_id;
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

bool ReaderPlayback::Play(const std::string& id, const std::string& file_path,
                          double rate, bool preserve_pitch,
                          int64_t start_position_ms) {
  const std::wstring wide_path = Utf8ToWide(file_path);
  if (id.empty() || id.size() > 512 || !std::isfinite(rate) ||
      start_position_ms < 0 || !ValidateAudioFile(wide_path) ||
      !HasOutputDevice()) {
    return false;
  }

  std::vector<uint8_t> bytes;
  bool is_wav = false;
  if (!ReadAudioBytes(wide_path, &bytes, &is_wav)) {
    return false;
  }

  const double clamped_rate = std::clamp(rate, 0.5, 2.0);
  Stop();

  auto slot = CreateEngineSlot(id, bytes, is_wav, clamped_rate,
                               start_position_ms);
  if (slot == nullptr) {
    return false;
  }
  slot->start_requested = true;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_id_ = id;
    ++token_generation_;
    native_ = false;
    paused_ = false;
    playback_rate_ = clamped_rate;
    preserve_pitch_ = preserve_pitch;
  }
  active_slot_ = std::move(slot);
  return true;
}

bool ReaderPlayback::PreloadNext(const std::string& after_id,
                                 const std::string& id,
                                 const std::string& file_path, double rate,
                                 bool preserve_pitch, int64_t gap_ms) {
  ClearPreloaded();
  const std::wstring wide_path = Utf8ToWide(file_path);
  std::string active_id;
  bool is_native = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_id = current_id_;
    is_native = native_;
  }
  if (after_id.empty() || id.empty() || id.size() > 512 || is_native ||
      after_id != active_id || active_slot_ == nullptr || !std::isfinite(rate) ||
      !ValidateAudioFile(wide_path) || !HasOutputDevice()) {
    return false;
  }

  const int64_t clamped_gap = std::clamp<int64_t>(gap_ms, 0, 3000);
  const double clamped_rate = std::clamp(rate, 0.5, 2.0);
  const uint64_t gen = ++preload_generation_;
  next_after_id_ = after_id;
  next_gap_ms_ = clamped_gap;
  (void)preserve_pitch;

  const auto self = shared_from_this();
  std::thread([self, gen, after_id, id, wide_path, clamped_rate] {
    std::vector<uint8_t> bytes;
    bool is_wav = false;
    const bool ok = ReadAudioBytes(wide_path, &bytes, &is_wav);
    self->post_main_([self, gen, after_id, id, bytes = std::move(bytes), is_wav,
                      ok, clamped_rate] {
      std::string cur_id;
      bool is_nat = false;
      double cur_rate = clamped_rate;
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        cur_id = self->current_id_;
        is_nat = self->native_;
        cur_rate = self->playback_rate_;
      }
      if (self->preload_generation_ != gen || is_nat || cur_id != after_id ||
          self->active_slot_ == nullptr || !ok) {
        if (self->preload_generation_ == gen) {
          self->ClearPreloaded();
        }
        return;
      }
      auto slot = self->CreateEngineSlot(id, bytes, is_wav, cur_rate, 0);
      if (slot == nullptr) {
        self->ClearPreloaded();
        return;
      }
      self->next_slot_ = std::move(slot);
    });
  }).detach();
  return true;
}

void ReaderPlayback::ClearPreloaded() {
  ++preload_generation_;
  ++transition_generation_;
  ShutdownSlot(&pending_transition_slot_);
  ShutdownSlot(&next_slot_);
  next_after_id_.clear();
  next_gap_ms_ = 0;
}

bool ReaderPlayback::TryAdvanceToPreloaded(const std::string& completed_id) {
  if (next_slot_ == nullptr || !next_slot_->can_play ||
      next_after_id_ != completed_id) {
    ClearPreloaded();
    return false;
  }

  const std::string target_id = next_slot_->token_id;
  const int64_t gap = next_gap_ms_;

  // 先接管槽位所有权，防止被并发 ClearPreloaded 误释放。
  ++preload_generation_;
  const uint64_t trans_gen = ++transition_generation_;
  pending_transition_slot_ = std::move(next_slot_);
  next_after_id_.clear();
  next_gap_ms_ = 0;

  if (gap <= 0) {
    CommitTransition(trans_gen, completed_id, target_id);
    return true;
  }

  const auto self = shared_from_this();
  std::thread([self, trans_gen, completed_id, target_id, gap] {
    std::this_thread::sleep_for(std::chrono::milliseconds(gap));
    self->post_main_([self, trans_gen, completed_id, target_id] {
      self->CommitTransition(trans_gen, completed_id, target_id);
    });
  }).detach();
  return true;
}

void ReaderPlayback::CommitTransition(uint64_t transition_gen,
                                      const std::string& completed_id,
                                      const std::string& target_id) {
  if (transition_generation_ != transition_gen ||
      pending_transition_slot_ == nullptr) {
    return;
  }

  std::string cur_id;
  double cur_vol = 1.0;
  double cur_rate = 1.0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cur_id = current_id_;
    cur_vol = volume_;
    cur_rate = playback_rate_;
  }
  if (cur_id != completed_id && cur_id != target_id) {
    ShutdownSlot(&pending_transition_slot_);
    return;
  }

  auto ready = std::move(pending_transition_slot_);
  ShutdownSlot(&active_slot_);

  ApplyVolumeToSlot(ready, cur_vol);
  ApplyRateToSlot(ready, cur_rate);
  ready->start_requested = true;
  ready->started = true;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_id_ = target_id;
    native_ = false;
    paused_ = false;
  }
  active_slot_ = std::move(ready);

  if (SUCCEEDED(active_slot_->engine->Play())) {
    ApplyRateToSlot(active_slot_, cur_rate);
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("completedId")] =
        flutter::EncodableValue(completed_id);
    payload[flutter::EncodableValue("startedId")] =
        flutter::EncodableValue(target_id);
    emit_("onAudioTransition", payload);
  } else {
    ShutdownSlot(&active_slot_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      current_id_.clear();
    }
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("id")] =
        flutter::EncodableValue(completed_id);
    emit_("onAudioComplete", payload);
  }
}

void ReaderPlayback::OnEngineEventMain(uint64_t slot_id, DWORD event,
                                       DWORD_PTR param1, DWORD param2) {
  (void)param1;
  (void)param2;

  // 1. 预热槽位事件
  if (next_slot_ != nullptr && next_slot_->slot_id == slot_id) {
    if (event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA ||
        event == MF_MEDIA_ENGINE_EVENT_CANPLAY ||
        event == MF_MEDIA_ENGINE_EVENT_CANPLAYTHROUGH) {
      const double dur = next_slot_->engine->GetDuration();
      if (std::isfinite(dur) && dur > 0.0 && dur <= 1800.0) {
        next_slot_->duration_hint_ms =
            static_cast<int64_t>(std::llround(dur * 1000.0));
      }
      if (event == MF_MEDIA_ENGINE_EVENT_CANPLAY ||
          event == MF_MEDIA_ENGINE_EVENT_CANPLAYTHROUGH) {
        next_slot_->can_play = true;
      }
    } else if (event == MF_MEDIA_ENGINE_EVENT_ERROR) {
      ClearPreloaded();
    }
    return;
  }

  // 2. 当前活动槽位事件
  if (active_slot_ == nullptr || active_slot_->slot_id != slot_id) {
    return;
  }
  const std::string token_id = active_slot_->token_id;
  std::string cur_id;
  bool is_paused = false;
  double cur_vol = 1.0;
  double cur_rate = 1.0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cur_id = current_id_;
    is_paused = paused_;
    cur_vol = volume_;
    cur_rate = playback_rate_;
  }
  if (cur_id != token_id) return;

  if (event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA ||
      event == MF_MEDIA_ENGINE_EVENT_CANPLAY ||
      event == MF_MEDIA_ENGINE_EVENT_CANPLAYTHROUGH) {
    const double dur = active_slot_->engine->GetDuration();
    if (std::isfinite(dur) && dur > 0.0 && dur <= 1800.0) {
      active_slot_->duration_hint_ms =
          static_cast<int64_t>(std::llround(dur * 1000.0));
    }
    if (event == MF_MEDIA_ENGINE_EVENT_CANPLAY ||
        event == MF_MEDIA_ENGINE_EVENT_CANPLAYTHROUGH) {
      active_slot_->can_play = true;
      if (active_slot_->start_requested && !active_slot_->started &&
          !is_paused) {
        if (active_slot_->start_position_ms > 0 &&
            active_slot_->duration_hint_ms > 0 &&
            active_slot_->start_position_ms <
                active_slot_->duration_hint_ms - 100) {
          active_slot_->engine->SetCurrentTime(
              static_cast<double>(active_slot_->start_position_ms) / 1000.0);
        }
        ApplyVolumeToSlot(active_slot_, cur_vol);
        ApplyRateToSlot(active_slot_, cur_rate);
        active_slot_->started = true;
        if (FAILED(active_slot_->engine->Play())) {
          ClearPreloaded();
          ShutdownSlot(&active_slot_);
          {
            std::lock_guard<std::mutex> lock(mutex_);
            current_id_.clear();
          }
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("id")] =
              flutter::EncodableValue(token_id);
          emit_("onAudioError", payload);
          return;
        }
        ApplyRateToSlot(active_slot_, cur_rate);
      }
    }
    return;
  }

  if (event == MF_MEDIA_ENGINE_EVENT_PLAYING) {
    ApplyVolumeToSlot(active_slot_, cur_vol);
    ApplyRateToSlot(active_slot_, cur_rate);
    return;
  }

  if (event == MF_MEDIA_ENGINE_EVENT_ENDED) {
    if (TryAdvanceToPreloaded(token_id)) {
      return;
    }
    ClearPreloaded();
    ShutdownSlot(&active_slot_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      current_id_.clear();
    }
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("id")] = flutter::EncodableValue(token_id);
    emit_("onAudioComplete", payload);
    return;
  }

  if (event == MF_MEDIA_ENGINE_EVENT_ERROR) {
    ClearPreloaded();
    ShutdownSlot(&active_slot_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      current_id_.clear();
    }
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("id")] = flutter::EncodableValue(token_id);
    payload[flutter::EncodableValue("code")] =
        flutter::EncodableValue(static_cast<int64_t>(param1));
    payload[flutter::EncodableValue("hresult")] =
        flutter::EncodableValue(static_cast<int64_t>(param2));
    emit_("onAudioError", payload);
  }
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
  ClearPreloaded();
  ShutdownSlot(&active_slot_);
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
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (native_ || current_id_.empty() ||
        (id.has_value() && !id->empty() && *id != current_id_)) {
      return false;
    }
  }
  if (active_slot_ == nullptr || active_slot_->engine == nullptr) {
    return false;
  }
  ClearPreloaded();
  active_slot_->engine->Pause();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    paused_ = true;
  }
  return true;
}

bool ReaderPlayback::ResumeAudio(const std::optional<std::string>& id) {
  double cur_vol = 1.0;
  double cur_rate = 1.0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (native_ || current_id_.empty() ||
        (id.has_value() && !id->empty() && *id != current_id_)) {
      return false;
    }
    paused_ = false;
    cur_vol = volume_;
    cur_rate = playback_rate_;
  }
  if (active_slot_ == nullptr || active_slot_->engine == nullptr) {
    return false;
  }
  ApplyVolumeToSlot(active_slot_, cur_vol);
  ApplyRateToSlot(active_slot_, cur_rate);
  if (active_slot_->can_play) {
    active_slot_->started = true;
    const HRESULT hr = active_slot_->engine->Play();
    if (SUCCEEDED(hr)) {
      ApplyRateToSlot(active_slot_, cur_rate);
      return true;
    }
    return false;
  }
  active_slot_->start_requested = true;
  return true;
}

bool ReaderPlayback::SetVolume(double value) {
  if (!std::isfinite(value) || value < 0.0 || value > 1.0) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    volume_ = value;
  }
  ApplyVolumeToSlot(active_slot_, value);
  ApplyVolumeToSlot(next_slot_, value);
  ApplyVolumeToSlot(pending_transition_slot_, value);
  return true;
}

bool ReaderPlayback::SetPlaybackRate(double rate, bool preserve_pitch) {
  if (!std::isfinite(rate)) return false;
  const double clamped = std::clamp(rate, 0.5, 2.0);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    playback_rate_ = clamped;
    preserve_pitch_ = preserve_pitch;
  }
  ApplyRateToSlot(active_slot_, clamped);
  ApplyRateToSlot(next_slot_, clamped);
  ApplyRateToSlot(pending_transition_slot_, clamped);
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

flutter::EncodableMap ReaderPlayback::AudioPosition() {
  std::string cur_id;
  bool is_nat = false;
  bool is_paused = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cur_id = current_id_;
    is_nat = native_;
    is_paused = paused_;
  }
  const bool playing =
      !is_nat && !is_paused && !cur_id.empty() && IsActiveEnginePlaying();
  const int64_t pos_ms = is_nat ? 0LL : QueryActivePositionMs();
  const int64_t dur_ms = is_nat ? 0LL : QueryActiveDurationMs();
  flutter::EncodableMap out;
  out[flutter::EncodableValue("id")] =
      cur_id.empty() ? flutter::EncodableValue()
                     : flutter::EncodableValue(cur_id);
  out[flutter::EncodableValue("playing")] = flutter::EncodableValue(playing);
  out[flutter::EncodableValue("positionMs")] = flutter::EncodableValue(pos_ms);
  out[flutter::EncodableValue("durationMs")] = flutter::EncodableValue(dur_ms);
  return out;
}

flutter::EncodableMap ReaderPlayback::PlaybackState() {
  std::string cur_id;
  bool is_nat = false;
  bool is_paused = false;
  double cur_vol = 1.0;
  int64_t cur_deadline = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cur_id = current_id_;
    is_nat = native_;
    is_paused = paused_;
    cur_vol = volume_;
    cur_deadline = sleep_deadline_;
  }
  const bool playing =
      !cur_id.empty() && !is_paused && (is_nat ? true : IsActiveEnginePlaying());
  flutter::EncodableMap state;
  state[flutter::EncodableValue("id")] =
      cur_id.empty() ? flutter::EncodableValue()
                     : flutter::EncodableValue(cur_id);
  state[flutter::EncodableValue("playing")] = flutter::EncodableValue(playing);
  state[flutter::EncodableValue("native")] = flutter::EncodableValue(is_nat);
  state[flutter::EncodableValue("paused")] = flutter::EncodableValue(is_paused);
  state[flutter::EncodableValue("volume")] = flutter::EncodableValue(cur_vol);
  state[flutter::EncodableValue("deadline")] =
      flutter::EncodableValue(cur_deadline);
  state[flutter::EncodableValue("position_ms")] =
      flutter::EncodableValue(is_nat ? 0LL : QueryActivePositionMs());
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
