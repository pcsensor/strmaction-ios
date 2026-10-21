import SwiftUI
import WebKit
import Security

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

        // 媒体内联播放与 JavaScript 权限
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 7/255, green: 8/255, blue: 10/255, alpha: 1.0)
        webView.scrollView.backgroundColor = webView.backgroundColor

        // 添加下拉刷新控件
        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = UIColor(red: 232/255, green: 176/255, blue: 106/255, alpha: 1.0)
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefreshControl(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        context.coordinator.webView = webView
        onWebViewCreated?(webView)

        if let url = URL(string: serverUrl) {
            var request = URLRequest(url: url)
            request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")
            webView.load(request)
        }

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebContainerView
        weak var webView: WKWebView?

        init(_ parent: WebContainerView) {
            self.parent = parent
        }

        @objc func handleRefreshControl(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
            print("[WebContainer] 加载失败: \(error.localizedDescription)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
            print("[WebContainer] 初始导航失败: \(error.localizedDescription)")
        }

        // 处理 HTTPS 自签名证书放行（支持纯 IP 直连）
        public func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let allowInsecure = UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true
            guard allowInsecure,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }

        // 处理网页 JavaScript alert
        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let topVC = Self.topViewController() else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                completionHandler()
            })
            topVC.present(alert, animated: true)
        }

        // 处理网页 JavaScript confirm
        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let topVC = Self.topViewController() else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: "确认", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completionHandler(false)
            })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                completionHandler(true)
            })
            topVC.present(alert, animated: true)
        }

        private static func topViewController() -> UIViewController? {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
                return nil
            }
            var top = window.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }
    }
}
