# StrmAction iOS 伴侣端（Architecture & Technical Specification）

本文档定义了 **StrmAction iOS Companion** 的系统架构、设计原则与技术选型，消除开发中的所有理解分歧。

---

## 1. 核心定位与设计哲学

StrmAction 是一个面向 `.strm` 媒体库的「刮削 + 展示 + 播放分发」系统。iOS 端的核心设计哲学必须严格与整个 StrmAction 生态对齐：

1. **零服务端带宽、零转码**：
   - 服务端绝对不代理视频流，也不对视频进行转码。
   - iOS 客户端直接从网盘 CDN 直连拉取视频流（通常经过 AList 等服务的 302 重定向直达百度网盘、阿里云盘等 CDN）。
2. **最大化复用现有 Web 前端（Web-First Container）**：
   - 媒体库浏览、海报墙、详情、季/集展示、搜索、用户登录、设置等功能 **100% 复用服务器部署的前端 Web UI**。
   - iOS 端只充当轻量壳（App 容器），不需要也不应该使用原生 Swift 重新实现一套媒体库页面。
3. **原生播放与独立进度心跳**：
   - 网页只负责通过 JSBridge 通知原生层播放某个条目（`itemId`）。
   - 原生层直接向服务端请求播放参数（直链、自定义 Headers、`play_token`）。
   - 播放流由原生播放器负责渲染，同时在后台以固定心跳（默认 5 秒）使用独立的 `play_token` 向服务端上报进度，网页不接触播放直链与鉴权凭证。

---

## 2. 为什么不能使用 iOS 原生 AVPlayer（关键技术避坑）

在 iOS 音视频开发中，必须明确为何放弃系统自带的 `AVPlayer`：

| 维度 | 系统 AVPlayer | 解决方案（推荐 KSPlayer / libmpv） |
|---|---|---|
| **302 重定向 Header 丢失（致命）** | `AVPlayer` 即使通过字典设置了 `User-Agent` 与 `Referer`，遇到 HTTP 302 重定向（AList → 网盘真实 CDN）时，**iOS 底层网络栈会强制丢弃自定义 Headers**，导致网盘 CDN 防盗链直接返回 `403 Forbidden`。 | 专用播放器内核基于 FFmpeg 网络层或自定义网络 Session，在 302 重定向后**持久保持请求头**，网盘鉴权 100% 成功。 |
| **容器格式支持** | 仅支持 MP4 / MOV / M4V / HLS。常见的 MKV、WebM 封装无法播放。 | 原生支持 MKV、WebM、MP4、TS 等主流与冷门封装。 |
| **字幕渲染** | 仅支持内嵌 WebVTT、简单 SRT，无法渲染动漫与影视常用的高级 ASS/SSA 特效字幕。 | 支持 libass 原生渲染，字体样式、屏幕定位、动态字幕完全还原。 |
| **音轨解码** | 不支持 AC3、E-AC3、DTS 等受版权或专利限制的常见音轨。 | 包含 FFmpeg 软解/硬解补全，音轨切换无杂音。 |

> **强制选型原则**：iOS 端必须采用基于 **FFmpeg / libmpv** 的播放器框架（首选 **KSPlayer** 或 **mpvKit / libmpv**），绝不可单纯使用 `AVPlayer` 直连网盘。

---

## 3. 总体架构与数据流向

整个 App 包含四个核心层次：

```
┌────────────────────────────────────────────────────────┐
│                   StrmAction iOS App                   │
├────────────────────────────────────────────────────────┤
│  1. 配置层 (SetupView)                                  │
│     • 首次启动引导 / 设置中重设服务器                     │
│     • 输入服务器地址 (如 http://192.168.1.10:8080)       │
│     • 连通性测试 (GET /api/health)                       │
│     • 配置持久化 (UserDefaults)                          │
├────────────────────────────────────────────────────────┤
│  2. Web 容器层 (MainWebViewController)                 │
│     • 全屏 WKWebView 加载 StrmAction Web                │
│     • Cookie 同步与持久化                                │
│     • 注入 JSBridge: window.StrmActionNative            │
│         - play(itemId)                                 │
│         - playExternal(itemId)                         │
│         - openSettings()                               │
│         - isCompanion() -> true                        │
│         - isTV() -> false (iPhone/iPad) / true (tvOS)  │
├────────────────────────────────────────────────────────┤
│  3. 原生播放调度 (PlayerViewController)                 │
│     • POST /api/play/{itemId} (携带 Web 会话 Cookie)     │
│     • 解析 play_url, headers, resume_ms, play_token    │
│     • 初始化 KSPlayer / libmpv 播放器                   │
│     • 手势控制 (双击快进退、长按倍速震动反馈)            │
│     • 40% 右侧侧滑抽屉 (选集列表、倍速切换、音轨字幕)     │
│     • 原生画中画 (PiP) 与锁屏控制中心集成                │
├────────────────────────────────────────────────────────┤
│  4. 进度同步引擎 (ProgressEngine)                        │
│     • 独立后台定时器 (默认 5 秒心跳)                     │
│     • 队列式上报 POST /api/items/{id}/progress         │
│     • 凭证: Authorization: Bearer <play_token>         │
│     • 暂停 / 退后台 / 播放完成强制补发                    │
│     • 播放结束自动无缝连播 next_item_id                  │
└────────────────────────────────────────────────────────┘
```

---

## 4. 核心组件与职责划分

### 4.1 SetupView（配置模块）
* 负责配置与测试 StrmAction 服务器地址。
* 请求 `GET /api/health` 验证服务是否存活及版本号。
* 保存以下配置至 `UserDefaults`：
  * `server_url`：服务器完整地址（标准化去除结尾 `/`）。
  * `cache_limit_mb`：本地播放缓存限制（默认 128MB）。
  * `tls_trusted_anchors_v1`：用户导入的自签名根证书（由 `TLSTrustStore` 维护）。

> 自签名不再有全局开关，也不再按主机固定叶子证书。
> 信任以「导入私有 CA 的自签名根证书」表达，
> 可在 SetupView 的「证书信任」入口导入与移除。

### 4.1.1 信任层（Trust）

自签名 HTTPS 的处理集中在 `Sources/Trust/`，遵循**一种传输栈、一处信任策略**：

| 模块 | 职责 |
|---|---|
| `TLSTrustStore` | 保存用户导入的自签名根证书、持久化；生成 FFmpeg 用的 CA bundle |
| `TLSProbe` | `NWConnection` 完成一次 TLS 握手，捕获证书链 |
| `SecurityPolicy` | 唯一信任判定，URLSession 委托与媒体通道共用同一份数据 |

判定顺序固定为两条：可由公共根验证 → 交给系统；
否则必须落到已导入的自签名根上，且主机名匹配。

**为什么不固定叶子证书**：Caddy 内部 CA 签发的叶子证书有效期只有 12 小时，
固定它的指纹等于每半天失效一次；轮换过程中不变的是签发它的 CA。
同时 FFmpeg 的 TLS 后端没有开启 `X509_V_FLAG_PARTIAL_CHAIN`，
信任锚必须是**自签名根**——中间证书放进 `ca_file` 照样报
`unable to get issuer certificate`，叶子证书更不行。

媒体字节**只走 FFmpeg 自己的 HTTP/TLS 栈**，不经过任何中间进程：
`MediaTransport` 把原始 URL、服务端下发的请求头、以及
`ca_file`（公共根 ＋ 已导入根证书）组装成 `KSOptions` 交给播放器。
`URLSession` 仅用于 KB 级 API（play 接口、字幕、进度上报）。

播放前 `SecurityPolicy.ensureTrusted(for:)` 先用同一套锚点做一次严格评估
（`SecTrustSetAnchorCertificatesOnly(true)`，与 `ca_file` 替换默认信任库的行为一致），
不通过就当场报错并给出导入提示，不把问题丢给 FFmpeg。

### 4.2 MainWebViewController（网页容器）
* 承载完整的 Web 端业务体验。
* 页面下拉刷新、顶部安全区背景着色（对齐主题背景色 `#07080A`）。
* 设置 `WKUserContentController`，在 `document_start` 时注入 `window.StrmActionNative` 桥接对象。
* 支持系统文件选择器（处理网页端上传自定义海报/背景图的需求）。

### 4.3 PlayerViewController（原生播放界面）
* 现代暗色风格播放器，完全对齐 Android 伴侣端：
  * **手势**：
    * 单击屏幕切换控件显示/隐藏（播放中 4.5 秒自动淡出）。
    * 双击左侧 35% 区域快退 10 秒；双击右侧 35% 区域快进 10 秒；双击中间播放/暂停。
    * 任意区域长按触发 iPhone Taptic Engine 震动反馈，进入快速倍速播放（1.5x~3.0x 可配），松手立即恢复正常播放速率。
  * **40% 右侧抽屉**：
    * 选集抽屉：展示同季/同系列全部剧集卡片，高亮当前集，打勾已看集，点击平滑无缝切集。
    * 倍速面板：0.5x、0.75x、1.0x、1.25x、1.5x、2.0x、3.0x 及长按倍速设定。
    * 音轨与字幕：内封音轨选择、服务端下发外挂字幕切换。
  * **画中画与后台**：
    * 支持 `AVPictureInPictureController`，退后台自动进入画中画模式。
    * 接入 `MPNowPlayingInfoCenter`，锁屏界面展示剧名、海报与进度条，支持耳机和车载线控。

### 4.4 ProgressEngine（进度心跳引擎）
* 单例维护的可靠上报队列，不因播放退出或偶发网络抖动丢失断点：
  * 维护最多 3 条心跳队列，失败自动在下个心跳重试。
  * 状态变更关键点立即补写：用户主动暂停、退入后台、播放到 90% 标记 `finished: true`、到达片尾。
  * 当收到 HTTP 401 时停止上报并向 UI 提示「凭证失效，请重新播放」。
