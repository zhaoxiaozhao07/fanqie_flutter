# v3.3.0 实施与验证记录

## 修复范围

- 官方分类源：`/api/author/book/category_list/v0/`，按频道获取并保存上一次成功的元数据，不再使用两套手写分类表。
- 书库：`/api/author/library/book_list/v0/`，频道映射为全部 `-1`、男频 `1`、女频 `0`；字数五档为 `0–4`；状态和排序与官方客户端协议对齐。
- 分类组名、名称、ID、数量均来自响应。分类可查找；频道变化清空不兼容选择，刷新移除已失效分类选择。
- 成功空页、业务失败和传输失败分开处理；分页遵循 `has_more`，去重并防止迟到响应覆盖新筛选结果。
- 移除关键词伪榜单、分类关键词降级、伪健康检查、正文通道别名、未使用的批量正文接口和旧匿名 Cookie 资产。
- 正文密钥首次协商、并发握手合并、密钥轮换后有界重试；校验响应、密钥长度、填充及 UTF-8。拒绝网页预览回退和损坏正文。
- 不删除已有书架、进度、本地导入、明确下载或批注。旧预览占位内容不会作为成功正文使用。
- 修复无下载时仍运行的按钮动画；窄屏、横屏和大字布局验证。

## 本地验证（2026-11-02）

工具链：Flutter 3.47.4 / Dart 3.13.3 / Java 21；专用 API 35 模拟器。

| 项目 | 结果 |
|---|---|
| `flutter analyze` | 通过，无问题 |
| 默认 `flutter test --reporter expanded` | 212 个通过；8 个真实接口用例默认跳过 |
| `FANQIE_LIVE_API=true` 的接口测试组 | 8 个通过 |
| `integration_test/discovery_platform_test.dart` | 1 个通过 |
| `scripts/test_android_platform.sh` | 9 个通过，含实际音频前台服务、关屏、暂停恢复 |
| Android Debug APK 构建与安装 | 通过，versionName 3.3.0 / versionCode 330 |
| 实际首页与分类弹层视觉检查 | 通过；此次全部频道返回 260 项分类，不把数量作为固定上限 |
| 发布 workflow YAML、依赖关系与 1800 秒门禁检查 | 通过 |

真实接口测试验证分类、筛选字数范围、分页 ID 不重复、详情目录、完整正文与评论。
正文额外直接调用移动端网关，避免磁盘旧缓存掩盖密钥协商或解密失败。测试使用临时目录并清理。

## 云端发布门禁

`v3.3.0` 标签触发 `.github/workflows/release.yml`：

1. 版本一致性、静态分析和确定性测试。
2. 官方内容接口小样本实测。
3. Android 首页交互、阅读器平台验证及 1800 秒关屏稳定性测试。
4. 使用仓库签名 secrets 构建 APK、计算 SHA-256 并创建正式 Release。

云端结果以该标签的 Actions 与 Release 记录为准。接口或任何必要测试失败时不发布。

### 云端完成记录（2026-11-02）

- 源码提交：`fe3cb405a17d1e8af2590f6c4b4b1fbe25abfa14`，标签 `v3.3.0`。
- [主分支 CI](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/41409105018)：通过。
- [标签发布 workflow](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/41409105011)：四个必要任务全部通过。
- 云端平台日志：9 个平台测试通过；`FANQIE_SOAK_DURATION=1800`，实际持续约 30:06，关屏测试通过。
- [正式 Release](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases/tag/v3.3.0)：非草稿、非预发布，已成为最新正式版。
- APK 下载后重新验证 SHA-256、APK 签名、包名与版本；签名证书与 v3.2.0 一致，无需因本次发布更换签名而卸载旧版。
- APK：`fanqie-v3.3.0.apk`，versionName `3.3.0` / versionCode `330`。
- SHA-256：`74d0f1246af274e7fa8220bd79cb0b44cc4dc81a3754926d0452176f5a692173`。

## 保留边界

- 第三方接口持续可用性不受项目控制。界面显示可重试错误，不用无关搜索或网页预览掩盖失败。
- 当前首页是官方小说书库；未宣称已实现真实七榜、漫画、短剧或官方账号同步。
- 模拟器和少量接口样本不是所有书籍、所有网络、所有厂商设备的保证；不支持 DRM 或付费权限绕过。
