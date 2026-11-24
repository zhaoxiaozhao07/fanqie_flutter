# 番茄Reader

基于 Flutter 构建的跨平台小说阅读与离线下载客户端，内置 Dart 服务引擎，无需单独部署后端服务。

## 核心功能

- **书库与管理**：支持分类浏览、条件筛选、书籍搜索、书架管理、阅读历史与连载更新检查。
- **阅读与排版**：支持上下滚动及覆盖、仿真、滑动、渐变、无动画五种翻页模式；提供多套阅读配色、内置宋体/楷体及外部 TTF/OTF 字体导入，支持正文插图查看与离线简繁切换。
- **桌面阅读体验**：针对 Windows 与 macOS 适配单/双栏布局、沉浸全屏模式、侧边目录与正文搜索、文本选区批注、位置前进/后退及自定义快捷键。
- **离线缓存与导出**：支持章节邻近预取、并发下载队列管理以及 TXT / EPUB 离线导出（保留正文插图）。
- **本地书库与听书**：支持本地 TXT / EPUB 预览与导入；支持系统语音引擎及兼容 OpenAI `/v1/audio/speech` 接口的朗读功能。
- **笔记与数据安全**：支持同章多书签、精准划线批注、跨书笔记检索与 Markdown/JSON 导出；内置回收站撤销与本地备份恢复机制。

## 支持平台与下载

请前往 [GitHub Releases](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases/latest) 获取对应平台的安装包：

| 平台 | 产物形式 | 说明 |
| --- | --- | --- |
| Android | APK 安装包 | 支持正式签名覆盖安装 |
| Windows | x64 便携压缩包 (ZIP) | 解压后运行 `FanqieReader.exe`，未做代码签名 |
| macOS | Apple Silicon (arm64) DMG | 自用构建，临时签名且未经过公证 |

## 快速开始

### 环境要求

- Flutter SDK（Dart SDK >= 3.10.4）
- Android 构建需配置 Android SDK 与 Java 21
- 桌面端构建需配置对应平台的 Visual Studio（Windows）或 Xcode（macOS）

### 常用命令

```bash
# 获取依赖
flutter pub get

# 本地运行（按目标平台替换为 windows / macos / android 设备 ID）
flutter run

# 代码静态检查与单元测试
flutter analyze
flutter test

# 构建发布包
flutter build apk --release
flutter build windows --release
flutter build macos --release
```

## 项目结构

```text
.
├── lib/                 # 应用核心代码（模型、页面、服务与组件）
├── assets/              # 应用图标、内置字体与静态映射数据
├── android/             # Android 平台工程配置与原生代码
├── windows/             # Windows 平台工程配置与原生代码
├── macos/               # macOS 平台工程配置与原生代码
├── test/                # 单元测试与组件测试
├── integration_test/    # 跨平台集成测试与性能测试
├── scripts/             # 打包、校验与自动化测试脚本
└── docs/                # 发布文档与历史归档
```

## 相关文档

- 版本更新记录：[docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md)
- 三平台统一发布说明：[docs/UNIFIED_RELEASE.md](docs/UNIFIED_RELEASE.md)
- 历史规划与验证归档：[docs/archive/](docs/archive/README.md)

## 免责声明

本项目仅供学习、技术研究与个人使用。小说内容版权归原作者及相关权利人所有，请支持正版，勿用于商业用途或任何侵权行为。

感谢开源社区及 [Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader) 等参考项目。
