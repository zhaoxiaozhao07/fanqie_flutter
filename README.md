# 番茄小说 Flutter 客户端

一款基于 Flutter 开发的番茄小说第三方客户端，支持小说搜索、浏览、下载等功能。

## 来源

[Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader)
这个项目很好用，但是我不是实时都有电脑可以使用其下载，而且主要在手机阅读，就弄成一个app版本的，直接下载手机阅读；希望支持原作者。

## 功能特性

- **榜单浏览** - 支持巅峰榜、出版榜、热搜榜、黑马榜、爆更榜、推荐榜、完结榜
- **分类筛选** - 按玄幻、修仙、都市、重生等分类浏览，支持男频/女频切换
- **书籍搜索** - 支持按书名、作者搜索小说
- **书籍详情** - 查看书籍信息、章节目录
- **小说下载** - 支持 TXT 和 EPUB 格式导出，可保存到本地
- **下载历史** - 记录下载历史，方便查看

## 技术栈

- **Flutter 3.10+** - 跨平台 UI 框架
- **Dart** - 开发语言
- **cached_network_image** - 图片缓存
- **archive** - EPUB 生成

## 构建

### 环境要求

- Flutter SDK 3.10.4+
- Dart SDK 3.0+
- Android SDK (Android 开发)

### 编译运行

```bash
# 获取依赖
flutter pub get

# 运行调试版本
flutter run

# 构建 Release APK
flutter build apk --release
```

## 下载

前往 [Releases](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases) 页面下载最新版本 APK。
