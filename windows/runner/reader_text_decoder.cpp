#include "reader_text_decoder.h"

#include <Windows.h>
#include <objbase.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

namespace {

constexpr size_t kMaxInputBytes = 128ull * 1024 * 1024;
constexpr size_t kChunkBytes = 64 * 1024;
// Longest multibyte character among supported encodings (GB18030).
constexpr size_t kMaxCharBytes = 4;

struct DecodeError : std::exception {
  enum class Kind { cancelled, invalidInput, invalidEncoding } kind;
  explicit DecodeError(Kind k) : kind(k) {}
};

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

// One guarded write handle for the temporary UTF-8 output.
class OutputFile {
 public:
  explicit OutputFile(const std::wstring& path)
      : handle_(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr)) {
    if (handle_ == INVALID_HANDLE_VALUE) {
      throw DecodeError(DecodeError::Kind::invalidInput);
    }
  }
  ~OutputFile() {
    if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
  }
  OutputFile(const OutputFile&) = delete;
  OutputFile& operator=(const OutputFile&) = delete;

  void Write(const uint8_t* data, size_t length) {
    while (length > 0) {
      const DWORD chunk =
          static_cast<DWORD>(std::min<size_t>(length, 1u << 20));
      DWORD written = 0;
      if (!WriteFile(handle_, data, chunk, &written, nullptr) ||
          written == 0) {
        throw DecodeError(DecodeError::Kind::invalidInput);
      }
      data += written;
      length -= written;
    }
  }
  void Flush() {
    if (!FlushFileBuffers(handle_)) {
      throw DecodeError(DecodeError::Kind::invalidInput);
    }
  }

 private:
  HANDLE handle_;
};

void EmitWide(const std::wstring& text, OutputFile* output, bool& saw_bom) {
  if (text.empty()) return;
  const wchar_t* data = text.data();
  size_t length = text.size();
  if (!saw_bom && length > 0 && data[0] == 0xfeff) {
    // A leading BOM belongs to the source encoding, not the UTF-8 output.
    ++data;
    --length;
  }
  saw_bom = true;
  if (length == 0) return;
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, data, static_cast<int>(length), nullptr,
      0, nullptr, nullptr);
  if (size <= 0) throw DecodeError(DecodeError::Kind::invalidEncoding);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data,
                      static_cast<int>(length), out.data(), size, nullptr,
                      nullptr);
  output->Write(reinterpret_cast<const uint8_t*>(out.data()), out.size());
}

// Strict chunked byte-encoding converter. MultiByteToWideChar reports no
// consumption count, so a failed conversion retries with a shorter tail; the
// retained bytes join the next chunk. At end-of-input the tail must be empty.
class ByteEncoding {
 public:
  ByteEncoding(UINT codepage, OutputFile* output)
      : codepage_(codepage), output_(output) {}

  void Push(const uint8_t* data, size_t length) {
    buffer_.insert(buffer_.end(), data, data + length);
    Convert(/*final=*/false);
  }

  void Finish() { Convert(/*final=*/true); }

 private:
  void Convert(bool final) {
    size_t consumed = 0;
    while (consumed < buffer_.size()) {
      const size_t available = buffer_.size() - consumed;
      const size_t max_hold = final ? 0 : kMaxCharBytes - 1;
      size_t best = 0;  // longest strictly-validated prefix, in bytes.
      std::wstring best_text;
      for (size_t take = available; take >= 1; --take) {
        if (available - take > max_hold) break;
        const int widened = MultiByteToWideChar(
            codepage_, MB_ERR_INVALID_CHARS,
            reinterpret_cast<const char*>(buffer_.data() + consumed),
            static_cast<int>(take), nullptr, 0);
        if (widened > 0) {
          best_text.resize(widened, L'\0');
          MultiByteToWideChar(
              codepage_, MB_ERR_INVALID_CHARS,
              reinterpret_cast<const char*>(buffer_.data() + consumed),
              static_cast<int>(take), best_text.data(), widened);
          best = take;
          break;
        }
      }
      if (best == 0) {
        if (!final && available <= max_hold) break;  // wait for more bytes.
        throw DecodeError(DecodeError::Kind::invalidEncoding);
      }
      EmitWide(best_text, output_, saw_bom_);
      consumed += best;
    }
    buffer_.erase(buffer_.begin(), buffer_.begin() + consumed);
  }

  UINT codepage_;
  OutputFile* output_;
  std::vector<uint8_t> buffer_;
  bool saw_bom_ = false;
};

// UTF-16 keeps even alignment; a surrogate pair split across chunks holds
// back its high half until the next read.
class WideEncoding {
 public:
  WideEncoding(bool big_endian, OutputFile* output)
      : big_endian_(big_endian), output_(output) {}

  void Push(const uint8_t* data, size_t length) {
    buffer_.insert(buffer_.end(), data, data + length);
    Convert(/*final=*/false);
  }

  void Finish() { Convert(/*final=*/true); }

 private:
  void Convert(bool final) {
    std::wstring units;
    while (buffer_.size() - offset_ >= 2) {
      const uint8_t b0 = buffer_[offset_];
      const uint8_t b1 = buffer_[offset_ + 1];
      const uint16_t unit =
          big_endian_ ? static_cast<uint16_t>((b0 << 8) | b1)
                      : static_cast<uint16_t>((b1 << 8) | b0);
      const bool at_tail = buffer_.size() - offset_ == 2;
      if (!final && at_tail && unit >= 0xd800 && unit <= 0xdbff) {
        break;  // high surrogate at the tail: wait for its pair.
      }
      units.push_back(static_cast<wchar_t>(unit));
      offset_ += 2;
      if (units.size() >= 4096) {
        EmitWide(units, output_, saw_bom_);
        units.clear();
      }
    }
    EmitWide(units, output_, saw_bom_);
    buffer_.erase(buffer_.begin(), buffer_.begin() + offset_);
    offset_ = 0;
    if (final && !buffer_.empty()) {
      throw DecodeError(DecodeError::Kind::invalidEncoding);
    }
  }

  bool big_endian_;
  OutputFile* output_;
  std::vector<uint8_t> buffer_;
  size_t offset_ = 0;
  bool saw_bom_ = false;
};

UINT CodepageFor(const std::string& encoding) {
  if (encoding == "UTF-8") return CP_UTF8;
  if (encoding == "GB18030") return 54936;
  if (encoding == "GBK") return 936;
  if (encoding == "Big5") return 950;
  return 0;
}

bool IsValidEncodingName(const std::string& encoding) {
  return encoding == "UTF-8" || encoding == "UTF-16LE" ||
         encoding == "UTF-16BE" || encoding == "GB18030" ||
         encoding == "GBK" || encoding == "Big5";
}

uint64_t ValidateSource(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA info{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
    throw DecodeError(DecodeError::Kind::invalidInput);
  }
  const DWORD attributes = info.dwFileAttributes;
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw DecodeError(DecodeError::Kind::invalidInput);
  }
  const uint64_t size =
      static_cast<uint64_t>(info.nFileSizeLow) |
      (static_cast<uint64_t>(info.nFileSizeHigh) << 32);
  if (size == 0 || size > kMaxInputBytes) {
    throw DecodeError(DecodeError::Kind::invalidInput);
  }
  return size;
}

std::vector<std::string> EncodingsFor(const std::string& requested,
                                      const uint8_t* header,
                                      size_t header_length) {
  if (requested != "auto") {
    if (!IsValidEncodingName(requested)) {
      throw DecodeError(DecodeError::Kind::invalidEncoding);
    }
    return {requested};
  }
  if (header_length >= 2 && header[0] == 0xff && header[1] == 0xfe) {
    return {"UTF-16LE"};
  }
  if (header_length >= 2 && header[0] == 0xfe && header[1] == 0xff) {
    return {"UTF-16BE"};
  }
  // The Android order: BOM, strict UTF-8, then GB18030 (Big5 last).
  return {"UTF-8", "GB18030", "Big5"};
}

void ConvertWith(const std::string& encoding, HANDLE source,
                 const std::wstring& target,
                 const std::function<void()>& check) {
  OutputFile output(target);
  std::vector<uint8_t> chunk(kChunkBytes);
  if (encoding == "UTF-16LE" || encoding == "UTF-16BE") {
    WideEncoding converter(encoding == "UTF-16BE", &output);
    uint64_t total = 0;
    for (;;) {
      check();
      DWORD read = 0;
      if (!ReadFile(source, chunk.data(), static_cast<DWORD>(chunk.size()),
                    &read, nullptr)) {
        throw DecodeError(DecodeError::Kind::invalidInput);
      }
      total += read;
      if (total > kMaxInputBytes) {
        throw DecodeError(DecodeError::Kind::invalidInput);
      }
      converter.Push(chunk.data(), read);
      if (read == 0) break;
    }
    converter.Finish();
  } else {
    const UINT codepage = CodepageFor(encoding);
    if (codepage == 0) {
      throw DecodeError(DecodeError::Kind::invalidEncoding);
    }
    CPINFO info{};
    if (GetCPInfo(codepage, &info) == 0 ||
        static_cast<size_t>(info.MaxCharSize) > kMaxCharBytes) {
      throw DecodeError(DecodeError::Kind::invalidEncoding);
    }
    ByteEncoding converter(codepage, &output);
    uint64_t total = 0;
    for (;;) {
      check();
      DWORD read = 0;
      if (!ReadFile(source, chunk.data(), static_cast<DWORD>(chunk.size()),
                    &read, nullptr)) {
        throw DecodeError(DecodeError::Kind::invalidInput);
      }
      total += read;
      if (total > kMaxInputBytes) {
        throw DecodeError(DecodeError::Kind::invalidInput);
      }
      converter.Push(chunk.data(), read);
      if (read == 0) break;
    }
    converter.Finish();
  }
  output.Flush();
}

std::wstring TemporaryTarget() {
  wchar_t directory[MAX_PATH]{};
  const DWORD length = GetTempPathW(MAX_PATH, directory);
  if (length == 0 || length > MAX_PATH - 64) {
    throw DecodeError(DecodeError::Kind::invalidInput);
  }
  GUID id{};
  if (CoCreateGuid(&id) != S_OK) {
    throw DecodeError(DecodeError::Kind::invalidInput);
  }
  wchar_t name[64]{};
  StringFromGUID2(id, name, 64);
  std::wstring cleaned;
  for (const wchar_t* c = name; *c != L'\0'; ++c) {
    if (*c != L'{' && *c != L'}') cleaned.push_back(*c);
  }
  return std::wstring(directory) + L"reader-normalized-" + cleaned + L".txt";
}

const flutter::EncodableValue* FindArg(const flutter::EncodableMap& args,
                                       const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

}  // namespace

void ReaderTextDecoder::RememberPending(const std::string& id) {
  std::scoped_lock guard(lock_);
  pending_.insert(id);
}

void ReaderTextDecoder::Forget(const std::string& id) {
  std::scoped_lock guard(lock_);
  cancelled_.erase(id);
  pending_.erase(id);
}

bool ReaderTextDecoder::IsCancelled(const std::string& id) {
  std::scoped_lock guard(lock_);
  return cancelled_.count(id) > 0;
}

void ReaderTextDecoder::Cancel(const std::string& id) {
  std::scoped_lock guard(lock_);
  if (pending_.count(id) > 0) cancelled_.insert(id);
}

void ReaderTextDecoder::Normalize(const flutter::EncodableMap& args,
                                  Finish result) {
  std::string id;
  std::wstring path;
  std::string requested = "auto";
  if (const auto* value = FindArg(args, "id");
      value != nullptr && std::holds_alternative<std::string>(*value)) {
    id = std::get<std::string>(*value);
  }
  if (const auto* value = FindArg(args, "path");
      value != nullptr && std::holds_alternative<std::string>(*value)) {
    path = Utf8ToWide(std::get<std::string>(*value));
  }
  if (const auto* value = FindArg(args, "encoding");
      value != nullptr && std::holds_alternative<std::string>(*value)) {
    requested = std::get<std::string>(*value);
  }

  RememberPending(id);
  auto self = shared_from_this();
  std::thread([self, id = std::move(id), path = std::move(path),
               requested = std::move(requested),
               result = std::move(result)]() mutable {
    const std::string request_id = id;
    Outcome outcome;
    std::wstring target;
    try {
      const auto check = [&self, &request_id] {
        if (self->IsCancelled(request_id)) {
          throw DecodeError(DecodeError::Kind::cancelled);
        }
      };
      check();
      ValidateSource(path);
      check();
      uint8_t header[4]{};
      size_t header_length = 0;
      {
        HANDLE probe =
            CreateFileW(path.c_str(), GENERIC_READ,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (probe == INVALID_HANDLE_VALUE) {
          throw DecodeError(DecodeError::Kind::invalidInput);
        }
        DWORD read = 0;
        if (ReadFile(probe, header, sizeof(header), &read, nullptr)) {
          header_length = read;
        }
        CloseHandle(probe);
      }
      const std::vector<std::string> candidates =
          EncodingsFor(requested, header, header_length);
      target = TemporaryTarget();
      std::string selected;
      for (const std::string& encoding : candidates) {
        check();
        HANDLE source =
            CreateFileW(path.c_str(), GENERIC_READ,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (source == INVALID_HANDLE_VALUE) {
          throw DecodeError(DecodeError::Kind::invalidInput);
        }
        bool ok = true;
        try {
          ConvertWith(encoding, source, target, check);
          selected = encoding;
        } catch (const DecodeError&) {
          ok = false;
        }
        CloseHandle(source);
        if (ok) break;
        DeleteFileW(target.c_str());
      }
      if (selected.empty()) {
        throw DecodeError(DecodeError::Kind::invalidEncoding);
      }
      check();
      outcome.ok = true;
      outcome.path = WideToUtf8(target);
      outcome.encoding = selected;
    } catch (const DecodeError& error) {
      if (!target.empty()) DeleteFileW(target.c_str());
      if (error.kind == DecodeError::Kind::cancelled) {
        outcome.error_code = "IMPORT_CANCELLED";
        outcome.error_message = "导入已取消";
      } else if (error.kind == DecodeError::Kind::invalidInput) {
        outcome.error_code = "TEXT_DECODE";
        outcome.error_message = "文本文件不可用或超出大小限制";
      } else {
        outcome.error_code = "TEXT_DECODE";
        outcome.error_message = "文本解码失败，请检查文件或手动选择编码";
      }
    } catch (...) {
      if (!target.empty()) DeleteFileW(target.c_str());
      outcome.error_code = "TEXT_DECODE";
      outcome.error_message = "文本解码失败，请检查文件或手动选择编码";
    }
    self->post_main_([self, request_id, result = std::move(result),
                      outcome = std::move(outcome)]() mutable {
      self->Forget(request_id);
      result(outcome);
    });
  }).detach();
}
