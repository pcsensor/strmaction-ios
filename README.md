# StrmAction iOS Companion

> 面向 StrmAction 媒体库的 iOS / iPadOS 原生伴侣端。
> 继承 StrmAction 核心设计哲学：**不转码、不代理视频流、零服务端带宽消耗**。

[![Build iOS App](https://github.com/pcsensor/strmaction-ios/actions/workflows/build.yml/badge.svg)](https://github.com/pcsensor/strmaction-ios/actions/workflows/build.yml)
![iOS](https://img.shields.io/badge/iOS-16.0%2B-0A84FF?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-16.0%2B-179BFC?logo=xcode&logoColor=white)
![Platform](https://img.shields.io/badge/platform-iOS%20%2F%20iPadOS-lightgrey)
![Bundle](https://img.shields.io/badge/bundle-top.strmaction.companion-8A8A8A)

---

## 目录

- [特性](#特性)
- [架构](#架构)
- [目录结构](#目录结构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [安装到设备](#安装到设备)
- [使用说明](#使用说明)
- [故障排查](#故障排查)
- [项目文档](#项目文档)
- [开发规约](#开发规约)
- [贡献指南](#贡献指南)
- [许可证](#许可证)
- [致谢](#致谢)

---

## 特性

### 播放内核

| 能力 | 说明 |
|---|---|
| 原生解码 | 基于 [KSPlayer](https://github.com/kingslay/KSPlayer) 2.2.0（FFmpeg + Metal），不使用系统 AVPlayer（后者会在 302 重定向中丢失请求头） |
| 请求头透传 | 服务端下发的 `User-Agent` / `Referer` 等自定义头在重定向链路上完整保持 |
| 外挂字幕 | ASS / SRT 字幕独立渲染层，可随时切换或关闭 |
| 画中画 | 支持 PiP 激活与后台音频播放，锁屏 / 控制中心同步剧名与进度 |
| 无缝连播 | 播完依据 `next_item_id` 自动接下一集 |

### 磁盘缓存层（自研）

原生播放器直连源站时，一旦 seek 就会重复下载已看过的内容。本项目在 FFmpeg 与源站之间插入一层**本地回环 HTTP 缓存服务**：

- **本地 HTTP 服务**：FFmpeg 只连 `127.0.0.1:<随机端口>/<token>`，源站地址与鉴权头不下发给播放器；
- **稀疏文件 + 区间索引**：`data.bin` 按绝对偏移随机写，内存里维护已合并的已落盘区间，**任意位置是否拉过**可 O(1) 判定；
- **seek 不重复下载**：拖回已缓存区间直接读盘，零网络流量；
- **退出即清空**：会话结束（`destroy`）整目录删除，不留残余。

### 流量控制（缓冲设置真正生效）

缓存层插在中间会切断 TCP 背压，源站会无视播放器需求全速推完整个文件。本项目在缓存层实现了**下游消费驱动的平滑水位**：

- 水位 = `已拉取字节 − 已消费字节`，已消费由播放位置按总时长折算回写；
- 未达目标时全速拉取，达到目标后**限速**跟随片源码率（×1.15），socket 持续排空，源站不会因空闲而断连；
- 只有当本地在途量积压到 8 MB（下游彻底不读）才真正停止接收，纯本地背压，不会死锁。

因此「设置 → 缓冲大小」是**真的生效**的：起播与 seek 时全速追，水位填满后网速自动收敛到码率附近。

### 其他

- **自建 CA 信任**：支持导入并管理私有根证书（PEM 文件 / 粘贴），自建 HTTPS 服务可正常播放；
- **实时网速**：底栏显示当前回源速率，低于 20 KB/s 自动隐藏；
- **进度条**：已播放金橙实心 + **已缓存区间白色细横线**（支持多段，seek 后的空洞留白）+ 白色竖线指示当前位置；
- **系统级亮度 / 音量**：拖动即改系统设置，退出播放器时自动还原；
- **手势**：双击快进退 10 秒、长按极速播放（松手自动复位）、锁定控件；
- **侧滑抽屉**：选集、播放速度、画面比例、字幕、下一集、证书信任、诊断日志；
- **诊断日志**：App 内查看 / 复制 / 清空，无 Xcode 也能定位问题。

---

## 架构

```text
┌─────────────────────────────────────────────────────────────┐
│  Web 层        WKWebView 完整加载 StrmAction Web 前端        │
│                海报墙 / 选集 / 详情 / 搜索 / 权限隔离          │
└───────────────────────┬─────────────────────────────────────┘
                        │ window.StrmActionNative (JSBridge)
┌───────────────────────▼─────────────────────────────────────┐
│  原生层        /api/play/{itemId} 取直链 + 鉴权头            │
│                play_token 独立鉴权，仅走 KB 级元数据           │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  磁盘缓存层        本地回环 HTTP (127.0.0.1:port/token)│  │
│  │  • RangeStore      稀疏文件 + 已落盘区间索引           │  │
│  │  • CacheServer     命中读盘 / 未命中回源 + 平滑水位限速 │  │
│  │  • OriginClient    手写 HTTP/1.1 over NWConnection     │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │ Range 请求（保持 UA / Referer）   │
└──────────────────────────┼──────────────────────────────────┘
                           ▼
                  源站（网盘直链 / CDN）
```

**媒体字节从不经过 StrmAction 服务端**，服务端只负责元数据与鉴权。

---

## 目录结构

```text
strmaction-ios/
├── .github/
│   └── workflows/
│       └── build.yml                 # GitHub Actions 云端编译并打包 IPA
├── docs/                             # 完备规范与技术文档
│   ├── ARCHITECTURE.md               # 架构设计与技术选型
│   ├── API_AND_JSBRIDGE.md           # API 与 JSBridge 契约规范
│   ├── PLAYER_AND_UI_SPEC.md         # 播放器 UI、手势与抽屉设计规范
│   └── WINDOWS_DEV_AND_GITHUB_ACTIONS.md  # Windows 开发与云构建指南
├── project.yml                       # XcodeGen 声明式工程配置（免手动编辑 xcodeproj）
├── Resources/
│   ├── Assets.xcassets/              # 图标与启动图
│   ├── Info.plist                    # 权限、后台音频与 ATS 声明
│   └── ca/roots.pem                  # 公共根证书包（用于私有 CA 校验）
├── Sources/
│   ├── App/
│   │   └── StrmActionApp.swift       # 应用入口与全局状态
│   ├── Bridge/
│   │   └── StrmActionBridge.swift    # 网页 JSBridge 注入与事件代理
│   ├── Cache/                        # 磁盘缓存层
│   │   ├── CacheServer.swift         #   本地回环 HTTP 服务 + 平滑水位流控
│   │   ├── OriginClient.swift        #   手写 HTTP/1.1 回源客户端（NWConnection）
│   │   ├── RangeStore.swift          #   稀疏文件 + 区间索引
│   │   └── ThroughputSampler.swift   #   回源吞吐滚动窗口采样
│   ├── Model/
│   │   └── PlayModels.swift          # 完整 Codable 数据模型
│   ├── Network/
│   │   └── PlayApi.swift             # 服务端 API 请求层
│   ├── Player/                       # 播放界面与内核适配
│   │   ├── PlayerView.swift          #   播放器主视图与手势
│   │   ├── PlayerControls.swift      #   底栏控制区
│   │   ├── PlayerDrawerView.swift    #   40% 侧滑抽屉
│   │   ├── PlayerUIKit.swift         #   主题色与尺寸常量
│   │   ├── PlayerUIController.swift  #   交互状态机
│   │   ├── PlayerOverlays.swift      #   浮层（字幕 / 提示 / 亮度音量）
│   │   ├── BufferedSeekBar.swift     #   缓冲进度条
│   │   ├── VideoPlayerAdapter.swift  #   KSPlayer 适配层
│   │   ├── MediaTransport.swift      #   KSOptions 构造
│   │   ├── PlaybackSession.swift     #   播放请求与缓冲偏好
│   │   ├── SystemVolumeController.swift  # 系统音量写入
│   │   └── PlayerDiagnostics.swift   #   诊断日志与查看面板
│   ├── Progress/
│   │   └── ProgressEngine.swift      # 5 秒进度心跳上报引擎
│   ├── Setup/
│   │   └── SetupView.swift           # 首次服务器配置与连通性测试
│   ├── Trust/                        # TLS 信任链管理
│   │   ├── TLSTrustStore.swift       #   根证书锚点存储
│   │   ├── CertificateTools.swift    #   链校验
│   │   ├── CertificateTools+Parse.swift  # 最小 ASN.1 解析
│   │   ├── SecurityPolicy.swift      #   统一信任策略
│   │   ├── TLSProbe.swift            #   TLS 探测
│   │   └── TrustManagementView.swift #   证书管理界面
│   └── Web/
│       └── WebContainerView.swift    # WKWebView 容器视图
├── .gitignore
└── README.md
```

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 最低系统 | iOS / iPadOS **16.0** |
| 设备架构 | arm64（iPhone / iPad 通用） |
| 编译工具 | Xcode **16.0+**（CI 依次探测 16.2 → 16.1 → 16.0） |
| Swift | 5.10 |
| 工程生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen) `brew install xcodegen` |
| 播放依赖 | KSPlayer 2.2.0+（SPM 自动解析） |
| 服务端 | 一套 StrmAction 服务端，需提供 `/api/health`、`/api/play/{itemId}`、`/api/items/{id}/progress` |

> **Windows 开发者**：本地**不需要** Xcode 或 Mac。只需 Git + VS Code（含 Swift 扩展）编辑文本，编译交由云端 CI 完成。详见 [`docs/WINDOWS_DEV_AND_GITHUB_ACTIONS.md`](docs/WINDOWS_DEV_AND_GITHUB_ACTIONS.md)。

---

## 快速开始

### 1. 获取代码

```bash
git clone https://github.com/pcsensor/strmaction-ios.git
cd strmaction-ios
```

### 2. 本地开发（Windows / macOS 均可）

所有业务代码位于 `Sources/`。**新增 `.swift` 文件直接在对应目录创建即可，无需改动任何工程配置** —— 云端 XcodeGen 会递归扫描 `Sources/` 与 `Resources/` 并生成 `.xcodeproj`。

工程描述集中在 `project.yml`（Bundle ID、部署目标、SPM 依赖、编译开关），改动它等同于改动 Xcode 工程设置。

### 3. 触发云端构建

> ⚠️ **CI 触发条件**（2026-10 起调整）：
> **普通 `git push` 到 main 不再触发构建。** 三种触发方式：

| 方式 | 命令 / 操作 | 说明 |
|---|---|---|
| **手动触发**（日常出包用这个） | `gh workflow run build.yml --ref main` | 或在 Actions 页面点 "Run workflow" |
| **打标签** | `git tag v1.0.0 && git push origin v1.0.0` | 构建的同时自动创建 GitHub Release |
| **Pull Request** | 往 main 开 PR | 每次推送 PR 分支都会再跑一遍 |

构建流程：`xcodegen generate` → `xcodebuild archive`（免签）→ 打包 `StrmAction.ipa` → 上传 artifact `StrmAction-iOS-IPA`（保留 14 天）。
在 `macos-14` runner 上约需 **4～5 分钟**。

### 4. 取包

Actions 页面 → 对应运行 → Artifacts → 下载 **`StrmAction-iOS-IPA`**（zip，解压后即 `StrmAction.ipa`）。

---

## 安装到设备

产物是**未签名**的 IPA，按你的设备情况选择：

| 方式 | 适用 | 操作 |
|---|---|---|
| **TrollStore** | 已装 TrollStore 的设备 | 手机 Safari 打开 Artifacts 下载 → 用 TrollStore 打开安装，永久免签 |
| **Sideloadly / AltStore** | 任意未越狱设备 | Windows 上装 Sideloadly，拖入 IPA + 填自己的 Apple ID 免费签名；7 天有效期，可自动续签 |
| **TestFlight**（可选） | 有 Apple 开发者账号 | 在仓库 Secrets 配置 App Store Connect API Key，流水线自动上传 TestFlight |

---

## 使用说明

1. **首次启动**：填写 StrmAction 服务端地址 → 点「测试连接」（`GET /api/health`）→ 保存。
2. **浏览与选片**：进入 Web 前端正常使用，海报墙 / 选集 / 详情 / 搜索 / 搜索全部由服务端前端提供。
3. **开始播放**：点击播放后原生层接管，走缓存层直连源站。
4. **私有 CA 服务端**：进入播放器 → 侧滑抽屉 →「证书信任」→ 导入或粘贴根证书（PEM）。
   Caddy 可用 `curl -s http://127.0.0.1:2019/pki/ca/local` 取根证书。
5. **缓冲与缓存**：设置页可调「缓冲大小（MB）」与「磁盘缓存上限（MB）」。
   - 缓冲大小 → 预拉取目标，超过后回源自动限速；
   - 磁盘缓存上限 → 已落盘数据的容量上限，退出播放时清空。

---

## 故障排查

播放器 → 侧滑抽屉 →「诊断日志」可查看并复制实时日志（含时间戳）。

| 现象 | 常见原因 | 处理 |
|---|---|---|
| `avformat can't open input` | 服务端使用自建 CA，根证书未导入 | 抽屉 →「证书信任」导入根证书；诊断日志里 `[trust]` 会打印链校验结果 |
| 提示 TLS `-1200` | `Info.plist` 的 ATS 配置被误改 | 必须保留 `NSAllowsArbitraryLoads=true` 且**删除** `NSAllowsArbitraryLoadsInWebContent` / `NSAllowsLocalNetworking`，否则 URLSession 的自定义信任逻辑不生效 |
| `403 Forbidden` | 源站校验 `User-Agent`，出现重复头 | 头部只允许一处 `User-Agent`（带冒号后空格），缓存层已统一处理 |
| 起播 20 秒超时 | 缓存层限流误伤了 FFmpeg 的探测读取 | 看诊断日志里 `[cache] 回源 @…` 是否反复重启；水位必须相对本次请求起点计算 |
| 网速一直全速 | 预拉取水位未生效 | 确认缓冲大小已设置；日志应出现 `[cache] 预拉取达标 … 限速 …` |
| seek 后重新下载 | 该区间确实没落盘 | 进度条上的白色缓存线显示已落盘区间，落盘范围内拖动不会重下 |

---

## 项目文档

| 文档 | 内容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 架构分层、数据流向、技术选型与避坑指南 |
| [`docs/API_AND_JSBRIDGE.md`](docs/API_AND_JSBRIDGE.md) | 网页与原生 JSBridge 契约、API 字段、双层鉴权 |
| [`docs/PLAYER_AND_UI_SPEC.md`](docs/PLAYER_AND_UI_SPEC.md) | 视觉系统、进度条、手势、抽屉与 iOS 原生特性 |
| [`docs/WINDOWS_DEV_AND_GITHUB_ACTIONS.md`](docs/WINDOWS_DEV_AND_GITHUB_ACTIONS.md) | Windows 开发全链路与云端构建 |

---

## 开发规约

- **新增文件无需改工程**：`.swift` 放进 `Sources/` 对应模块目录即可；
- **模块边界**：`Cache/` 只管字节与流控，`Trust/` 只管证书链，`Player/` 不直接触碰 `Network/` 的会话逻辑；
- **回调线程**：`CacheServer` / `OriginClient` 的回调统一在各自串行队列上，需要更新 UI 的一律切回主线程；
- **日志**：使用 `D.log("tag", "message")`，`tag` 用语义化小写（`cache` / `engine` / `trust` / `buffer` / `state`）；
- **提交信息**：遵循 Conventional Commits（`feat:` / `fix:` / `docs:` / `ci:` / `refactor:`）；
- **CI 是唯一裁判**：Windows 上无法本地编译，**任何改动都必须推上去让 CI 编译通过**才算完成。

---

## 贡献指南

1. Fork 本仓库并新建分支（`feat/xxx` / `fix/xxx`）；
2. 改动请同步更新 `docs/` 中受影响的规范文档；
3. 提交前确认 `git diff` 无意外产物（`build/`、`*.ipa` 不入库）；
4. 开 PR 描述问题与验证方式 —— **PR 会自动触发一次 CI 构建**；
5. 涉及播放器行为的改动，附上真机验证步骤（iOS 版本、机型、片源、关键日志）。

---

## 许可证

本仓库目前**尚未附带 LICENSE 文件**。在许可证确定之前，默认适用「保留所有权利」；若要分发或二次使用，请先在 Issue 中确认授权范围。

---

## 致谢

- [KSPlayer](https://github.com/kingslay/KSPlayer) —— 基于 FFmpeg + Metal 的开源播放器内核，302 重定向保持请求头
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) —— 让 Windows 也能维护 iOS 工程
- [Network.framework](https://developer.apple.com/documentation/network) —— 底层 TCP / TLS 与 HTTP/1.1 手写实现的基础
