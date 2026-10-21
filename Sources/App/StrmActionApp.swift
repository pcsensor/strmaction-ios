import SwiftUI
import WebKit

@main
struct StrmActionApp: App {
    @AppStorage("server_url") private var serverUrl: String = ""
    @State private var showSetup: Bool = false
    @State private var activePlayInfo: PlayResponse?
    @State private var webViewRef: WKWebView?
    @State private var errorMessage: String?
    @State private var bridgeHandler: BridgeHandler?

    // 桥接实例
    private let bridge: StrmActionBridge

    init() {
        let host = URL(string: UserDefaults.standard.string(forKey: "server_url") ?? "")?.host ?? ""
        self.bridge = StrmActionBridge(allowedHost: host)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(hex: "#07080A").ignoresSafeArea()

                if serverUrl.isEmpty {
                    SetupView(isPresented: $showSetup)
                } else {
                    WebContainerView(
                        serverUrl: serverUrl,
                        bridge: bridge,
                        onWebViewCreated: { wv in
                            self.webViewRef = wv
                            self.setupBridgeDelegate()
                        }
                    )
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .sheet(isPresented: $showSetup) {
                SetupView(isPresented: $showSetup)
            }
            .fullScreenCover(item: $activePlayInfo) { playInfo in
                PlayerView(
                    playInfo: playInfo,
                    serverUrl: serverUrl,
                    onClose: {
                        self.activePlayInfo = nil
                    },
                    onSelectEpisode: { nextId in
                        self.fetchAndPlay(itemId: nextId)
                    }
                )
                // fullScreenCover(item:) 在 item 变化时不一定会重新触发 onAppear，
                // 用 itemId 强制重建播放器，确保切集时重新 setup 播放器与定时器。
                .id(playInfo.itemId)
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if serverUrl.isEmpty {
                    showSetup = true
                }
                setupTokenExpiredHandler()
            }
            .onChange(of: serverUrl) { newUrl in
                bridge.allowedHost = URL(string: newUrl)?.host ?? ""
            }
        }
    }

    private func setupTokenExpiredHandler() {
        ProgressEngine.shared.onTokenExpired = {
            DispatchQueue.main.async {
                self.errorMessage = "播放凭证已过期，请重新进入播放"
                self.activePlayInfo = nil
            }
        }
    }

    private func setupBridgeDelegate() {
        bridge.allowedHost = URL(string: serverUrl)?.host ?? ""
        let handler = BridgeHandler(
            onPlay: { itemId in
                self.fetchAndPlay(itemId: itemId)
            },
            onExternalPlay: { itemId in
                self.fetchAndPlay(itemId: itemId, mode: "external_mpv")
            },
            onSettings: {
                self.showSetup = true
            }
        )
        self.bridgeHandler = handler
        bridge.delegate = handler
    }

    private func fetchAndPlay(itemId: Int, mode: String = "builtin") {
        Task {
            do {
                let cookieString = await extractCookies()
                let response = try await PlayApi.shared.fetchPlayInfo(
                    serverUrl: serverUrl,
                    itemId: itemId,
                    cookieString: cookieString,
                    mode: mode
                )
                DispatchQueue.main.async {
                    if mode == "external_mpv" {
                        self.handleExternalPlay(playInfo: response)
                    } else {
                        self.activePlayInfo = response
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "发起播放失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleExternalPlay(playInfo: PlayResponse) {
        let encoded = playInfo.playUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playInfo.playUrl
        if let url = URL(string: "infuse://x-callback-url/play?url=\(encoded)"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let vlc = URL(string: "vlc://\(playInfo.playUrl)"), UIApplication.shared.canOpenURL(vlc) {
            UIApplication.shared.open(vlc)
        } else {
            UIPasteboard.general.string = playInfo.playUrl
            self.errorMessage = "已将播放直链复制至剪贴板，可粘贴至任意第三方播放器加载。"
        }
    }

    private func extractCookies() async -> String {
        guard let wv = webViewRef else { return "" }
        guard let host = URL(string: serverUrl)?.host?.lowercased(), !host.isEmpty else {
            return ""
        }

        let store = wv.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { return false }
            return host == domain || host.hasSuffix(".\(domain)")
        }

        return HTTPCookie.requestHeaderFields(with: relevantCookies)["Cookie"] ?? ""
    }
}

// 代理辅助处理器
final class BridgeHandler: StrmActionBridgeDelegate {
    let onPlay: (Int) -> Void
    let onExternalPlay: (Int) -> Void
    let onSettings: () -> Void

    init(
        onPlay: @escaping (Int) -> Void,
        onExternalPlay: @escaping (Int) -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.onPlay = onPlay
        self.onExternalPlay = onExternalPlay
        self.onSettings = onSettings
    }

    func bridgeDidRequestPlay(itemId: Int) {
        onPlay(itemId)
    }

    func bridgeDidRequestExternalPlay(itemId: Int) {
        onExternalPlay(itemId)
    }

    func bridgeDidRequestSettings() {
        onSettings()
    }
}

// 使 PlayResponse 支持作为 fullScreenCover 的 item
extension PlayResponse: Identifiable {
    public var id: Int { itemId }
}
