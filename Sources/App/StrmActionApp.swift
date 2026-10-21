import SwiftUI
import WebKit

@main
struct StrmActionApp: App {
    @AppStorage("server_url") private var serverUrl: String = ""
    @State private var showSetup: Bool = false
    @State private var activePlayInfo: PlayResponse?
    @State private var webViewRef: WKWebView?
    @State private var errorMessage: String?

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
            }
        }
    }

    private func setupBridgeDelegate() {
        bridge.allowedHost = URL(string: serverUrl)?.host ?? ""
        bridge.delegate = BridgeHandler(
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
                    self.activePlayInfo = response
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "发起播放失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func extractCookies() async -> String {
        guard let wv = webViewRef else { return "" }
        let store = wv.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let cookiePairs = cookies.map { "\($0.name)=\($0.value)" }
        return cookiePairs.joined(separator: "; ")
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
