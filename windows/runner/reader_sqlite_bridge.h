#ifndef RUNNER_READER_SQLITE_BRIDGE_H_
#define RUNNER_READER_SQLITE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <winsqlite/winsqlite3.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Windows 原生 SQLite 桥接：对接 sqflite 的 "com.tekartik.sqflite" 通道，
// 使用系统内置 winsqlite3.dll 提供 WAL 事务库能力，无需额外打包第三方 DLL。
class ReaderSqliteBridge {
 public:
  using PostMainCallback = std::function<void(std::function<void()>)>;

  ReaderSqliteBridge(flutter::BinaryMessenger* messenger,
                     PostMainCallback post_main);
  ~ReaderSqliteBridge();

  // 优雅停止后台工作线程并关闭所有已打开的数据库连接。
  void Shutdown();

 private:
  struct DbEntry {
    sqlite3* handle = nullptr;
    std::string path;
    std::string normalized_key;
    bool single_instance = true;
    bool read_only = false;
    bool in_transaction = false;
    int64_t next_txn_id = 1;
  };

  void WorkerLoop();
  void EnqueueTask(std::function<void()> task);
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void DispatchOnWorker(
      const std::string& method, const flutter::EncodableMap& args,
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void CloseEntryLocked(int64_t id);
  void CloseAllLocked();

  PostMainCallback post_main_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<std::function<void()>> queue_;
  bool stopping_ = false;
  std::thread worker_;

  // 以下状态仅在 worker_ 线程内访问。
  std::map<int64_t, DbEntry> dbs_;
  std::map<std::string, int64_t> single_instances_;
  int64_t next_db_id_ = 1;
};

#endif  // RUNNER_READER_SQLITE_BRIDGE_H_
