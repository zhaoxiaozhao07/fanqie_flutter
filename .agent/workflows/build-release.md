---
description: 手动构建并发布 Flutter APK 到 GitHub Release
---

# 构建并发布 APK

此工作流说明如何构建签名的 Release APK 并发布到 GitHub Releases。

## 自动发布（推荐）

### 通过 Git Tag 触发

// turbo
1. 确保所有代码已提交并推送到远程仓库

2. 创建并推送 tag：
```bash
git tag v1.0.0
git push origin v1.0.0
```

3. GitHub Actions 会自动：
   - 构建签名的 Release APK
   - 创建 GitHub Release
   - 上传 APK 文件

### 通过 GitHub 手动触发

1. 打开 GitHub 仓库页面
2. 点击 **Actions** 标签
3. 选择 **构建并发布 Flutter APK** 工作流
4. 点击 **Run workflow**
5. 输入版本号（可选，留空则使用 pubspec.yaml 中的版本）
6. 点击 **Run workflow** 按钮

---

## 本地构建

如需在本地构建签名 APK：

### 1. 创建 key.properties 文件

在 `android/` 目录下创建 `key.properties` 文件：

```properties
storePassword=你的密钥库密码
keyPassword=fanqiefanqie
keyAlias=fanqie
storeFile=你的密钥文件路径.jks
```

### 2. 执行构建

// turbo
```bash
flutter build apk --release
```

### 3. 获取 APK

构建完成后，APK 文件位于：
```
build/app/outputs/flutter-apk/app-release.apk
```

---

## GitHub Secrets 配置

在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中添加以下 Secrets：

| Secret 名称 | 说明 |
|-------------|------|
| `KEYSTORE_BASE64` | 签名密钥文件的 Base64 编码 |
| `KEYSTORE_PASSWORD` | 密钥库密码 |
| `KEY_ALIAS` | 密钥别名：`fanqie` |
| `KEY_PASSWORD` | 密钥密码：`fanqiefanqie` |

### 生成 KEYSTORE_BASE64

**Windows (PowerShell):**
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("your_keystore.jks")) | Out-File keystore_base64.txt
```

**Linux/macOS:**
```bash
base64 -i your_keystore.jks -o keystore_base64.txt
```
