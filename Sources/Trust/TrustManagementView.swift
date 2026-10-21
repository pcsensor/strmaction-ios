import SwiftUI

/// 证书信任管理面板。
///
/// 展示当前已固定的服务器指纹，允许逐个撤销或全部清空。
/// 撤销后下一次播放会重新走一次 TOFU 固定流程。
struct TrustManagementView: View {
    @ObservedObject private var store = TLSTrustStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemove: PinnedCertificate?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("自签名服务器在首次连接时会被固定。此后只有指纹完全一致的证书才能建立连接，证书被替换或中间人攻击都会直接失败。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if store.pins.isEmpty {
                    Section {
                        Text("尚未固定任何服务器。\n连接自签名服务时会自动固定。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(store.pins) { pin in
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pin.hostKey)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(pin.subject)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                Text(pin.fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                HStack(spacing: 12) {
                                    if let notAfter = pin.notAfter {
                                        Label(
                                            notAfter.formatted(date: .abbreviated, time: .omitted),
                                            systemImage: "calendar"
                                        )
                                        .font(.system(size: 11))
                                        .foregroundStyle(notAfter > Date() ? Color.secondary : Color.red)
                                    }
                                    Label(
                                        pin.pinnedAt.formatted(date: .abbreviated, time: .shortened),
                                        systemImage: "pin"
                                    )
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !store.pins.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            store.removeAll()
                        } label: {
                            Text("撤销全部固定证书")
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
        }
        .navigationViewStyle(.stack)
    }
}
