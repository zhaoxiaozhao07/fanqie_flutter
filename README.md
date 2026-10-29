<div align="center">

# 🍅 番茄Reader (Fanqie Novel Reader)

一款基于 **Flutter** 开发的高颜值、高性能第三方番茄小说阅读与下载客户端。  
**纯 Dart 原生内置完整后端服务引擎**，彻底免除部署外部服务器或配置任何后端地址，开箱即用。

[![Release](https://img.shields.io/github/v/release/zhaoxiaozhao07/fanqie_flutter?color=FF6B6B&label=Release&logo=github)](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases/latest)
[![Build Status](https://img.shields.io/github/actions/workflow/status/zhaoxiaozhao07/fanqie_flutter/release.yml?branch=main&label=Build&logo=githubactions)](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions)
[![Flutter Version](https://img.shields.io/badge/Flutter-3.10+-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.0+-0175C2?logo=dart)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Desktop-4CAF50)](#)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

## 📖 核心特性与架构升级 (v3.0.0)

### 🚀 1. 纯 Dart 内置后端引擎 (Zero-Server Architecture)
- **完全内置运行**：完整移植并内置原本外部独立的 `fanqie-backend` 服务，免除部署或连接任何外部 Python/FastAPI 后端，不再提供任何后端地址配置项，纯本地自包含运行。
- **汉字反爬字体解密**：原生内置书库筛选与正文阅览全套 362 个 PUA 汉字解密映射字典，毫秒级内存解码，完整还原标准汉字。
- **全量多维筛选与书库**：直连官方书库 API，对齐分类、字数、连载状态、男频/女频与排序的多维复合检索，并具备榜单关键词动态降级自愈能力。
- **书籍详情与智能分卷**：通过多级正则与状态机精准提取分卷目录与章节元数据。

### 🔓 2. 移动端专属通道与无锁全量正文 (突破 Web 端 200 字限制)
- **移动端协议纯原生逆向**：纯 Dart 实现了字节跳动移动端双重安全签名与数据解密体系，包括：
  - **SM3 哈希** 与 **Simon-64/128** 轻量级分组密码（72 轮密钥扩展预编译）；
  - **Ladon** 34 轮 ARX 哈希表扩散算法；
  - **Protobuf 序列化** 与 **Argus-551** 安全签名协议；
  - **动态 AES 密钥协商 (`registerkey`)** 与 **AES-128-CBC 密文解密 + Gzip 流式解压**。
- **彻底消除预览锁章限制**：彻底突破番茄官方 Web 端中后段章节出现的 `[提示：本章为番茄APP端专享/锁章章节，当前官方Web端仅提供试读预览]` 截断，获取 2,000 ~ 5,000+ 字无锁完整正文。

### ⚡ 3. 高性能异步并发下载
- **长连接管道化**：维护持久化 HTTP/1.1 单例连接池（`maxConnectionsPerHost: 32`），复用活跃连接，彻底消除频繁 TCP 与 TLS 握手 RTT 开销。
- **解除限速与并发流水线**：内置引擎直接控制 12 并发 Worker，解除前端人为批次停顿，单章毫秒级响应。
- **非阻塞后台任务与即时保存**：点击下载即时返回，在后台持续作业，主界面右上角常驻动态下载指示器；下载完成直接流式装配 TXT 与带有封面和目录的规范 EPUB 电子书，彻底根治卡在最后章节的问题。

### 📚 4. 极致顺滑的阅读器体验
- **双向无缝连续无限滚屏**：
  - **彻底修复跳章上滑**：在传统无限下拉基础上，真正支持往上滑动平滑追加上一章，并引入精准的高度差值补偿（`jumpTo(oldOffset + deltaHeight)`），当前阅读视口内容纹丝不动；
  - **满帧长文架构**：50px 节流探测、局部邻近章节探测、`RepaintBoundary` 绘制图层隔离，彻底消除连续阅读十几章后的掉帧与卡顿；
- **目录打开智能定位**：点开目录弹窗时，按当前阅读位置自动平滑滚动定位到当前正在读的章节，上下文一览无余；
- **多重沉浸辅助**：阅读屏幕常亮（Keep Screen On）、底部 22px 微型时间/电量/总进度状态栏、四周安全边距可调、实体物理音量键平滑滚动翻页、专属纯黑 OLED 模式。

### 🎙️ 5. 智能流式预拉取 TTS 听书系统
- **双引擎支持**：支持 **Android 系统原生 TTS** 与 **OpenAI 兼容语音接口 (`/v1/audio/speech`)**；
- **音色自由自定义**：OpenAI 兼容模式下不仅内置官方经典音色，更支持自由输入任何自定义或第三方模型音色（如 `zh-CN-XiaoxiaoNeural`, `nova`, `custom-voice` 等）；
- **智能短句分块与双缓冲预拉取流水线**：
  - 按句末标点自动切分为 80~200 字的高效自然句块；
  - 播放切片 N 时，后台并发管道**提前异步拉取并缓存切片 N+1 与 N+2**，播完 0 毫秒无缝切入，彻底杜绝切句停顿与大段超长请求超时；
- **Word 经典温润荧光高亮**：根据当前阅读主题自动适配同色系低饱和度温和底色（白昼米暖、羊皮纸茶木、护眼绿春草、暗夜纯黑深碳灰），绝不刺眼，自然保留段落行气；
- **当前视口首句直接开播**：点击听书根据读者视线在屏幕上的垂直坐标，从当前屏幕顶部第一句话开口朗读；
- **智能字幕平滑滚屏跟随**：高亮文字始终平滑保持在屏幕黄金视线舒适区。

### 🖼️ 6. 书架与多级自愈封面体系
- **实体书黄金长宽比 (1 : 1.42)**：三列宫格彻底消除矮胖正方形，封面与文字容器高度完全解耦恒定，全屏书籍整齐划一，大小绝对一致；
- **操作精准分区**：点击书本封面直接进入阅读秒开；点击书名/作者文字区域进入书籍详情页；
- **三级自愈封面体系**：
  1. 本地永久离线磁盘缓存（`${docDir}/offline_books/${bookId}/cover.jpg`）；
  2. 已下载 EPUB 内部封面自动解压提取；
  3. 书架与下载记录双索引跨源互补；
  4. 后台搜索接口静默补全最新封面。

---

## 🏗️ 核心架构与协议原理

### 1. 移动端安全通信与解密链路
```
[书籍 itemId] 
      │
      ▼
[移动端网关: /reading/reader/full/v]
      │
      ├──> [Argus-551 协议封装] ──> Protobuf Bean 序列化 ──> Simon-64/128 加密 ──> SM3 哈希校验
      ├──> [Ladon 34 轮扩散] ──> ARX 哈希表动态置换
      └──> [动态 AES 密钥协商] ──> /reading/crypt/registerkey (AES-128-CBC 交互)
                                            │
                                            ▼
                             [获取加密正文密文]
                                            │
                                            ▼
                 [AES-128-CBC 解密] ──> [Gzip 压缩流解压] ──> [HTML 标题/段落清洗]
                                            │
                                            ▼
                           [突破锁章限制的万字完整正文]
```

### 2. TTS 双缓冲滑动窗口流水线
```
[当前朗读: 切片 N] ──> (正在通过本地音频播放器平滑输出)
        │
        └──> [后台并发管道] ──> 提前异步请求 OpenAI 接口拉取并缓存 [切片 N+1] 与 [切片 N+2]
                                      │
[切片 N 播完触发 onAudioComplete] <───┘
        │
        └──> [切片 N+1] 音频已在本地完全就绪，0 毫秒无缝切入播放！
        │
        └──> [后台并发管道] 立即异步预拉取 [切片 N+3]
```

---

## 🛠️ 构建与运行

### 环境要求
- **Flutter SDK**: `>= 3.10.4`
- **Dart SDK**: `>= 3.0.0`
- **Java**: `21` (推荐 Temurin JDK 21)
- **Android SDK**: `compileSdkVersion 34` / `minSdkVersion 24`

### 常用命令
```bash
# 获取依赖包
flutter pub get

# 运行代码分析
flutter analyze

# 执行全套单元与功能测试 (21 个测试用例)
flutter test

# 运行调试版本
flutter run

# 构建发布版 Release APK
flutter build apk --release
```

---

## 📚 参考项目与致谢 (References & Acknowledgements)

本项目在移动端协议逆向、动态密钥协商及解密架构的开发过程中，参考了开源社区的杰出成果，特此致以诚挚的敬意与感谢：

1. **[Fanqie-novel-Downloader (POf-L)](https://github.com/POf-L/Fanqie-novel-Downloader)**  
   - 核心参考了其关于番茄小说移动端专属通道的协议逻辑、请求参数规范、动态 AES 密钥协商机制 (`/reading/crypt/registerkey`) 以及字节跳动移动端双重风控体系的设计思路。
2. **开源社区与协议研究者**  
   - 感谢在字节跳动 Ladon / Argus-551 算法扩散、Simon 算法测试向量以及字体反爬解密领域做出贡献的开源作者们。

---

## 📄 免责声明 (Disclaimer)

1. 本项目仅供编程学习、技术研究与个人学习使用，禁止用于任何商业用途或批量滥用。
2. 小说版权归番茄小说及其原作者所有。请支持正版小说。
3. 使用本项目所产生的一切后果由使用者自行承担，开发者不承担任何法律责任。

---

<div align="center">
Made with ❤️ by Open Source Community
</div>
