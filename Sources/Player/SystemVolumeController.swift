import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 系统音量控制。
///
/// AVFoundation 没有公开的音量写入 API，唯一可行途径是 `MPVolumeView` 内部那个
/// `UISlider`。它必须挂在视图层级里，否则取不到 slider，写了也不生效。
///
/// 为什么不改播放器增益：`playbackVolume` 只影响当前播放器，最终响度还要乘系统音量。
/// 系统音量 50% 时，播放器增益拉满也只有一半响度——表现就是「控制条到头了但声音不够大」。
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    private let volumeView: MPVolumeView
    private weak var host: UIView?

    private init() {
        volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.isUserInteractionEnabled = false
        // 不能用 isHidden：隐藏的 MPVolumeView 不会创建内部 slider。
        volumeView.alpha = 0.01
    }

    /// 当前系统音量（0…1）。
    var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// 把隐藏的 MPVolumeView 挂到宿主视图上。
    func attach(to view: UIView) {
        guard host !== view else { return }
        host = view
        volumeView.removeFromSuperview()
        volumeView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.addSubview(volumeView)
    }

    /// 设置系统音量。
    ///
    /// 视图刚挂上时内部 slider 可能还没创建，这里做一次延迟重试，
    /// 避免「第一次滑动没反应」。
    func set(_ value: Float) {
        let clamped = max(0, min(1, value))
        if let slider = volumeSlider {
            slider.value = clamped
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.volumeSlider?.value = clamped
        }
    }

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
}

/// 承载隐藏 `MPVolumeView` 的透明宿主。
///
/// 放在播放器 ZStack 的最底层，尺寸 2×2、不接收触摸，用户完全看不到。
struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        SystemVolumeController.shared.attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        SystemVolumeController.shared.attach(to: uiView)
    }
}
