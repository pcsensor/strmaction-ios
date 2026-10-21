import Foundation
import SwiftUI
import UIKit

/// 临时诊断日志（排查播放卡死后可整体摘除）。
///
/// 设计要点：
/// - 同时输出到 `print` 和内存环形缓冲，方便在没有 Xcode 控制台的环境（侧载 IPA）里
///   直接在 App 内查看、复制；
/// - 可从任意线程调用，内部用锁保护缓冲；
/// - 仅在播放器「更多」面板里露出入口，不打扰正常使用。
final class PlayerDiagnostics: ObservableObject {
    static let shared = PlayerDiagnostics()

    /// 供 SwiftUI 观察的快照。真正的写入缓冲由 `lock` 保护。
    @Published private(set) var lines: [String] = []

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxLines = 600

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {}

    func log(_ tag: String, _ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = "\(stamp) [\(tag)] \(message)"

        // 始终走 print，接 Xcode / Console.app 时也能看到。
        print("[StrmAction] \(line)")

        lock.lock()
        buffer.append(line)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
        let snapshot = buffer
        lock.unlock()

        Task { @MainActor in
            self.lines = snapshot
        }
    }

    @MainActor
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        lines = []
    }

    var text: String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return snapshot.joined(separator: "\n")
    }
}

// MARK: - 便捷调用

/// `D.log("tag", "message")` 的简写，避免各处重复写单例名。
enum D {
    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        PlayerDiagnostics.shared.log(tag, message())
    }
}

// MARK: - 日志查看面板

struct PlayerDiagnosticsView: View {
    @ObservedObject private var diagnostics = PlayerDiagnostics.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: diagnostics.lines.count) { count in
                    // 始终贴底，方便看到最新一行。
                    if count > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("诊断日志 (\(diagnostics.lines.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") {
                        Task { @MainActor in diagnostics.clear() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(copied ? "已复制" : "复制全部") {
                        UIPasteboard.general.string = diagnostics.text
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}