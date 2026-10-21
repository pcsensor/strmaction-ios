# StrmAction iOS Companion（iOS 伴侣端）

> 面向 StrmAction 媒体库的 iOS / iPadOS 原生伴侣外壳。
> 继承 StrmAction 核心设计哲学：**不转码、不代理视频流、零服务端带宽消耗**。

---

## 1. 项目简介

本仓库是 **StrmAction** 的 iOS 客户端实现，专为补全 Apple 生态而设计。

与 Android 伴侣端（`companion`）与桌面端（`desktop`）一致，iOS 端遵循 **Web-First 混合架构**：
* **业务界面 100% 复用 Web**：通过 `WKWebView` 完整加载服务器部署的 StrmAction Web 前端，直接获得海报墙、选集、详情、搜索、用户权限隔离等全量功能；
* **原生播放器内核直连**：网页点击播放后，原生层直接向服务端请求网盘直链与鉴权头，交给原生播放器内核解码渲染，支持 HTTP 302 重定向保持 Headers、音轨与外挂 ASS 字幕切换；
* **独立心跳上报**：播放时以 5 秒为周期向服务端回传进度（`play_token` 独立鉴权），断点续播、已看判定与无缝连播体验完备。

---

## 2. 核心文档导航（必读）

为确保在新设备或异构环境（如 Windows）下开发**没有任何理解分歧、能够一次性完成所有功能**，所有详细规格与设计规范均已编撰入 `docs/` 目录：

| 文档 | 核心内容 | 重点关注 |
|---|---|---|
| 📖 [**系统架构设计 (ARCHITECTURE.md)**](docs/ARCHITECTURE.md) | • 整体架构分层与数据流向<br>• 为什么不能使用系统 AVPlayer（302 Header 丢失避坑）<br>• KSPlayer / libmpv 播放器选型与设计原则 | 架构全景、避坑指南、生命周期 |
| 🔌 [**接口与通信规范 (API_AND_JSBRIDGE.md)**](docs/API_AND_JSBRIDGE.md) | • 网页与原生 JSBridge 通信契约 (`window.StrmActionNative`)<br>• 连通性测试接口 (`GET /api/health`)<br>• 播放分发接口完整字段解析 (`POST /api/play/{itemId}`)<br>• 5 秒进度心跳上报规范 (`POST /api/items/{id}/progress`) | 接口字段契约、Cookie 与 play_token 双层鉴权 |
| 🎬 [**播放器与交互规范 (PLAYER_AND_UI_SPEC.md)**](docs/PLAYER_AND_UI_SPEC.md) | • 现代暗黑矢量 UI 风格与主题色 (`#07080A`, `#E8B06A`)<br>• 三层缓冲进度条 (BufferedSeekBar)<br>• **40% 右侧侧滑抽屉**（选集列表、倍速面板、音轨字幕）<br>• 手势体系（双击快进退、长按极速播放与触觉震动反馈）<br>• iOS 原生特性（画中画 PiP、锁屏 NowPlaying） | UI 布局、手势交互细节、抽屉与反馈 |
| 🛠️ [**Windows 开发与 Actions 云构建 (WINDOWS_DEV_AND_GITHUB_ACTIONS.md)**](docs/WINDOWS_DEV_AND_GITHUB_ACTIONS.md) | • **Windows 电脑免 Mac 开发方案**（VS Code + Swift 插件）<br>• 声明式工程配置 (**XcodeGen** `project.yml`)<br>• GitHub Actions 云端 macOS 自动化编译与打包 `.ipa`<br>• 巨魔商店 (TrollStore) / 个人免费签名 (Sideloadly) 安装指南 | Windows 工作流、Actions 脚本、IPA 安装 |

---

## 3. 目录与工程结构

```text
strmaction-ios/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 云端自动编译并打包 IPA 流水线
├── docs/                         # 项目完备规范与技术文档
│   ├── ARCHITECTURE.md           # 架构设计与技术选型
│   ├── API_AND_JSBRIDGE.md       # API 与 JSBridge 契约规范
│   ├── PLAYER_AND_UI_SPEC.md     # 播放器 UI、手势与抽屉设计规范
│   └── WINDOWS_DEV_AND_GITHUB_ACTIONS.md  # Windows 开发与 Actions 云构建指南
├── project.yml                   # XcodeGen 声明式工程配置文件（免手动编辑 xcodeproj）
├── Resources/
│   └── Info.plist                # 应用权限、后台音频与网络安全声明
├── Sources/                      # Swift 源代码
│   ├── App/
│   │   └── StrmActionApp.swift   # 应用入口与全局状态
│   ├── Bridge/
│   │   └── StrmActionBridge.swift# 网页 JSBridge 注入与事件代理
│   ├── Model/
│   │   └── PlayModels.swift      # 完整 Codable 数据模型
│   ├── Network/
│   │   └── PlayApi.swift         # 服务端 API 请求层
│   ├── Player/
│   │   └── PlayerView.swift      # 原生播放界面、手势控制与 40% 抽屉
│   ├── Progress/
│   │   └── ProgressEngine.swift  # 5 秒进度心跳上报引擎
│   ├── Setup/
│   │   └── SetupView.swift       # 首次服务器配置与连通性测试
│   └── Web/
│       └── WebContainerView.swift# WKWebView 容器视图
├── .gitignore                    # Git 忽略配置
└── README.md                     # 本入口文档
```

---

## 4. 快速开始（针对 Windows 开发）

1. **克隆本仓库并在 Windows 上打开**：
   使用 VS Code 打开本仓库目录，安装 `Swift` 扩展。
2. **编辑代码与新增功能**：
   所有业务代码均位于 `Sources/`，新增文件直接创建即可，无需配置 Xcode 工程。
3. **提交并推送到 GitHub**：
   ```bash
   git add .
   git commit -m "feat: your feature"
   git push origin main
   ```
4. **云端自动编译与提取安装包**：
   * 打开 GitHub 仓库的 **Actions** 标签页；
   * 等待构建任务执行完毕（约 2~3 分钟）；
   * 在构建产物（Artifacts）中直接下载编译好的 **`StrmAction-iOS-IPA`**；
   * 使用 **Sideloadly** 免费签名安装至 iPhone，或通过 **TrollStore** 永久免签安装测试。

---

## 5. 开发检查清单（Definition of Done）

在其他设备接手开发时，按以下清单验收功能完整性：

- [x] **配置引导**：启动时可配置服务器 URL，支持 `GET /api/health` 连通性测试与错误原因反馈。
- [x] **Web 容器**：`WKWebView` 正常加载前端，正确注入 `window.StrmActionNative`，Cookie 状态维持。
- [x] **安全通信**：JSBridge 只接收配置域名下的请求，通过原生层直接向服务端请求播放直链与 `play_token`。
- [x] **播放内核**：支持自定义 Request Headers（User-Agent, Referer）并在 HTTP 302 重定向中保持。
- [x] **进度心跳**：播放中每 5 秒上报进度，90% 标记已看，暂停/退后台/退出立即补发，支持 401 过期处理。
- [x] **交互体验**：中心大播放按键、双击快退/快进 10 秒、长按倍速并触发 Taptic Engine 触觉震动。
- [x] **40% 侧滑抽屉**：选集卡片列表（高亮当前集、勾选已看）、倍速面板平滑呼出与收回。
- [x] **连播与兜底**：播完自动根据 `next_item_id` 无缝连播；15 秒加载超时主动提示并支持复制直链。
- [x] **iOS 系统级特性**：画中画 (PiP) 正常激活，锁屏及控制中心可同步剧名与进度条。
