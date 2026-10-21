import SwiftUI

public struct SetupView: View {
    @AppStorage("server_url") private var serverUrl: String = ""
    @AppStorage("buffer_limit_mb") private var bufferLimitMb: Int = PlaybackBufferPreference.defaultLimitMb
    @State private var isCustomBuffer = false
    @State private var customBufferText = ""
    @State private var showTrust = false
    @ObservedObject var trustStore = TLSTrustStore.shared
    @Binding var isPresented: Bool

    @State private var inputUrl: String = ""
    @State private var statusMessage: String = ""
    @State private var isTesting: Bool = false
    @State private var isSuccess: Bool = false

    private let bufferTargetOptions = PlaybackBufferPreference.presets

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        ZStack {
            Color(hex: "#07080A").ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("StrmAction")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(Color(hex: "#E8B06A"))
                            Text("连接到媒体库服务器")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        if !serverUrl.isEmpty {
                            Button(action: { isPresented = false }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(Color(hex: "#8A93A5"))
                            }
                        }
                    }

                    Text("输入你的 StrmAction 服务端地址（如 http://192.168.1.10:8080 或 https://media.yourdomain.com）。")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8A93A5"))
                        .lineSpacing(4)

                    // 服务器地址输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器地址")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "#8A93A5"))

                        TextField("http://192.168.1.10:8080", text: $inputUrl)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding()
                            .background(Color(hex: "#14161C"))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .onChange(of: inputUrl) { _ in
                                isSuccess = false
                                statusMessage = ""
                            }
                    }
                    .padding(.top, 10)

                    // 缓存与网络高级设置
                    VStack(alignment: .leading, spacing: 12) {
                        Text("高级设置")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "#8A93A5"))

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("缓冲大小")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                    Text("按容量设置，实际预读时长取决于片源码率")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#8A93A5"))
                                }
                                Spacer()
                                Picker("缓冲大小", selection: bufferSelection) {
                                    ForEach(bufferTargetOptions, id: \.self) { mb in
                                        Text("\(mb) MB").tag(mb)
                                    }
                                    Text("自定义…").tag(-1)
                                }
                                .pickerStyle(.menu)
                                .tint(Color(hex: "#E8B06A"))
                            }

                            if isCustomBuffer {
                                HStack(spacing: 8) {
                                    TextField("MB", text: $customBufferText)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 88)
                                    Text("MB（\(PlaybackBufferPreference.minLimitMb)–\(PlaybackBufferPreference.maxLimitMb)）")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "#8A93A5"))
                                    Spacer()
                                    Button("应用") {
                                        if let value = Int(customBufferText) {
                                            bufferLimitMb = PlaybackBufferPreference.clamp(value)
                                            customBufferText = "\(bufferLimitMb)"
                                            isCustomBuffer = false
                                        }
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .tint(Color(hex: "#E8B06A"))
                                    .disabled(Int(customBufferText) == nil)
                                }
                            }

                            Text("当前 \(bufferLimitMb) MB，按最近片源码率约 "
                                + "\(Int(PlaybackBufferPreference.seconds(limitMb: bufferLimitMb, bitRate: PlaybackBufferPreference.observedBitRate))) 秒")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#8A93A5"))
                        }
                        .padding()
                        .background(Color(hex: "#14161C"))
                        .cornerRadius(8)

                        Button {
                            showTrust = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("证书信任")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                    Text(trustSummary)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#8A93A5"))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(hex: "#8A93A5"))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding()
                        .background(Color(hex: "#14161C"))
                        .cornerRadius(8)
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.system(size: 14))
                            .foregroundColor(isSuccess ? Color(hex: "#4ADE80") : Color(hex: "#F87171"))
                            .padding(.vertical, 4)
                    }

                    HStack(spacing: 16) {
                        Button(action: testConnection) {
                            HStack {
                                if isTesting {
                                    ProgressView().tint(.white)
                                }
                                Text("测试连接")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(hex: "#1E222D"))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(isTesting || inputUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(action: saveAndEnter) {
                            Text("保存并进入")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(isSuccess ? Color(hex: "#E8B06A") : Color(hex: "#374151"))
                                .foregroundColor(isSuccess ? Color(hex: "#07080A") : Color(hex: "#9CA3AF"))
                                .fontWeight(.semibold)
                                .cornerRadius(8)
                        }
                        .disabled(!isSuccess)
                    }
                    .padding(.top, 10)

                    Spacer()
                }
                .padding(24)
            }
        }
        .onAppear {
            inputUrl = serverUrl
            if !serverUrl.isEmpty {
                isSuccess = true
            }
            // 上次存的是自定义值时，直接把输入框展开
            isCustomBuffer = !PlaybackBufferPreference.presets.contains(bufferLimitMb)
            customBufferText = "\(bufferLimitMb)"
        }
        .sheet(isPresented: $showTrust) {
            TrustManagementView()
        }
    }

    /// 固定档位与「自定义」共用一个 Picker：-1 表示自定义。
    private var bufferSelection: Binding<Int> {
        Binding(
            get: { PlaybackBufferPreference.presets.contains(bufferLimitMb) ? bufferLimitMb : -1 },
            set: { newValue in
                if newValue == -1 {
                    customBufferText = "\(bufferLimitMb)"
                    isCustomBuffer = true
                } else {
                    isCustomBuffer = false
                    bufferLimitMb = newValue
                }
            }
        )
    }

    /// 证书信任摘要，展示当前已导入的根证书数量。
    private var trustSummary: String {
        if trustStore.anchors.isEmpty {
            return "私有 CA 站点需导入其自签名根证书"
        }
        return "已信任 \(trustStore.anchors.count) 个根证书 · 点击管理"
    }

    private func testConnection() {
        let clean = inputUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return }

        isTesting = true
        statusMessage = "正在连接服务器..."
        isSuccess = false

        Task {
            do {
                let health = try await PlayApi.shared.checkHealth(serverUrl: clean)
                DispatchQueue.main.async {
                    self.isTesting = false
                    if health.ok {
                        self.isSuccess = true
                        self.statusMessage = "连接成功！服务端版本: \(health.version ?? "未知")"
                    } else {
                        self.isSuccess = false
                        self.statusMessage = "服务未就绪"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTesting = false
                    self.isSuccess = false
                    self.statusMessage = "连接失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveAndEnter() {
        let clean = inputUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        serverUrl = clean
        isPresented = false
    }
}

// 辅助色扩展
extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
