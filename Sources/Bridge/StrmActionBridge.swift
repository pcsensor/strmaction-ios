import Foundation
import WebKit

public protocol StrmActionBridgeDelegate: AnyObject {
    func bridgeDidRequestPlay(itemId: Int)
    func bridgeDidRequestExternalPlay(itemId: Int)
    func bridgeDidRequestSettings()
}

public final class StrmActionBridge: NSObject, WKScriptMessageHandler {
    public static let messageHandlerName = "StrmActionBridge"
    public weak var delegate: StrmActionBridgeDelegate?
    public var allowedHost: String = ""

    public init(allowedHost: String) {
        self.allowedHost = allowedHost
    }

    /// 生成在 document_start 注入的 JS 脚本
    public func userScript() -> WKUserScript {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let scriptSource = """
        (function() {
            window.StrmActionNative = {
                isCompanion: function() { return true; },
                isTV: function() { return false; },
                version: function() { return "\(appVersion)"; },
                serverHost: function() { return "\(allowedHost)"; },
                play: function(itemId) {
                    window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
                        action: "play",
                        itemId: Number(itemId)
                    });
                },
                playExternal: function(itemId) {
                    window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
                        action: "playExternal",
                        itemId: Number(itemId)
                    });
                },
                openSettings: function() {
                    window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
                        action: "openSettings"
                    });
                }
            };
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        // 安全校验：校验来源 Host
        if let host = message.webView?.url?.host, !allowedHost.isEmpty {
            let cleanAllowed = allowedHost.components(separatedBy: ":").first ?? allowedHost
            if host.caseInsensitiveCompare(cleanAllowed) != .orderedSame {
                print("[StrmActionBridge] 消息来源非受信服务器 host: \(host), 期望: \(cleanAllowed)")
                return
            }
        }

        switch action {
        case "play":
            if let itemId = body["itemId"] as? Int {
                DispatchQueue.main.async {
                    self.delegate?.bridgeDidRequestPlay(itemId: itemId)
                }
            }
        case "playExternal":
            if let itemId = body["itemId"] as? Int {
                DispatchQueue.main.async {
                    self.delegate?.bridgeDidRequestExternalPlay(itemId: itemId)
                }
            }
        case "openSettings":
            DispatchQueue.main.async {
                self.delegate?.bridgeDidRequestSettings()
            }
        default:
            break
        }
    }
}
