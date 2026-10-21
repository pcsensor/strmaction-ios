import SwiftUI
import AVFoundation
import UIKit

// MARK: - 抽屉 / 面板

enum PlayerDrawer: String, Identifiable, Equatable {
    case menu
    case episodes
    case speed
    case subtitles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: return "更多"
        case .episodes: return "选集"
        case .speed: return "播放速度"
        case .subtitles: return "字幕"
        }
    }

    /// 子面板需要返回箭头，主面板不需要。
    var parent: PlayerDrawer? {
        switch self {
        case .menu, .episodes, .speed: return nil
        case .subtitles: return .menu
        }
    }
}

// MARK: - 居中浮层

struct ScrubBadgeData: Equatable {
    var targetMs: Int64
    var totalMs: Int64
    var deltaSec: Int64
    var isBuffered: Bool
}

/// 所有「瞬时反馈」共用同一个居中槽位，避免多个浮层互相打架。
enum PlayerCenterBadge: Equatable {
    case toast(String)
    case scrub(ScrubBadgeData)
    case brightness(Double)
    case volume(Double)

    /// 按类型给一个稳定标识——数值变化时不要换 id，否则过渡动画会反复触发造成闪烁。
    var transitionKey: String {
        switch self {
        case .toast: return "toast"
        case .scrub: return "scrub"
        case .brightness: return "brightness"
        case .volume: return "volume"
        }
    }

    var autoDismissDelay: Double {
        switch self {
        case .toast: return PlayerTheme.toastDuration
        case .scrub, .brightness, .volume: return PlayerTheme.badgeAutoDismiss
        }
    }
}

// MARK: - 手势模式

enum PlayerGestureMode: Equatable {
    case none
    case scrub
    case brightness
    case volume
}

// MARK: - UI 状态机

/// 播放器界面的全部瞬时状态：控件显隐、锁定、全屏、面板、浮层、手势仲裁、定时器。
///
/// 从 PlayerView 中抽出来的目的有两个：
/// 1. 自动隐藏的触发条件集中在一处，杜绝「拖动进度条时控件消失」这类竞态；
/// 2. 手势在一次拖动内锁定为单一模式（进度 / 亮度 / 音量），不会被中途改判。
@MainActor
final class PlayerUIController: ObservableObject {
    // 控件显隐
    @Published private(set) var isControlsVisible = true
    @Published private(set) var isLocked = false
    @Published private(set) var isLockButtonVisible = false
    @Published private(set) var isFullscreen = false

    // 面板与浮层
    @Published var activeDrawer: PlayerDrawer?
    @Published private(set) var centerBadge: PlayerCenterBadge?
    @Published private(set) var speedBadge: Double?
    /// 拖动过程中预瞄的播放位置。存在时进度条与时间文本都显示它，松手才真正 seek。
    @Published private(set) var scrubPreviewMs: Int64?

    // 亮度 / 音量
    //
    // 两者都直接作用于**系统**：`UIScreen.main.brightness` 与 `MPVolumeView`。
    // 之前亮度用压暗遮罩、音量用播放器增益，上限都被锁死在「系统当前值」——
    // 拖到顶只是把叠加的衰减去掉，所以永远不够亮、不够响。
    @Published private(set) var brightness: Double
    @Published private(set) var volume: Double

    /// 进入播放器时的系统亮度，退出时还原。
    private let baselineBrightness: CGFloat
    /// 首次读到的系统音量，退出时还原。
    private var baselineVolume: Float?

    // MARK: 依赖

    @MainActor weak var player: VideoPlayerController?

    // MARK: 私有状态

    private var gestureMode: PlayerGestureMode = .none
    private var panStartX: CGFloat = 0
    private var panStartProgressMs: Int64 = 0
    private var panStartBrightness: Double = 0
    private var panStartVolume: Double = 0
    /// 进度条正在被拖动（横向手势不算，两者取或）。
    private var isBarScrubbing = false

    private var hideTimer: Timer?
    private var lockButtonTimer: Timer?
    private var badgeTimer: Timer?

    init() {
        // 记住进入时的系统亮度，退出播放器时还原——改系统亮度是全局副作用，必须收尾。
        // 这里不读取任何属性，避免在存储属性初始化完成前访问 self。
        let screenBrightness = UIScreen.main.brightness
        baselineBrightness = screenBrightness
        brightness = Double(screenBrightness)
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
    }

    // 所有定时器都用 [weak self] 捕获，控制器释放后回调自动空转，
    // 因此不需要 deinit，也不会形成引用环。

    // MARK: - 控件显隐

    func showControls() {
        guard !isLocked else { return }
        guard !isControlsVisible else {
            scheduleAutoHide()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            isControlsVisible = true
        }
        scheduleAutoHide()
    }

    func hideControls() {
        guard isControlsVisible else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        withAnimation(.easeOut(duration: 0.24)) {
            isControlsVisible = false
        }
    }

    func toggleControls() {
        isControlsVisible ? hideControls() : showControls()
    }

    /// 任何「用户主动操作」后调用：重置自动隐藏倒计时。
    func resetAutoHide() {
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTimer?.invalidate()
        hideTimer = nil

        // 与 Android 保持一致的四个前置条件。缺一不可：
        // 锁定 / 控件已隐藏 / 面板打开 / 正在拖进度 / 已暂停 —— 任一情况都不自动隐藏。
        guard !isLocked,
              isControlsVisible,
              activeDrawer == nil,
              !isBarScrubbing,
              gestureMode != .scrub,
              (player?.isPlaying ?? false)
        else { return }

        let timer = Timer(timeInterval: PlayerTheme.autoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideControls() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func cancelAutoHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// 播放状态变化时重新评估自动隐藏（暂停时立刻取消倒计时，恢复播放时重新计时）。
    func playbackStateChanged() {
        if player?.isPlaying == true {
            scheduleAutoHide()
        } else {
            cancelAutoHide()
        }
    }

    // MARK: - 进度条拖动（修复点：拖动期间挂起自动隐藏）

    func setBarScrubbing(_ scrubbing: Bool) {
        guard isBarScrubbing != scrubbing else { return }
        isBarScrubbing = scrubbing
        if scrubbing {
            // 关键修复：进入拖动立刻取消自动隐藏倒计时，控件不会再在拖到一半时消失。
            cancelAutoHide()
            showControls()
        } else {
            scrubPreviewMs = nil
            scheduleAutoHide()
        }
    }

    /// 进度条拖动过程中的实时预览位置。
    func updateBarScrubPreview(_ ms: Int64) {
        scrubPreviewMs = ms
    }

    // MARK: - 锁定

    func toggleLock() {
        isLocked.toggle()

        if isLocked {
            closeDrawer(animated: false)
            dismissBadge()
            // closeDrawer 会顺带重排自动隐藏倒计时，锁定后必须再取消一次。
            cancelAutoHide()
            withAnimation(.easeOut(duration: 0.2)) {
                isControlsVisible = false
            }
            // 锁定只锁控件，不动播放状态。之前这里 pause() 再在解锁时 play()，
            // 等于把「防误触」做成了「暂停」，锁一下画面就停一帧。
            scheduleLockButtonHide()
        } else {
            hideLockButton()
            showControls()
        }
    }

    func hideLockButton() {
        lockButtonTimer?.invalidate()
        lockButtonTimer = nil
        isLockButtonVisible = false
    }

    private func scheduleLockButtonHide() {
        lockButtonTimer?.invalidate()
        isLockButtonVisible = true
        let timer = Timer(timeInterval: PlayerTheme.lockButtonHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideLockButton() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockButtonTimer = timer
    }

    /// 锁定状态下的单击：第一次唤出解锁按钮，第二次直接收起。
    func handleTapWhileLocked() {
        if isLockButtonVisible {
            hideLockButton()
        } else {
            scheduleLockButtonHide()
        }
    }


    // MARK: - 全屏

    func toggleFullscreen() {
        isFullscreen.toggle()
        if isFullscreen {
            // 手机端横屏优先（与 Android 的 SENSOR_LANDSCAPE 对齐），iPad 允许全部方向。
            SystemOrientation.request(.landscape)
        } else {
            SystemOrientation.request(.all)
        }
        // 切换后强制呼出控件并重置倒计时，避免旋转过程中控件处于不可见状态。
        showControls()
    }

    // MARK: - 面板

    func openDrawer(_ drawer: PlayerDrawer) {
        cancelAutoHide()
        // 打开面板时不允许残留长按倍速。
        endLongPressSpeed()
        withAnimation(.spring(response: PlayerTheme.drawerOpenDuration, dampingFraction: 0.9)) {
            activeDrawer = drawer
            isControlsVisible = false
        }
    }

    func pushDrawer(_ drawer: PlayerDrawer) {
        cancelAutoHide()
        withAnimation(.easeOut(duration: 0.18)) {
            activeDrawer = drawer
        }
    }

    func popDrawer() {
        guard let parent = activeDrawer?.parent else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            activeDrawer = parent
        }
    }

    func closeDrawer(animated: Bool = true) {
        guard activeDrawer != nil else { return }
        let apply = { self.activeDrawer = nil }
        if animated {
            withAnimation(.easeIn(duration: PlayerTheme.drawerCloseDuration)) { apply() }
        } else {
            apply()
        }
        scheduleAutoHide()
    }

    func isDrawerOpen(_ drawer: PlayerDrawer) -> Bool {
        activeDrawer == drawer
    }

    // MARK: - 居中浮层

    func showToast(_ text: String) {
        presentBadge(.toast(text))
    }

    func showScrubBadge(_ data: ScrubBadgeData) {
        presentBadge(.scrub(data))
    }

    private func presentBadge(_ badge: PlayerCenterBadge) {
        centerBadge = badge
        badgeTimer?.invalidate()
        let timer = Timer(timeInterval: badge.autoDismissDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.centerBadge?.transitionKey == badge.transitionKey else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.centerBadge = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        badgeTimer = timer
    }

    func dismissBadge() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            centerBadge = nil
        }
    }

    // MARK: - 长按倍速浮层

    private var speedBeforeLongPress: Double?

    func setLongPressSpeed(_ enabled: Bool) {
        guard let player else { return }
        if enabled {
            // 幂等：手势的 onChanged 会连续回调，若每次都覆盖 speedBeforeLongPress，
            // 松手就会「恢复」到倍速本身，等于永远退不出去。
            guard speedBeforeLongPress == nil else { return }
            guard player.isPlaying, gestureMode == .none else { return }
            speedBeforeLongPress = player.playbackSpeed
            player.setSpeed(UserDefaults.standard.double(forKey: "long_press_speed").nonZeroOrDefault(2.0))
            withAnimation(.easeOut(duration: 0.15)) {
                speedBadge = player.playbackSpeed
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            guard let previous = speedBeforeLongPress else { return }
            speedBeforeLongPress = nil
            player.setSpeed(previous)
            withAnimation(.easeOut(duration: 0.15)) {
                speedBadge = nil
            }
        }
    }

    /// 无条件退出长按倍速。打开面板、页面消失、锁屏等路径都调它兜底。
    func endLongPressSpeed() {
        setLongPressSpeed(false)
    }

    func commitLongPressSpeed(_ value: Double) {
        UserDefaults.standard.set(value, forKey: "long_press_speed")
    }

    var longPressSpeed: Double {
        UserDefaults.standard.double(forKey: "long_press_speed").nonZeroOrDefault(2.0)
    }

    // MARK: - 亮度 / 音量

    private func setBrightness(_ value: Double) {
        let clamped = max(0.02, min(1.0, value))
        brightness = clamped
        // 直接改系统亮度，才能突破「只能变暗、不能变亮」的上限。
        UIScreen.main.brightness = CGFloat(clamped)
        presentBadge(.brightness(clamped))
    }

    private func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        // 走系统音量：播放器增益固定 1.0，不再二次衰减。
        SystemVolumeController.shared.set(Float(clamped))
        presentBadge(.volume(clamped))
    }

    /// 退出播放器时把系统亮度、音量还原成进入前的值。
    ///
    /// 这两个都是全局副作用，不还原就会把用户在 App 里调的值留在系统设置里。
    func restoreSystemSettings() {
        UIScreen.main.brightness = baselineBrightness
        brightness = Double(baselineBrightness)
        if let baselineVolume {
            SystemVolumeController.shared.set(baselineVolume)
            volume = Double(baselineVolume)
        }
    }

    private func syncSystemVolumeIfNeeded() {
        guard baselineVolume == nil else { return }
        let sessionVolume = AVAudioSession.sharedInstance().outputVolume
        guard sessionVolume > 0 else { return }
        // 第一次拖动前记下系统音量，退出时还原用。
        baselineVolume = sessionVolume
        volume = Double(sessionVolume)
    }

    // MARK: - 手势

    /// 拖动开始：记录起点并决定这次拖动的模式，在手指抬起前锁定。
    func handleDragBegan(at location: CGPoint, in size: CGSize) {
        guard !isLocked, activeDrawer == nil else {
            gestureMode = .none
            return
        }
        syncSystemVolumeIfNeeded()

        gestureMode = .none
        panStartX = location.x
        panStartProgressMs = player?.currentPositionMs ?? 0
        panStartBrightness = brightness
        panStartVolume = volume
    }

    /// 拖动过程中。`translation` 为相对起点的位移。
    func handleDragChanged(_ translation: CGSize, in size: CGSize) {
        guard !isLocked, activeDrawer == nil else { return }

        // 首次越过死区时锁定模式，之后不再改判——这是滑动不「中途跳变」的关键。
        if gestureMode == .none {
            let horizontal = abs(translation.width)
            let vertical = abs(translation.height)
            guard max(horizontal, vertical) > PlayerTheme.dragSlop else { return }
            gestureMode = horizontal > vertical
                ? .scrub
                : (panStartX < size.width / 2 ? .brightness : .volume)
        }

        switch gestureMode {
        case .scrub:
            cancelAutoHide()
            let total = player?.durationMs ?? 0
            guard total > 0, size.width > 0 else { return }
            // 整屏宽度映射到 min(总时长, 3 分钟)，与 Android 一致，长片不会过于灵敏。
            let range = min(total, PlayerTheme.scrubRangeMs)
            let deltaMs = Int64(Double(translation.width / size.width) * Double(range))
            let target = max(0, min(total, panStartProgressMs + deltaMs))
            scrubPreviewMs = target
            let deltaSec = (target - panStartProgressMs) / 1000
            let buffered = player?.bufferedPositionMs ?? 0
            showScrubBadge(
                ScrubBadgeData(targetMs: target, totalMs: total, deltaSec: deltaSec, isBuffered: target <= buffered)
            )

        case .brightness:
            let sensitivity = max(1, size.height * PlayerTheme.verticalSensitivity)
            setBrightness(panStartBrightness + Double(-translation.height / sensitivity))

        case .volume:
            let sensitivity = max(1, size.height * PlayerTheme.verticalSensitivity)
            setVolume(panStartVolume + Double(-translation.height / sensitivity))

        case .none:
            break
        }
    }

    /// 拖动结束：进度在此刻才真正落定，避免拖动过程中发起大量 seek 请求。
    func handleDragEnded() {
        if gestureMode == .scrub, let target = scrubPreviewMs {
            player?.seek(toMs: target)
        }
        scrubPreviewMs = nil
        gestureMode = .none
        dismissBadge()
        if !isLocked {
            scheduleAutoHide()
        }
    }

    /// 单击：切换控件。锁定态下改为呼出解锁按钮。
    func handleSingleTap() {
        if isLocked {
            handleTapWhileLocked()
            return
        }
        if activeDrawer != nil {
            closeDrawer()
            return
        }
        toggleControls()
    }

    /// 双击：左 / 右快退快进，中间播放暂停。
    func handleDoubleTap(xRatio: Double) {
        guard !isLocked, activeDrawer == nil else { return }
        guard let player else { return }
        if xRatio < PlayerTheme.doubleTapLeftZone {
            player.skip(seconds: -PlayerTheme.skipIntervalSeconds)
            showToast("快退 \(PlayerTheme.skipIntervalSeconds) 秒")
        } else if xRatio > PlayerTheme.doubleTapRightZone {
            player.skip(seconds: PlayerTheme.skipIntervalSeconds)
            showToast("快进 \(PlayerTheme.skipIntervalSeconds) 秒")
        } else {
            player.togglePlayPause()
            resetAutoHide()
        }
    }

    // MARK: - 播放控制

    func togglePlayPause() {
        player?.togglePlayPause()
        resetAutoHide()
    }

    func setSpeed(_ value: Double) {
        player?.setSpeed(value)
        resetAutoHide()
    }

    // MARK: - 生命周期

    func resetForNewEpisode() {
        activeDrawer = nil
        centerBadge = nil
        speedBadge = nil
        scrubPreviewMs = nil
        isLocked = false
        isLockButtonVisible = false
        isFullscreen = false
        gestureMode = .none
        isBarScrubbing = false
        dismissAllTimers()
    }

    private func dismissAllTimers() {
        hideTimer?.invalidate()
        lockButtonTimer?.invalidate()
        badgeTimer?.invalidate()
        hideTimer = nil
        lockButtonTimer = nil
        badgeTimer = nil
    }
}

// MARK: - 辅助

private extension Double {
    /// UserDefaults 里 0 视为「未设置」，回退到默认值。
    func nonZeroOrDefault(_ fallback: Double) -> Double {
        self > 0.001 ? self : fallback
    }
}