import SwiftUI
import UniformTypeIdentifiers

/// 证书信任管理面板。
///
/// 信任的唯一来源是「用户导入的自签名根证书」。
/// 之所以不自动固定叶子证书：Caddy 内部 CA 签发的叶子证书有效期只有 12 小时，
/// 固定它会周期性失效；轮换过程中保持不变的是签发它的 CA。
struct TrustManagementView: View {
    @ObservedObject var store = TLSTrustStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingFilePicker = false
    @State private var showingPasteSheet = false
    @State private var pastedText = ""
    @State private var alertTitle = ""
    @State private var alertMessage: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("私有 CA（例如 Caddy 内部 CA）签发的站点，需要导入它自签名的根证书才能播放。")
                        .font(.system(size: 12))
                    Text("FFmpeg 会顺着「叶子 → 中间 → 根」构建证书链，只有根落在信任库里才算通过。中间证书和叶子证书都不能当信任锚——叶子证书还会轮换。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("取证书：curl -s http://127.0.0.1:2019/pki/ca/local，或取 Caddy 数据目录下的 pki/authorities/local/root.crt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("导入根证书") {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                            .font(.system(size: 14))
                    }
                    Button {
                        pastedText = ""
                        showingPasteSheet = true
                    } label: {
                        Label("粘贴证书内容", systemImage: "doc.on.clipboard")
                            .font(.system(size: 14))
                    }
                }

                if store.anchors.isEmpty {
                    Section {
                        Text("尚未导入任何根证书。\n连接私有 CA 站点时会提示需要导入哪一个。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("已信任的根证书") {
                        ForEach(store.anchors) { anchor in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(anchor.subject)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(anchor.fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Label(
                                    anchor.addedAt.formatted(date: .abbreviated, time: .shortened),
                                    systemImage: "clock"
                                )
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.removeAnchor(fingerprint: anchor.fingerprint)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            store.removeAll()
                        } label: {
                            Text("移除全部根证书")
                        }
                    }
                }
            }
            .navigationTitle("证书信任")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item, .data, .text],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                        alertTitle = "导入失败"
                        alertMessage = "无法以文本方式读取这个文件，请确认它是 PEM 格式的证书。"
                        return
                    }
                    importPEM(text)
                case .failure(let error):
                    alertTitle = "导入失败"
                    alertMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingPasteSheet) {
                NavigationView {
                    TextEditor(text: $pastedText)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .navigationTitle("粘贴 PEM")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showingPasteSheet = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("导入") {
                                    showingPasteSheet = false
                                    importPEM(pastedText)
                                }
                                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func importPEM(_ text: String) {
        do {
            let imported = try store.addAnchor(pem: text)
            alertTitle = "导入成功"
            alertMessage = "已信任 \(imported.count) 张根证书：\n"
                + imported.map { "· \($0.subject)" }.joined(separator: "\n")
        } catch {
            alertTitle = "导入失败"
            alertMessage = error.localizedDescription
        }
    }
}
