#if MOTONAV_SCREENSHOTS
import SwiftUI
import UIKit

enum AppPageScenario {
    static let scene = ProcessInfo.processInfo.arguments.dropFirst().first(where: { $0.hasPrefix("page-") }) ?? "page-home-top"
    static var baseScene: String { scene.hasSuffix("-night") ? String(scene.dropLast(6)) : scene }
    static var largeFont: Bool { scene.contains("large-font") }
    static let sampleVias: [JourneyPoint] = [
        .init(name: "测试补给站", lat: 30.001, lng: 120.001),
        .init(name: "测试观景台", lat: 30.002, lng: 120.002),
        .init(name: "测试午餐点", lat: 30.003, lng: 120.003)
    ]
    static var sampleSummary: PipelineSummary {
        var events: [[String: Any]] = []
        for i in 0..<8 {
            let d = Double(i)
            events.append(["event":"fetch-complete", "fields":["preparationMs":120+d*8]])
            events.append(["event":"bulk-write", "fields":["queueWaitMs":10+d*2]])
            events.append(["event":"bulk-ack", "fields":["transferMs":210+d*5, "ackWaitMs":20+d*2]])
            events.append(["event":"screen-stats", "fields":["frameMs":40+d, "pushMs":12+d]])
        }
        return PipelineSummary.evaluate(events: events, droppedSamples: 0)
    }
    static func prepare() {
        // The test app has its own identifier and sandbox; no user configuration
        // or real credentials are read, copied, or passed to a service.
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        // Use the actual bounded store and library in the disposable app sandbox.
        // No application data is copied into this separate bundle's container.
        let store = JourneyStore()
        try! store.save([])
        if scene.hasPrefix("page-journeys") && !scene.contains("empty") {
            try! store.save([
                SavedJourney(name: "测试周末三站行程", mode: .drive,
                    destination: .init(name: "测试目的地", lat: 30.01, lng: 120.02),
                    vias: sampleVias, avoidHighway: true),
                SavedJourney(name: "测试摩托车三站行程", mode: .motorcycle,
                    destination: .init(name: "测试集合点", lat: 30.02, lng: 120.03),
                    vias: Array(sampleVias.prefix(3)), avoidHighway: false),
                SavedJourney(name: "测试自行车行程", mode: .bicycle,
                    destination: .init(name: "测试公园", lat: 30.03, lng: 120.04),
                    vias: [], avoidHighway: false)
            ])
            Settings.shared.amapKey = "UI_TEST_ONLY"
        }
        let map = MapFeeder.shared
        Settings.shared.theme = baseScene == "page-maintenance-mismatch" ? 2 : 1
        if scene.contains("maintenance") || scene.contains("display-bottom") {
            map.recoverablePreparation = PreparationRecoveryCheckpoint(savedAt: Date(), key: "synthetic-preview-route", points: [.init(lat:30,lng:120),.init(lat:30.01,lng:120.02)], frameLat: 30, frameLng: 120, frameID: 1, source: 3, style: 1, buildings: true, buildingPreference: true, rangeKm: 20, forceRefresh: true, refreshStartedAt: Date())
            map.preparationSaveState = .saved
        }
        if scene.contains("saving") { map.preparationSaveState = .saving }
        if scene.contains("failed") { map.preparationSaveState = .notSaved(.storage) }
        if scene.contains("too-large") { map.preparationSaveState = .notSaved(.tooLarge) }
        if baseScene == "page-maintenance-mismatch" { map.cacheMessage = "地图风格或建筑设置已改变，请恢复原设置后继续" }
        if scene.contains("planner-") { WebMotorSession.shared.route = .sample(bicycle: scene.contains("bicycle")) }
        if scene.contains("planner-drive") {
            NaviBridge.shared.routeOptions = [
                .init(id:1,label:"推荐路线 · 合成样本",timeS:1200,length:12000,lights:8,toll:0),
                .init(id:2,label:"备选路线 · 合成样本",timeS:1500,length:14500,lights:11,toll:0)]
            NaviBridge.shared.selectedRouteID = 1; NaviBridge.shared.routeReady = true
            NaviBridge.shared.vias = sampleVias.map { .init(lat: $0.lat, lng: $0.lng, name: $0.name) }
        }
        if scene.contains("navigation-independent") {
            WebMotorSession.shared.route = .sample(); WebMotorSession.shared.running = true
            WebMotorSession.shared.simulation = true
            let ticket = WebMotorSession.shared.recalculationNotice.beganAttempt()
            WebMotorSession.shared.recalculationNotice.failed("合成样本：路线服务暂不可用", ticket: ticket,
                retryNotBefore: Date().addingTimeInterval(20))
        }
        if scene.contains("navigation-drive") || scene.contains("home-active") {
            NaviBridge.shared.navigating = true; NaviBridge.shared.emulating = true
            NaviBridge.shared.vias = sampleVias.map { .init(lat: $0.lat, lng: $0.lng, name: $0.name) }
        }
        Settings.shared.voiceMuted = scene.contains("muted")
        Settings.shared.nightMode = scene.contains("night") ? 2 : 1
        if scene.contains("gta") { Settings.shared.theme = 2 }
        if baseScene == "page-home-search-flow" { Settings.shared.amapKey = "UI_TEST_ONLY" }
        if scene.contains("home-bottom") {
            History.shared.add(.init(name: "测试目的地", address: "合成样本，不含个人位置", lat:30, lng:120))
            Favorites.shared.add(.init(name: "测试常用地点", address: "合成样本", lat:30.01, lng:120.02))
        }
    }
}

@main struct AppPagesPreview: App {
    @ObservedObject private var settings = Settings.shared
    init() { AppPalette.configureSystemAppearance(); AppPageScenario.prepare() }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("界面自测 · 合成输入 · 未接真机").font(.caption2).foregroundColor(.yellow).padding(.vertical, 4)
                    .frame(maxWidth: .infinity).background(Color.black)
                    .overlay(alignment: .trailing) {
                        Text(settings.paletteNight ? "夜间" : "白天")
                            .font(.caption2).foregroundColor(.white).padding(.trailing, 8)
                            .accessibilityIdentifier("preview-theme")
                    }
                AppPagesScene()
            }.preferredColorScheme(settings.paletteNight ? .dark : .light)
                .environment(\.dynamicTypeSize, AppPageScenario.largeFont ? .accessibility1 : .large)
                .onAppear {
                    scheduleScroll()
                    PreviewFrameReadiness.shared.begin(scene: AppPageScenario.scene,
                        after: AppPageScenario.scene.contains("bottom") || AppPageScenario.scene.contains("middle") ? 1.7 : AppPageScenario.scene.contains("vias-editor") ? 1.0 : 0.3)
                }
        }
    }
    private func scheduleScroll() {
        guard AppPageScenario.scene.contains("bottom") || AppPageScenario.scene.contains("middle") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { scrollPreviewPage() }
    }
    private func scrollPreviewPage() {
        var candidates: [UIScrollView] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { collectScrollViews(window, into: &candidates) }
        }
        let visible = candidates.filter { scroll in
            !scroll.isHidden && scroll.bounds.height > 150 && scroll.contentSize.height > scroll.bounds.height
        }
        guard let scroll = visible.max(by: { $0.bounds.height < $1.bounds.height }) else { return }
        let end: CGFloat = max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y: CGFloat = AppPageScenario.scene.contains("middle") ? end * 0.45 : end
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
    private func collectScrollViews(_ view: UIView, into result: inout [UIScrollView]) {
        if let scroll = view as? UIScrollView { result.append(scroll) }
        for child in view.subviews { collectScrollViews(child, into: &result) }
    }

}

/// A per-process marker proves this scene appeared in an active window and at
/// least three subsequent display frames elapsed. The capture script separately
/// rejects empty white/black frames and requires two identical PNGs.
final class PreviewFrameReadiness: NSObject {
    static let shared = PreviewFrameReadiness()
    private var display: CADisplayLink?
    private var scene = "", frames = 0
    func begin(scene: String, after delay: TimeInterval) {
        self.scene = scene; frames = 0
        DispatchQueue.main.asyncAfter(deadline: .now()+delay) {
            self.display?.invalidate()
            let display = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            self.display = display; display.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active else { return }
        var hasWindow = false
        for connected in UIApplication.shared.connectedScenes {
            guard let windowScene = connected as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden && window.bounds.height > 100 { hasWindow = true }
        }
        guard hasWindow else { return }
        frames += 1
        guard frames >= 3 else { return }
        link.invalidate(); display = nil
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: ["scene":scene,"displayFrames":frames]) else { return }
        try? data.write(to: root.appendingPathComponent("preview-frame-ready.json"), options: .atomic)
    }
}

struct AppPagesScene: View {
    private var scene: String { AppPageScenario.scene }
    @ObservedObject private var map = MapFeeder.shared
    @ObservedObject private var navi = NaviBridge.shared
    var body: some View {
        Group {
            if scene.hasPrefix("page-journeys") {
                JourneyListView { _ in }
            } else if scene.hasPrefix("page-vias-editor") {
                ViaDraftPreviewHarness()
            } else if scene.hasPrefix("page-maintenance") {
                NavigationView { ScrollView { VStack(alignment:.leading,spacing:16) {
                    MapCacheManagementView()
                    Text("控件回调：继续 \(map.continueCount) · 放弃 \(map.discardCount)")
                        .font(.caption2).foregroundColor(ContentView.sub).accessibilityIdentifier("preview-action-counts")
                }.padding(16) }.background(ContentView.bg).navigationTitle("离线地图维护") }
            } else if scene.hasPrefix("page-diagnostics") {
                NavigationView { ScrollView { VStack(alignment:.leading,spacing:16) {
                    if scene.contains("sample") {
                        CardView { Text("电脑合成记录 · 仅展示汇总布局").foregroundColor(.yellow).font(.caption); PipelineSummaryView(summary:AppPageScenario.sampleSummary) }
                    } else { PerformanceRecordingView() }
                }.padding(16) }.background(ContentView.bg).navigationTitle("性能诊断") }
            } else if scene.hasPrefix("page-planner-drive") {
                ContentView(previewPage:0,previewDestination:.init(name:"测试目的地",address:"合成路线样本",lat:30.01,lng:120.02),previewTravelMode:2)
            } else if scene.hasPrefix("page-planner-") { IndependentPlannerView(mode:scene.contains("bicycle") ? .bicycle : .motorcycle) }
            else if scene.hasPrefix("page-navigation-independent") { IndependentNavigationView() }
            else if scene.hasPrefix("page-navigation-drive") { NaviScreen() }
            else if scene.hasPrefix("page-key-setup") { KeySetupView() }
            else if AppPageScenario.baseScene == "page-history" { NavigationView { RideHistoryView() } }
            else if AppPageScenario.baseScene == "page-place-picker" { PlacePickerView(title:"选择目的地",choose:{_ in}) }
            else if AppPageScenario.baseScene == "page-motor-login" { MotorLoginView(page:nil) }
            else {
                VStack(spacing: 0) {
                    ContentView(previewPage: scene.contains("display") ? 1 : scene.contains("voice") ? 2 : scene.contains("settings") ? 3 : scene.contains("keys") ? 4 : 0, previewExpanded: scene.contains("home-bottom"))
                    if scene.contains("home-active") {
                        Text("测试导航调用：开始 \(navi.startCount) · 停止 \(navi.stopCount)")
                            .font(.caption2).foregroundColor(ContentView.sub).accessibilityIdentifier("preview-navigation-counts")
                    }
                }
            }
        }.background(ContentView.bg)
    }
}

/// The sheet is the production editor. The surrounding disposable host records
/// only its public apply/cancel closures, so UI tests can inspect their results.
struct ViaDraftPreviewHarness: View {
    @State private var points = AppPageScenario.sampleVias
    @State private var showingEditor = true
    @State private var applied = 0
    @State private var cancelled = 0
    @State private var editingFinished = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("草稿编辑自测 · 合成途经点").font(.headline)
            Text(points.map(\.name).joined(separator: " → ")).accessibilityIdentifier("preview-vias-committed")
            Text("应用 \(applied) · 取消 \(cancelled)").accessibilityIdentifier("preview-vias-callbacks")
            Button("再次编辑草稿") { editingFinished = false; showingEditor = true }.accessibilityIdentifier("preview-vias-open")
        }.padding(16).foregroundColor(.white)
            .sheet(isPresented: $showingEditor, onDismiss: cancelIfNeeded) {
                ViaDraftEditor(points: points, limit: JourneyMode.drive.maximumVias,
                    onApply: { points = $0; applied += 1; editingFinished = true }, onCancel: cancelIfNeeded)
            }
    }
    private func cancelIfNeeded() {
        guard !editingFinished else { return }
        cancelled += 1; editingFinished = true
    }
}
#endif
