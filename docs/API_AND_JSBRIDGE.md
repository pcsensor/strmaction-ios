# StrmAction 接口与 JSBridge 通信规范

本文档详尽列出 **StrmAction iOS Companion** 所需的所有网络接口、认证模式以及与前端网页之间的 JSBridge 通信契约。所有字段均与服务端及前端现有逻辑严格一致。

---

## 1. 认证机制（Authentication）

StrmAction 采用**双层认证**分离机制：

1. **用户会话层（Cookie 鉴权）**：
   - 作用域：网页端常规浏览、设置、检索以及发起 `/api/play/{item_id}` 请求。
   - 流程：用户在 `WKWebView` 网页中完成登录后，服务端下发 `session_id` Cookie（或 token Cookie）。
   - 原生层处理：原生发起 `/api/play/{item_id}` 时，通过 `WKWebsiteDataStore.default().httpCookieStore` 读取对应 host 下的全部 Cookie，并在请求头中附加 `Cookie: <cookie_string>`。
2. **播放与进度上报层（Bearer play_token 鉴权）**：
   - 作用域：仅用于单个视频条目的进度上报接口 `/api/items/{id}/progress` 以及外挂字幕拉取。
   - 流程：`/api/play/{item_id}` 接口下发专属的 `play_token`（12小时有效，绑定当前条目与当前登录用户）。
   - 原生层处理：原生播放器上报进度时，**严禁携带用户 Cookie**，只在请求头中添加 `Authorization: Bearer <play_token>`。这样解耦了用户凭证与后台上报流程，杜绝泄露风险。

---

## 2. 网页 ↔ 原生 JSBridge 契约

前端通过全局对象 `window.StrmActionNative` 判断是否运行在原生伴侣端，并调用原生层能力。

### 2.1 注入时机与实现

在 `WKWebView` 配置中，通过 `WKUserScript` 在 `WKUserScriptInjectionTimeAtDocumentStart`（即 DOM 加载前）注入以下 JavaScript 代码：

```javascript
(function() {
  window.StrmActionNative = {
    // 标记当前处于伴侣 App 壳中
    isCompanion: function() {
      return true;
    },
    // 是否为电视模式（iPhone/iPad 返回 false，Apple TV 返回 true）
    isTV: function() {
      return false;
    },
    // 返回客户端版本号
    version: function() {
      return "1.0.0";
    },
    // 当前绑定的服务器 host（用于安全来源过滤）
    serverHost: function() {
      return "%SERVER_HOST%";
    },
    // 播放指定条目（内置播放器）
    play: function(itemId) {
      window.webkit.messageHandlers.StrmActionBridge.postMessage({
        action: "play",
        itemId: Number(itemId)
      });
    },
    // 调用外部播放器兜底
    playExternal: function(itemId) {
      window.webkit.messageHandlers.StrmActionBridge.postMessage({
        action: "playExternal",
        itemId: Number(itemId)
      });
    },
    // 打开 App 内的服务器设置页
    openSettings: function() {
      window.webkit.messageHandlers.StrmActionBridge.postMessage({
        action: "openSettings"
      });
    }
  };
})();
```

### 2.2 原生拦截与处理（Swift 规范）

在原生端，实现 `WKScriptMessageHandler`：

```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "StrmActionBridge" else { return }
    guard let body = message.body as? [String: Any],
          let action = body["action"] as? String else { return }
    
    // 安全校验：只接受当前配置的服务器域名发出的消息
    guard let url = message.webView?.url,
          let host = url.host,
          host.caseInsensitiveCompare(configuredHost) == .orderedSame else {
        print("[StrmActionBridge] 来源安全拦截: \(url.absoluteString)")
        return
    }

    switch action {
    case "play":
        if let itemId = body["itemId"] as? Int {
            self.startPlayback(itemId: itemId, external: false)
        }
    case "playExternal":
        if let itemId = body["itemId"] as? Int {
            self.startPlayback(itemId: itemId, external: true)
        }
    case "openSettings":
        self.presentSetupView()
    default:
        break
    }
}
```

---

## 3. 服务端 HTTP API 详尽规范

所有 API 基准地址为用户配置的服务器地址（例如：`http://192.168.1.10:8080`，以下用 `{{BASE_URL}}` 表示）。

### 3.1 连通性测试（健康检查）

用于配置页面测试服务器是否正常运行。

* **Method**：`GET`
* **Path**：`{{BASE_URL}}/api/health`
* **Headers**：
  * `X-StrmAction-Companion: 1`
* **Response** (200 OK)：
  ```json
  {
    "ok": true,
    "version": "1.2.0"
  }
  ```
* **校验逻辑**：只有当 HTTP 状态码为 200 且 `ok == true` 时，才允许用户点击「保存并进入」。

---

### 3.2 播放分发接口（核心）

原生层获取视频直链与播放配置的关键入口。

* **Method**：`POST`
* **Path**：`{{BASE_URL}}/api/play/{itemId}`
* **Headers**：
  * `Content-Type: application/json`
  * `Accept: application/json`
  * `X-StrmAction-Companion: 1`
  * `User-Agent: StrmActionCompanion/1.0.0 (iOS; Darwin)`
  * `Cookie: {{WEBVIEW_COOKIE}}`
* **Request Body** (JSON)：
  ```json
  {
    "mode": "builtin"
  }
  ```
  *(注：如果由 playExternal 触发，则 mode 填 `"external_mpv"`)*

* **Response (200 OK) 完整 JSON 结构**：
  ```json
  {
    "mode": "builtin",
    "requested_mode": "builtin",
    "downgraded": false,
    "downgrade_reason": null,
    "item_id": 105,
    "kind": "episode",
    "series_id": 12,
    "series_title": "怪奇物语",
    "title": "怪奇物语 S01E01 消失的威尔·拜尔斯",
    "library": "欧美剧集",
    "play_url": "https://pan.example.com/direct/xxxx?sign=yyyy",
    "resume_ms": 125000,
    "duration_ms": 2890000,
    "headers": {
      "User-Agent": "pan.baidu.com",
      "Referer": "https://pan.baidu.com/"
    },
    "headers_hint": "User-Agent: pan.baidu.com",
    "play_token": "pt_eyJhbGciOi...",
    "play_token_expires_at": 1729500000,
    "progress_interval_ms": 5000,
    "cache_limit_mb": 128,
    "fallback_on_error": true,
    "media_file_id": 420,
    "next_item_id": 106,
    "next_title": "第一季 第二集 枫树街上的怪人",
    "next_episode_code": "S01E02",
    "subtitles": [
      {
        "label": "简体中文 (内嵌提取)",
        "lang": "chi",
        "filename": "Stranger.Things.S01E01.chi.ass",
        "format": "ass",
        "mime": "text/x-ssa",
        "url": "/api/items/105/subtitles/0?pt=pt_eyJhbGciOi..."
      }
    ],
    "playlist": [
      {
        "id": 105,
        "title": "消失的威尔·拜尔斯",
        "season_no": 1,
        "episode_no": 1,
        "code": "S01E01",
        "watched": false,
        "current": true
      },
      {
        "id": 106,
        "title": "枫树街上的怪人",
        "season_no": 1,
        "episode_no": 2,
        "code": "S01E02",
        "watched": false,
        "current": false
      }
    ],
    "current_index": 0
  }
  ```

#### 关键字段含义与处理要求：
1. **`play_url`**：直链视频地址（必须由播放内核直连播放，不经过任何中间代理）。
2. **`headers`**：按媒体库配置下发的 HTTP 请求头字典（必须原样配置给播放内核网络层，不可丢失）。
3. **`resume_ms`**：断点续播位置（毫秒）。当 `resume_ms > 0` 时，播放器初始加载完成后自动跳转（Seek）到该位置。
4. **`duration_ms`**：视频预计总时长（毫秒，可能为 `null`，以播放器实际读取时长优先）。
5. **`play_token`**：进度回传的令牌凭证，有效期 12 小时。
6. **`progress_interval_ms`**：心跳上报周期（通常为 5000ms）。
7. **`cache_limit_mb`**：播放器内存预读缓冲上限（默认 128MB）。
8. **`playlist`**：当前季或当前文件夹下的选集列表，用于右侧抽屉展示与切集。
9. **`next_item_id`**：当前集播完后无缝连播的目标 ID。

---

### 3.3 进度心跳上报接口

视频播放过程中，周期性向服务端回传观看进度。

* **Method**：`POST`
* **Path**：`{{BASE_URL}}/api/items/{itemId}/progress`
* **Headers**：
  * `Content-Type: application/json`
  * `Authorization: Bearer {{play_token}}`
  * `X-StrmAction-Companion: 1`
* **Request Body** (JSON)：
  ```json
  {
    "position_ms": 45000,
    "duration_ms": 2890000,
    "finished": false
  }
  ```
* **Response** (200 OK)：
  ```json
  {
    "ok": true,
    "item_id": 105,
    "position_ms": 45000,
    "finished": false
  }
  ```

#### 上报与防重规则：
1. **周期性**：播放期间按照 `progress_interval_ms` 间隔上报（默认 5 秒）。
2. **已看标记**：当 `position_ms / duration_ms >= 0.90`（即播放超过 90%）或者触发播放完成事件时，`finished` 必须置为 `true`。
3. **关键事件瞬时补发**：
   - 用户主动点击暂停时，立即上报一次。
   - 用户切入后台（`sceneDidEnterBackground`）或退出播放页面时，立即上报一次。
4. **网络容错**：本地维护一个最多保留 3 条记录的待发队列。网络异常时不阻塞播放，待下次心跳触发时自动补发最新位置。
5. **凭证过期**：若收到 HTTP 401，立即终止定时器，并在播放界面提示「播放凭证已过期，请重新进入播放」。

---

### 3.4 字幕拉取接口

如果返回的 `subtitles` 列表中包含外挂字幕：

* **URL 补全**：若 `subtitles[i].url` 为相对路径（如 `/api/items/...`），需自动拼接为 `{{BASE_URL}} + url`。
* **自带凭证**：服务端返回的字幕 URL 后方已经包含了 `?pt={{play_token}}` 鉴权参数，直接发起 GET 请求即可拉取字幕内容文件并交给渲染模块解析。
