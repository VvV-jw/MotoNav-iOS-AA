import SwiftUI
import ObjectiveC

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 导航时手机上显示的高德原版导航界面（地图、路线、转向提示都由高德画）。
/// 我们的 NaviBridge 同时在旁边“旁听”导航数据发给圆屏。
/// iOS v0.5.2：
/// - 高德界面自带的“关闭”按钮 = 退出导航；“更多”按钮弹出菜单（看全程 / 回到跟随、路况开关、退出导航）
/// - 地图跟着夜间配色切换白天 / 夜间样式
/// - 到达目的地后显示 4 秒“已到达”，然后自动关掉（圆屏同时显示到达，4 秒后回到待机）
/// iOS v0.6：播报静音按钮（下次还记得）；模拟导航暂停 / 继续、车速 40/60/100/150；
/// “退出导航”要长按（防误触），高德界面的“关闭”按钮先问一句

/// 接住高德导航界面的按钮回调（和 NaviBridge 一样在运行时登记协议，见 CLAUDE.md 高德坑第 1 条）
final class DriveViewController: NSObject, ObservableObject {
    weak var view: AMapNaviDriveView?
    var onClose: (() -> Void)?
    @Published var showMore = false

    var asDelegate: AMapNaviDriveViewDelegate? {
        class_addProtocol(DriveViewController.self, AMapNaviDriveViewDelegate.self)
        return (self as AnyObject) as? AMapNaviDriveViewDelegate
    }

    @objc(driveViewCloseButtonClicked:)
    func closeTapped(_ v: AMapNaviDriveView) { onClose?() }

    @objc(driveViewMoreButtonClicked:)
    func moreTapped(_ v: AMapNaviDriveView) { showMore = true }

    var isOverview: Bool { view?.showMode == .overview }
    func toggleOverview() {
        guard let v = view else { return }
        v.showMode = v.showMode == .overview ? .carPositionLocked : .overview
    }
    var trafficOn: Bool { view?.mapShowTraffic ?? true }
    func toggleTraffic() { view?.mapShowTraffic.toggle() }
}

struct AMapDriveViewRep: UIViewRepresentable {
    let controller: DriveViewController
    let night: Bool

    func makeUIView(context: Context) -> AMapNaviDriveView {
        let v = AMapNaviDriveView(frame: .zero)
        v.delegate = controller.asDelegate
        v.mapViewModeType = night ? .night : .day
        controller.view = v
        AMapNaviDriveManager.sharedInstance().addDataRepresentative(v)
        return v
    }

    func updateUIView(_ v: AMapNaviDriveView, context: Context) {
        let mode: AMapNaviViewMapModeType = night ? .night : .day
        if v.mapViewModeType != mode { v.mapViewModeType = mode }
    }

    static func dismantleUIView(_ uiView: AMapNaviDriveView, coordinator: ()) {
        AMapNaviDriveManager.sharedInstance().removeDataRepresentative(uiView)
    }
}

struct NaviScreen: View {
    @ObservedObject var navi = NaviBridge.shared
    @ObservedObject var settings = Settings.shared
    @StateObject private var drive = DriveViewController()
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false
    @State private var closeOwner: UInt64?
    @State private var menuOwner: UInt64?
    @State private var holdOwner: UInt64?
    @State private var showSkipNotice = false
    @State private var holding = false                  // 正在长按“退出导航”
    @State private var holdHint = false

    var body: some View {
        ZStack(alignment: .bottom) {
            AMapDriveViewRep(controller: drive, night: settings.paletteNight).ignoresSafeArea()
            VStack(spacing: 10) {
                if navi.uiSuggestMin > 0 {                  // iOS v0.2 高德发现更快的路线
                    HStack {
                        Text("发现更快路线，能省约 \(navi.uiSuggestMin) 分钟")
                            .font(.subheadline).foregroundColor(.white)
                        Spacer()
                        Button("换这条") { navi.acceptSuggest() }
                            .font(.headline).foregroundColor(Color(red: 0.26, green: 0.88, blue: 0.94))
                        Button("不用") { navi.clearSuggest() }
                            .font(.subheadline).foregroundColor(.gray)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85)))
                    .padding(.horizontal, 16)
                }
                if !navi.showArrived {
                    if navi.canSkipVia {
                        Button("下一站：\(navi.nextViaName) · 跳过说明") { navi.explainDriveSkip(); showSkipNotice = true }
                            .font(.caption.bold()).foregroundColor(.white).padding(10).background(Capsule().fill(Color.black.opacity(0.82)))
                    }
                    controlRow
                    exitButton
                }
            }
            if navi.showArrived { arrivedCard }
        }
        .onAppear { drive.onClose = { closeOwner = navi.navigationOwner; confirmClose = closeOwner != nil } }
        .onChange(of: drive.showMore) { if $0 { menuOwner = navi.navigationOwner } }
        .confirmationDialog("驾车途中调整途经点", isPresented: $showSkipNotice) { Button("继续原导航", role: .cancel) {} } message: {
            Text("当前驾车引擎无法保证途中换站失败时继续原路线。请停车后结束导航，再编辑途经点并重新规划。")
        }
        .alert("退出导航？", isPresented: $confirmClose) {
            Button("退出导航", role: .destructive) { exitNavi(expectedOwner: closeOwner) }
            Button("继续导航", role: .cancel) {}
        }
        .onChange(of: navi.navigating) { now in
            if !now && !navi.showArrived { dismiss() }          // 退出导航：马上关；到达：等“已到达”显示完
        }
        .onChange(of: navi.showArrived) { now in
            if !now && !navi.navigating { dismiss() }           // “已到达”显示完了
        }
        .confirmationDialog("导航选项", isPresented: $drive.showMore, titleVisibility: .hidden) {
            Button(drive.isOverview ? "回到车头跟随" : "看全程") { drive.toggleOverview() }
            Button(drive.trafficOn ? "关掉路况颜色" : "显示路况颜色") { drive.toggleTraffic() }
            Button("返回首页修改设置") { dismiss() }
            Button("退出导航", role: .destructive) { exitNavi(expectedOwner: menuOwner) }
            Button("取消", role: .cancel) {}
        }
    }

    private func exitNavi(expectedOwner: UInt64?) {
        if navi.stop(ifOwner: expectedOwner) { dismiss() }
    }

    /// 静音、（模拟导航时）暂停 / 继续、车速
    private var controlRow: some View {
        HStack(spacing: 10) {
            chip(settings.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 settings.voiceMuted ? "恢复播报" : "播报已开", on: settings.voiceMuted) {
                settings.voiceMuted.toggle()
                if settings.voiceMuted { Speech.shared.stopNow() }
            }.accessibilityIdentifier("navigation.resumeVoice")
            if navi.emulating {
                chip(navi.emuPaused ? "play.fill" : "pause.fill", navi.emuPaused ? "继续" : "暂停", on: navi.emuPaused) { navi.toggleEmuPause() }
                chip("speedometer", "\(navi.emuSpeed) km/h", on: false) { navi.cycleEmuSpeed() }
            }
            Spacer()
            chip("house", "首页", on: false) { dismiss() }.accessibilityIdentifier("navigation.home")
        }
        .padding(.horizontal, 24)
    }

    private func chip(_ icon: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundColor(on ? Color(red: 1, green: 0.31, blue: 0.71) : .white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.82)))
        }
        .buttonStyle(.plain)
    }

    /// 长按 0.6 秒才退出（骑车时误碰不会退）；按住时粉色从左往右填满
    private var exitButton: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(red: 0.45, green: 0.14, blue: 0.32))
            GeometryReader { g in
                Capsule().fill(Color(red: 1, green: 0.31, blue: 0.71))
                    .frame(width: holding ? g.size.width : 0)
                    .animation(holding ? .linear(duration: 0.6) : .easeOut(duration: 0.15), value: holding)
            }
            Text(holdHint ? "要长按才能退出" : (holding ? "松手取消" : "长按退出导航"))
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 48)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            holdHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { holdHint = false }
        }
        .onLongPressGesture(minimumDuration: 0.6, pressing: { p in if p { holdOwner = navi.navigationOwner }; holding = p }) {
            holding = false
            exitNavi(expectedOwner: holdOwner)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// 到达目的地：显示 4 秒后自动关掉（点一下马上关）
    private var arrivedCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.checkered").font(.system(size: 40, weight: .bold)).foregroundColor(Color(red: 1, green: 0.31, blue: 0.71))
            Text(navi.info).font(.title2.bold()).foregroundColor(.white)
            Text("马上回到主界面").font(.footnote).foregroundColor(.gray)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.88)))
        .padding(24)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !navi.navigating { dismiss() } }
    }
}
