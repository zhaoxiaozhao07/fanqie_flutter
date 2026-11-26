#include "reader_sqlite_bridge.h"

#include <ShlObj.h>
#include <Windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <optional>
#include <vector>

namespace {

// UTF-8 与 UTF-16 路径转换工具。
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

std::wstring ToLowerWide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

std::string NormalizePathKey(const std::string& raw_path) {
  if (raw_path == ":memory:") return raw_path;
  const std::wstring wide = Utf8ToWide(raw_path);
  if (wide.empty()) return raw_path;
  std::error_code ec;
  const std::filesystem::path p = std::filesystem::weakly_canonical(wide, ec);
  const std::wstring norm =
      ec ? std::filesystem::path(wide).lexically_normal().wstring()
         : p.wstring();
  return WideToUtf8(ToLowerWide(norm));
}

std::string DefaultDatabasesPath() {
  PWSTR raw = nullptr;
  std::filesystem::path base;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                     &raw)) &&
      raw != nullptr) {
    base = std::filesystem::path(raw);
    CoTaskMemFree(raw);
  } else {
    wchar_t temp[MAX_PATH + 1]{};
    GetTempPathW(MAX_PATH, temp);
    base = std::filesystem::path(temp);
  }
  const std::filesystem::path dir =
      base / L"com.fanqie" / L"FanqieReader" / L"databases";
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  return WideToUtf8(dir.wstring());
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

bool BoolArg(const flutter::EncodableMap& args, const char* key,
             bool fallback = false) {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<bool>(*value)) {
    return std::get<bool>(*value);
  }
  return fallback;
}

std::optional<bool> OptionalBoolArg(const flutter::EncodableMap& args,
                                    const char* key) {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<bool>(*value)) {
    return std::get<bool>(*value);
  }
  return std::nullopt;
}

std::optional<int64_t> OptionalInt64Arg(const flutter::EncodableMap& args,
                                        const char* key) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return std::nullopt;
  if (std::holds_alternative<int64_t>(*value)) return std::get<int64_t>(*value);
  if (std::holds_alternative<int32_t>(*value)) {
    return static_cast<int64_t>(std::get<int32_t>(*value));
  }
  return std::nullopt;
}

const flutter::EncodableList* ListArg(const flutter::EncodableMap& args,
                                      const char* key) {
  const auto* value = FindArg(args, key);
  if (value != nullptr && std::holds_alternative<flutter::EncodableList>(*value)) {
    return &std::get<flutter::EncodableList>(*value);
  }
  return nullptr;
}

struct SqlOutcome {
  bool ok = true;
  int result_code = SQLITE_OK;
  std::string error_message;
  flutter::EncodableValue value;
};

// 将 Flutter 参数列表绑定到 SQLite 预处理语句。
int BindSqlArguments(sqlite3_stmt* stmt, const flutter::EncodableList* args,
                     std::string* error_out) {
  if (args == nullptr) return SQLITE_OK;
  const int expected = sqlite3_bind_parameter_count(stmt);
  if (static_cast<int>(args->size()) != expected) {
    if (error_out) {
      *error_out = "SQL parameter count mismatch";
    }
    return SQLITE_RANGE;
  }
  for (size_t i = 0; i < args->size(); ++i) {
    const int index = static_cast<int>(i) + 1;
    const flutter::EncodableValue& val = (*args)[i];
    int rc = SQLITE_OK;
    if (std::holds_alternative<std::monostate>(val)) {
      rc = sqlite3_bind_null(stmt, index);
    } else if (std::holds_alternative<bool>(val)) {
      rc = sqlite3_bind_int(stmt, index, std::get<bool>(val) ? 1 : 0);
    } else if (std::holds_alternative<int32_t>(val)) {
      rc = sqlite3_bind_int64(stmt, index, std::get<int32_t>(val));
    } else if (std::holds_alternative<int64_t>(val)) {
      rc = sqlite3_bind_int64(stmt, index, std::get<int64_t>(val));
    } else if (std::holds_alternative<double>(val)) {
      rc = sqlite3_bind_double(stmt, index, std::get<double>(val));
    } else if (std::holds_alternative<std::string>(val)) {
      const auto& str = std::get<std::string>(val);
      rc = sqlite3_bind_text(stmt, index, str.data(),
                             static_cast<int>(str.size()), SQLITE_TRANSIENT);
    } else if (std::holds_alternative<std::vector<uint8_t>>(val)) {
      const auto& blob = std::get<std::vector<uint8_t>>(val);
      static const uint8_t kEmptyBlob = 0;
      const void* ptr =
          blob.empty() ? static_cast<const void*>(&kEmptyBlob)
                       : static_cast<const void*>(blob.data());
      rc = sqlite3_bind_blob(stmt, index, ptr, static_cast<int>(blob.size()),
                             SQLITE_TRANSIENT);
    } else {
      if (error_out) *error_out = "Unsupported SQL argument type";
      return SQLITE_MISMATCH;
    }
    if (rc != SQLITE_OK) {
      if (error_out) *error_out = "Failed to bind SQL argument";
      return rc;
    }
  }
  return SQLITE_OK;
}

flutter::EncodableValue ExtractColumnValue(sqlite3_stmt* stmt, int col) {
  switch (sqlite3_column_type(stmt, col)) {
    case SQLITE_INTEGER:
      return flutter::EncodableValue(
          static_cast<int64_t>(sqlite3_column_int64(stmt, col)));
    case SQLITE_FLOAT:
      return flutter::EncodableValue(sqlite3_column_double(stmt, col));
    case SQLITE_TEXT: {
      const auto* text =
          reinterpret_cast<const char*>(sqlite3_column_text(stmt, col));
      const int bytes = sqlite3_column_bytes(stmt, col);
      if (text == nullptr || bytes <= 0) {
        return flutter::EncodableValue(std::string());
      }
      return flutter::EncodableValue(std::string(text, bytes));
    }
    case SQLITE_BLOB: {
      const auto* data =
          static_cast<const uint8_t*>(sqlite3_column_blob(stmt, col));
      const int bytes = sqlite3_column_bytes(stmt, col);
      if (data == nullptr || bytes <= 0) {
        return flutter::EncodableValue(std::vector<uint8_t>());
      }
      return flutter::EncodableValue(std::vector<uint8_t>(data, data + bytes));
    }
    case SQLITE_NULL:
    default:
      return flutter::EncodableValue();
  }
}

SqlOutcome RunExecute(sqlite3* db, const std::string& sql,
                      const flutter::EncodableList* args) {
  SqlOutcome out;
  const char* cursor = sql.c_str();
  const char* end = sql.c_str() + sql.size();
  bool bound_used = false;
  while (cursor < end) {
    sqlite3_stmt* stmt = nullptr;
    const char* tail = nullptr;
    int rc = sqlite3_prepare_v2(db, cursor, static_cast<int>(end - cursor),
                                &stmt, &tail);
    if (rc != SQLITE_OK) {
      out.ok = false;
      out.result_code = rc;
      out.error_message = sqlite3_errmsg(db);
      return out;
    }
    cursor = tail != nullptr ? tail : end;
    if (stmt == nullptr) continue;

    if (!bound_used && args != nullptr && !args->empty()) {
      std::string bind_err;
      rc = BindSqlArguments(stmt, args, &bind_err);
      if (rc != SQLITE_OK) {
        sqlite3_finalize(stmt);
        out.ok = false;
        out.result_code = rc;
        out.error_message =
            bind_err.empty() ? sqlite3_errmsg(db) : bind_err;
        return out;
      }
      bound_used = true;
    }

    // PRAGMA 等语句会返回 SQLITE_ROW，需持续 step 直至 SQLITE_DONE。
    do {
      rc = sqlite3_step(stmt);
    } while (rc == SQLITE_ROW);

    if (rc != SQLITE_DONE) {
      out.ok = false;
      out.result_code = rc;
      out.error_message = sqlite3_errmsg(db);
      sqlite3_finalize(stmt);
      return out;
    }
    sqlite3_finalize(stmt);
  }
  return out;
}

SqlOutcome RunInsert(sqlite3* db, const std::string& sql,
                     const flutter::EncodableList* args) {
  SqlOutcome out;
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(db, sql.c_str(), static_cast<int>(sql.size()),
                              &stmt, nullptr);
  if (rc != SQLITE_OK || stmt == nullptr) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  std::string bind_err;
  rc = BindSqlArguments(stmt, args, &bind_err);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    out.ok = false;
    out.result_code = rc;
    out.error_message = bind_err.empty() ? sqlite3_errmsg(db) : bind_err;
    return out;
  }
  do {
    rc = sqlite3_step(stmt);
  } while (rc == SQLITE_ROW);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  if (sqlite3_changes(db) > 0) {
    out.value =
        flutter::EncodableValue(static_cast<int64_t>(sqlite3_last_insert_rowid(db)));
  } else {
    out.value = flutter::EncodableValue();
  }
  return out;
}

SqlOutcome RunUpdate(sqlite3* db, const std::string& sql,
                     const flutter::EncodableList* args) {
  SqlOutcome out;
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(db, sql.c_str(), static_cast<int>(sql.size()),
                              &stmt, nullptr);
  if (rc != SQLITE_OK || stmt == nullptr) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  std::string bind_err;
  rc = BindSqlArguments(stmt, args, &bind_err);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    out.ok = false;
    out.result_code = rc;
    out.error_message = bind_err.empty() ? sqlite3_errmsg(db) : bind_err;
    return out;
  }
  do {
    rc = sqlite3_step(stmt);
  } while (rc == SQLITE_ROW);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  out.value = flutter::EncodableValue(static_cast<int64_t>(sqlite3_changes(db)));
  return out;
}

SqlOutcome RunQuery(sqlite3* db, const std::string& sql,
                    const flutter::EncodableList* args) {
  SqlOutcome out;
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(db, sql.c_str(), static_cast<int>(sql.size()),
                              &stmt, nullptr);
  if (rc != SQLITE_OK || stmt == nullptr) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  std::string bind_err;
  rc = BindSqlArguments(stmt, args, &bind_err);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    out.ok = false;
    out.result_code = rc;
    out.error_message = bind_err.empty() ? sqlite3_errmsg(db) : bind_err;
    return out;
  }
  const int col_count = sqlite3_column_count(stmt);
  flutter::EncodableList columns;
  columns.reserve(col_count);
  for (int i = 0; i < col_count; ++i) {
    const char* name = sqlite3_column_name(stmt, i);
    columns.push_back(flutter::EncodableValue(name ? std::string(name) : ""));
  }
  flutter::EncodableList rows;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    flutter::EncodableList row;
    row.reserve(col_count);
    for (int i = 0; i < col_count; ++i) {
      row.push_back(ExtractColumnValue(stmt, i));
    }
    rows.push_back(flutter::EncodableValue(std::move(row)));
  }
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    out.ok = false;
    out.result_code = rc;
    out.error_message = sqlite3_errmsg(db);
    return out;
  }
  flutter::EncodableMap result_map;
  result_map[flutter::EncodableValue("columns")] =
      flutter::EncodableValue(std::move(columns));
  result_map[flutter::EncodableValue("rows")] =
      flutter::EncodableValue(std::move(rows));
  out.value = flutter::EncodableValue(std::move(result_map));
  return out;
}

}  // namespace

ReaderSqliteBridge::ReaderSqliteBridge(flutter::BinaryMessenger* messenger,
                                       PostMainCallback post_main)
    : post_main_(std::move(post_main)) {
  worker_ = std::thread([this] { WorkerLoop(); });
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.tekartik.sqflite",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

ReaderSqliteBridge::~ReaderSqliteBridge() { Shutdown(); }

void ReaderSqliteBridge::Shutdown() {
  if (channel_ != nullptr) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) return;
    stopping_ = true;
  }
  queue_cv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void ReaderSqliteBridge::EnqueueTask(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) return;
    queue_.push_back(std::move(task));
  }
  queue_cv_.notify_one();
}

void ReaderSqliteBridge::WorkerLoop() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
      if (stopping_ && queue_.empty()) break;
      task = std::move(queue_.front());
      queue_.pop_front();
    }
    if (task) task();
  }
  CloseAllLocked();
}

void ReaderSqliteBridge::CloseEntryLocked(int64_t id) {
  const auto it = dbs_.find(id);
  if (it == dbs_.end()) return;
  if (it->second.single_instance && !it->second.normalized_key.empty()) {
    const auto sit = single_instances_.find(it->second.normalized_key);
    if (sit != single_instances_.end() && sit->second == id) {
      single_instances_.erase(sit);
    }
  }
  if (it->second.handle != nullptr) {
    sqlite3_close_v2(it->second.handle);
    it->second.handle = nullptr;
  }
  dbs_.erase(it);
}

void ReaderSqliteBridge::CloseAllLocked() {
  for (auto& kv : dbs_) {
    if (kv.second.handle != nullptr) {
      sqlite3_close_v2(kv.second.handle);
      kv.second.handle = nullptr;
    }
  }
  dbs_.clear();
  single_instances_.clear();
}

void ReaderSqliteBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string method = call.method_name();
  const auto* raw_args = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap args =
      raw_args == nullptr ? flutter::EncodableMap() : *raw_args;
  const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> owned(
      result.release());

  EnqueueTask([this, method, args, owned] {
    DispatchOnWorker(method, args, owned);
  });
}

void ReaderSqliteBridge::DispatchOnWorker(
    const std::string& method, const flutter::EncodableMap& args,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto reply_success = [this, result](flutter::EncodableValue val) {
    post_main_([result, val = std::move(val)]() { result->Success(val); });
  };
  auto reply_null = [this, result]() {
    post_main_([result]() { result->Success(); });
  };
  auto reply_error = [this, result](const std::string& code,
                                    const std::string& msg) {
    post_main_([result, code, msg]() { result->Error(code, msg); });
  };

  if (method == "getDatabasesPath") {
    reply_success(flutter::EncodableValue(DefaultDatabasesPath()));
    return;
  }

  if (method == "options" || method == "debugMode" || method == "debug") {
    if (method == "debug") {
      flutter::EncodableMap map;
      map[flutter::EncodableValue("databases")] =
          flutter::EncodableValue(flutter::EncodableMap());
      reply_success(flutter::EncodableValue(std::move(map)));
    } else {
      reply_null();
    }
    return;
  }

  if (method == "databaseExists") {
    const std::string path = StringArg(args, "path");
    if (path.empty() || path == ":memory:") {
      reply_success(flutter::EncodableValue(false));
      return;
    }
    const std::wstring wide = Utf8ToWide(path);
    const DWORD attrs = GetFileAttributesW(wide.c_str());
    const bool exists = attrs != INVALID_FILE_ATTRIBUTES &&
                        (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
    reply_success(flutter::EncodableValue(exists));
    return;
  }

  if (method == "deleteDatabase") {
    const std::string path = StringArg(args, "path");
    if (!path.empty() && path != ":memory:") {
      const std::string key = NormalizePathKey(path);
      std::vector<int64_t> to_close;
      for (const auto& kv : dbs_) {
        if (kv.second.normalized_key == key) to_close.push_back(kv.first);
      }
      for (int64_t id : to_close) CloseEntryLocked(id);
      const std::wstring wide = Utf8ToWide(path);
      std::error_code ec;
      std::filesystem::remove(wide, ec);
      std::filesystem::remove(wide + L"-wal", ec);
      std::filesystem::remove(wide + L"-shm", ec);
      std::filesystem::remove(wide + L"-journal", ec);
    }
    reply_null();
    return;
  }

  if (method == "openDatabase") {
    const std::string path = StringArg(args, "path");
    const bool read_only = BoolArg(args, "readOnly", false);
    const bool single_instance =
        BoolArg(args, "singleInstance", true) && path != ":memory:";
    if (path.empty()) {
      reply_error("sqlite_error", "Database path is empty");
      return;
    }
    const std::string norm_key = NormalizePathKey(path);
    if (single_instance) {
      const auto sit = single_instances_.find(norm_key);
      if (sit != single_instances_.end()) {
        const auto dit = dbs_.find(sit->second);
        if (dit != dbs_.end() && dit->second.handle != nullptr) {
          flutter::EncodableMap res;
          res[flutter::EncodableValue("id")] =
              flutter::EncodableValue(dit->first);
          res[flutter::EncodableValue("recovered")] =
              flutter::EncodableValue(true);
          if (dit->second.in_transaction) {
            res[flutter::EncodableValue("recoveredInTransaction")] =
                flutter::EncodableValue(true);
          }
          reply_success(flutter::EncodableValue(std::move(res)));
          return;
        }
      }
    }

    if (path != ":memory:" && !read_only) {
      const std::filesystem::path fs_path(Utf8ToWide(path));
      if (fs_path.has_parent_path()) {
        std::error_code ec;
        std::filesystem::create_directories(fs_path.parent_path(), ec);
      }
    }

    sqlite3* db = nullptr;
    const int flags =
        read_only ? SQLITE_OPEN_READONLY
                  : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    const int rc = sqlite3_open_v2(path.c_str(), &db, flags, nullptr);
    if (rc != SQLITE_OK || db == nullptr) {
      const std::string err =
          db != nullptr ? sqlite3_errmsg(db) : "Failed to open SQLite database";
      if (db != nullptr) sqlite3_close_v2(db);
      reply_error("sqlite_error", err);
      return;
    }
    sqlite3_busy_timeout(db, 5000);

    const int64_t id = next_db_id_++;
    DbEntry entry;
    entry.handle = db;
    entry.path = path;
    entry.normalized_key = norm_key;
    entry.single_instance = single_instance;
    entry.read_only = read_only;
    dbs_[id] = entry;
    if (single_instance) {
      single_instances_[norm_key] = id;
    }
    flutter::EncodableMap res;
    res[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
    reply_success(flutter::EncodableValue(std::move(res)));
    return;
  }

  if (method == "closeDatabase") {
    const auto id = OptionalInt64Arg(args, "id");
    if (id.has_value()) {
      CloseEntryLocked(*id);
    }
    reply_null();
    return;
  }

  const auto id = OptionalInt64Arg(args, "id");
  if (!id.has_value()) {
    reply_error("sqlite_error", "Missing database id");
    return;
  }
  const auto dit = dbs_.find(*id);
  if (dit == dbs_.end() || dit->second.handle == nullptr) {
    reply_error("sqlite_error", "Database is closed");
    return;
  }
  DbEntry& entry = dit->second;
  sqlite3* db = entry.handle;

  if (method == "execute") {
    const std::string sql = StringArg(args, "sql");
    const auto* sql_args = ListArg(args, "arguments");
    const auto in_txn = OptionalBoolArg(args, "inTransaction");
    const bool has_txn_key = FindArg(args, "transactionId") != nullptr;
    const bool txn_id_is_null =
        has_txn_key &&
        std::holds_alternative<std::monostate>(*FindArg(args, "transactionId"));

    const SqlOutcome outcome = RunExecute(db, sql, sql_args);
    if (!outcome.ok) {
      reply_error("sqlite_error", outcome.error_message);
      return;
    }
    if (in_txn.has_value()) {
      entry.in_transaction = *in_txn;
    }
    if (in_txn.value_or(false) && txn_id_is_null) {
      flutter::EncodableMap res;
      res[flutter::EncodableValue("transactionId")] =
          flutter::EncodableValue(entry.next_txn_id++);
      reply_success(flutter::EncodableValue(std::move(res)));
    } else {
      reply_null();
    }
    return;
  }

  if (method == "insert") {
    const SqlOutcome outcome =
        RunInsert(db, StringArg(args, "sql"), ListArg(args, "arguments"));
    if (!outcome.ok) {
      reply_error("sqlite_error", outcome.error_message);
      return;
    }
    reply_success(outcome.value);
    return;
  }

  if (method == "update") {
    const SqlOutcome outcome =
        RunUpdate(db, StringArg(args, "sql"), ListArg(args, "arguments"));
    if (!outcome.ok) {
      reply_error("sqlite_error", outcome.error_message);
      return;
    }
    reply_success(outcome.value);
    return;
  }

  if (method == "query") {
    const SqlOutcome outcome =
        RunQuery(db, StringArg(args, "sql"), ListArg(args, "arguments"));
    if (!outcome.ok) {
      reply_error("sqlite_error", outcome.error_message);
      return;
    }
    reply_success(outcome.value);
    return;
  }

  if (method == "batch") {
    const auto* operations = ListArg(args, "operations");
    const bool no_result = BoolArg(args, "noResult", false);
    const bool continue_on_error = BoolArg(args, "continueOnError", false);
    flutter::EncodableList results;
    if (operations != nullptr) {
      if (!no_result) results.reserve(operations->size());
      for (const auto& op_val : *operations) {
        if (!std::holds_alternative<flutter::EncodableMap>(op_val)) continue;
        const auto& op = std::get<flutter::EncodableMap>(op_val);
        const std::string op_method = StringArg(op, "method");
        const std::string sql = StringArg(op, "sql");
        const auto* sql_args = ListArg(op, "arguments");
        SqlOutcome outcome;
        if (op_method == "insert") {
          outcome = RunInsert(db, sql, sql_args);
        } else if (op_method == "update") {
          outcome = RunUpdate(db, sql, sql_args);
        } else if (op_method == "query") {
          outcome = RunQuery(db, sql, sql_args);
        } else {
          outcome = RunExecute(db, sql, sql_args);
          if (outcome.ok) {
            const auto in_txn = OptionalBoolArg(op, "inTransaction");
            if (in_txn.has_value()) entry.in_transaction = *in_txn;
          }
        }
        if (!outcome.ok) {
          if (!continue_on_error) {
            reply_error("sqlite_error", outcome.error_message);
            return;
          }
          if (!no_result) {
            flutter::EncodableMap err_map;
            err_map[flutter::EncodableValue("code")] =
                flutter::EncodableValue("sqlite_error");
            err_map[flutter::EncodableValue("message")] =
                flutter::EncodableValue(outcome.error_message);
            err_map[flutter::EncodableValue("resultCode")] =
                flutter::EncodableValue(static_cast<int32_t>(outcome.result_code));
            flutter::EncodableMap item;
            item[flutter::EncodableValue("error")] =
                flutter::EncodableValue(std::move(err_map));
            results.push_back(flutter::EncodableValue(std::move(item)));
          }
        } else if (!no_result) {
          flutter::EncodableMap item;
          item[flutter::EncodableValue("result")] = outcome.value;
          results.push_back(flutter::EncodableValue(std::move(item)));
        }
      }
    }
    if (no_result) {
      reply_null();
    } else {
      reply_success(flutter::EncodableValue(std::move(results)));
    }
    return;
  }

  post_main_([result]() { result->NotImplemented(); });
}
