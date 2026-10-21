import SwiftUI
import WebKit

public struct WebContainerView: UIViewRepresentable {
    public let serverUrl: String
    public let bridge: StrmActionBridge
    public var onWebViewCreated: ((WKWebView) -> Void)?

    public init(
        serverUrl: String,
        bridge: StrmActionBridge,
        onWebViewCreated: ((WKWebView) -> Void)? = nil
    ) {
        self.serverUrl = serverUrl
        self.bridge = bridge
        self.onWebViewCreated = onWebViewCreated
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // 注入 JS 桥
        contentController.add(bridge, name: StrmActionBridge.messageHandlerName)
        contentController.addUserScript(bridge.userScript())
        config.userContentController = contentController

        // 允许媒体内联播放与跨域 Cookie
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 7/255, green: 8/255, blue: 10/255, alpha: 1.0)
        webView.scrollView.backgroundColor = webView.backgroundColor

        onWebViewCreated?(webView)

        if let url = URL(string: serverUrl) {
            var request = URLRequest(url: url)
            request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")
            webView.load(request)
        }

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebContainerView

        init(_ parent: WebContainerView) {
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebContainer] 加载失败: \(error.localizedDescription)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[WebContainer] 初始导航失败: \(error.localizedDescription)")
        }
    }
}
