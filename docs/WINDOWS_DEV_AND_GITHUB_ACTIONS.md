# Windows 开发与 GitHub Actions 云端构建落地指南

本文档专为 **Windows 主力机开发 iOS 应用** 量身定制，提供一套完全脱离本地 Mac、依靠 **「Windows 编码 + 纯文本工程描述 (XcodeGen) + GitHub Actions 自动化云构建」** 的全链路落地方案。

---

## 1. 核心痛点与破解之道

在 Windows 上开发 iOS 最核心的两个障碍是：
1. **没有 Xcode，无法可视化修改 `.pbxproj` 工程文件**：手动编辑 XML/ASCII 极易损坏工程。
2. **没有 macOS 环境，无法本地运行 `xcodebuild` 编译打包**。

### 💡 解决方案组合拳：
* **工程描述**：采用 **`XcodeGen`**（使用极简的纯文本 YAML 文件 `project.yml` 描述工程结构与 SPM 依赖）。在 Windows 上新增 Swift 文件只需在目录中创建，无需手动改写 Xcode 工程配置，提交到云端后一行命令自动生成 `.xcodeproj`。
* **依赖管理**：采用 **Swift Package Manager (SPM)**。不使用任何依赖 Ruby 的 CocoaPods。
* **编译打包**：通过 **GitHub Actions 的 macOS Runner**（免费提供 `macos-14` / `macos-15` M1/M2 算力环境），在云端自动完成依赖拉取、编译、生成 `.ipa` 并发布产物。

---

## 2. Windows 本地开发环境配置

在 Windows 电脑上，只需安装以下三样工具：

### 2.1 基础工具链
1. **Git**：官方安装包，配置全局邮箱与用户名。
2. **Visual Studio Code**：主力代码编辑器。
3. **VS Code 推荐扩展**：
   * `Swift`（SSWG 官方插件，提供语法高亮、自动补全与类型推导提示）
   * `YAML`（用于编辑 `project.yml` 与 GitHub Actions 文件）
   * `GitLens`（方便查看版本与分支）

### 2.2 本地编码规范
* 所有 Swift 源代码统一存放于 `Sources/` 目录下。
* 资源文件（图标、Assets、启动图）统一存放于 `Resources/` 目录下。
* 当你在 Windows 下新增了一个 `.swift` 文件（例如 `Sources/Player/SpeedHelper.swift`），**无需任何配置**，云端 XcodeGen 会自动将该目录下的所有源码递归扫描并加入编译目标。

---

## 3. 声明式工程配置：`project.yml` (XcodeGen)

在项目根目录下维护一份 `project.yml`，彻底解决 Windows 开发者维护 iOS 工程的问题：

```yaml
name: StrmAction
options:
  bundleIdPrefix: top.strmaction
  deploymentTarget:
    iOS: "16.0"
  xcodeVersion: "16.0"

settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: top.strmaction.companion
    INFOPLIST_FILE: Resources/Info.plist
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "5.10"
    TARGETED_DEVICE_FAMILY: "1,2" # 1: iPhone, 2: iPad
    ENABLE_BITCODE: NO

packages:
  # 引入开源播放器框架 KSPlayer（基于 FFmpeg + Metal，原生支持 302 重定向维持 Header）
  KSPlayer:
    url: https://github.com/kingslay/KSPlayer.git
    from: 2.2.0

targets:
  StrmAction:
    type: application
    platform: iOS
    sources:
      - Sources
      - Resources
    dependencies:
      - package: KSPlayer
        product: KSPlayer
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_BITCODE: NO
        # 免签归档：CI 直接打包未签名 IPA
        CODE_SIGNING_ALLOWED: NO
        CODE_SIGNING_REQUIRED: NO
        CODE_SIGN_IDENTITY: ""
        ENABLE_USER_SCRIPT_SANDBOXING: NO
```

> 后台音频（`UIBackgroundModes: audio`）与 ATS 例外声明写在 `Resources/Info.plist` 里，不在 `project.yml` 中配置。

---

## 4. GitHub Actions 云端构建流水线

在 `.github/workflows/build.yml` 中配置完整的 CI 流程。它在三种情况下启动一台搭载 M 系列芯片的 macOS 虚拟机自动编译并打包产物：

| 触发 | 操作 | 说明 |
|---|---|---|
| **手动触发**（日常出包） | `gh workflow run build.yml --ref main`，或 Actions 页面点 "Run workflow" | 首选方式 |
| **打标签** | `git tag v1.0.0 && git push origin v1.0.0` | 构建的同时自动创建 GitHub Release |
| **Pull Request** | 往 main 开 PR | 每次推送 PR 分支都会再跑一遍 |

> ⚠️ **普通 `git push` 到 main 不再触发构建**（2026-10 起调整）。本地推代码只更新仓库，需要出包时请用上面的手动触发或打标签。

### 4.1 流水线执行流程
1. **环境准备**：使用 `macos-14`（配备 Xcode 16.x，脚本依次探测 16.2 / 16.1 / 16.0）。
2. **安装 XcodeGen**：通过 Homebrew 安装 `xcodegen`。
3. **生成工程**：运行 `xcodegen generate`，根据 `project.yml` 即时生成 `StrmAction.xcodeproj`。
4. **编译与归档**：使用 `xcodebuild archive` 进行 Release 构建（针对通用 iOS 设备 `generic/platform=iOS`）。
5. **提取并生成 IPA**：将编译出的 `StrmAction.app` 打包为免签/自签名 `StrmAction.ipa`。
6. **产物上传**：将 `.ipa` 上传至 GitHub Actions Artifacts（并在发布 Git Tag 时自动创建 GitHub Release）。

---

## 5. 手机端安装与签名测试方式

云端构建生成的 `StrmAction.ipa` 可以通过以下三种无缝方式安装到你的 iPhone / iPad 上进行测试：

### 途径 A：巨魔商店（TrollStore - 最爽方案）
* **适用**：iOS 14.0 - 16.6.1 / 17.0（已安装 TrollStore 的设备）。
* **操作**：直接在手机 Safari 打开 GitHub Actions 页面下载 `StrmAction.ipa`，点击使用 TrollStore 打开，永久免签安装，无任何证书过期问题。

### 途径 B：AltStore / Sideloadly（免费个人证书侧载）
* **适用**：所有常规未越狱 iOS 设备（包括最新 iOS 17/18）。
* **操作**：
  1. 在 Windows 电脑上安装 **Sideloadly** 或 **AltServer**（完全支持 Windows）。
  2. 将手机连接到电脑，或在同一局域网 Wi-Fi 下。
  3. 将从 Actions 下载的 `StrmAction.ipa` 拖入 Sideloadly，输入自己的 Apple ID 即可免费签名并直装到手机，拥有 7 天有效期（支持自动续签）。

### 途径 C：正式 TestFlight 自动化分发（可选，需 Apple 开发者账号）
若拥有 99 美元/年的 Apple 开发者账号，可在 GitHub Secrets 中配置：
* `APP_STORE_CONNECT_API_KEY_ID`
* `APP_STORE_CONNECT_API_ISSUER_ID`
* `APP_STORE_CONNECT_API_PRIVATE_KEY`
流水线即可通过 Fastlane 或 `altool` 自动将构建版本直传 TestFlight，手机端直接通过 TestFlight App 收到推送更新。

---

## 6. Windows 开发日常工作流总结

```text
  1. 在 Windows 上用 VS Code 编写 Swift 代码或修改 project.yml
                         │
                         ▼
  2. 提交代码并推送到 GitHub (git push origin main)
                         │
                         ▼
  3. 手动触发云端构建（push 本身不再自动触发）：
     gh workflow run build.yml --ref main
     或 Actions 页面点 "Run workflow" / 推 v* 标签
                         │
                         ▼
     GitHub Actions 拉起 macOS Runner：
     • xcodegen 生成工程
     • xcodebuild 编译打包
     • 输出 StrmAction.ipa
                         │
                         ▼
  4. 手机端通过浏览器下载 IPA（或通过 Sideloadly 侧载安装），在真机上验证
```
*整个过程 0 本地 Mac 依赖，完全闭环。*
