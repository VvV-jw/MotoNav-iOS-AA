#if MOTONAV_SCREENSHOTS
import SwiftUI
import UIKit

enum AppPageScenario {
    static let scene = ProcessInfo.processInfo.arguments.dropFirst().first(where: { $0.hasPrefix("page-") }) ?? "page-home-top"
    static var largeFont: Bool { scene.contains("large-font") }
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
        let map = MapFeeder.shared
        Settings.shared.theme = scene == "page-maintenance-mismatch" ? 2 : 1
        if scene.contains("maintenance") || scene.contains("display-bottom") {
            map.recoverablePreparation = PreparationRecoveryCheckpoint(savedAt: Date(), key: "synthetic-preview-route", points: [.init(lat:30,lng:120),.init(lat:30.01,lng:120.02)], frameLat: 30, frameLng: 120, frameID: 1, source: 3, style: 1, buildings: true, buildingPreference: true, rangeKm: 20, forceRefresh: true, refreshStartedAt: Date())
            map.preparationSaveState = .saved
        }
        if scene.contains("saving") { map.preparationSaveState = .saving }
        if scene.contains("failed") { map.preparationSaveState = .notSaved(.storage) }
        if scene.contains("too-large") { map.preparationSaveState = .notSaved(.tooLarge) }
        if scene.contains("planner-") { WebMotorSession.shared.route = .sample(bicycle: scene.contains("bicycle")) }
        if scene.contains("planner-drive") {
            NaviBridge.shared.routeOptions = [
                .init(id:1,label:"推荐路线 · 合成样本",timeS:1200,length:12000,lights:8,toll:0),
                .init(id:2,label:"备选路线 · 合成样本",timeS:1500,length:14500,lights:11,toll:0)]
            NaviBridge.shared.selectedRouteID = 1; NaviBridge.shared.routeReady = true
        }
        if scene.contains("navigation-independent") {
            WebMotorSession.shared.route = .sample(); WebMotorSession.shared.running = true
            WebMotorSession.shared.simulation = true
        }
        if scene.contains("navigation-drive") { NaviBridge.shared.navigating = true; NaviBridge.shared.emulating = true }
        if scene.contains("home-bottom") {
            History.shared.add(.init(name: "测试目的地", address: "合成样本，不含个人位置", lat:30, lng:120))
            Favorites.shared.add(.init(name: "测试常用地点", address: "合成样本", lat:30.01, lng:120.02))
        }
    }
}

@main struct AppPagesPreview: App {
    init() { AppPageScenario.prepare() }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("界面自测 · 合成输入 · 未接真机").font(.caption2).foregroundColor(.yellow).padding(.vertical, 4)
                    .frame(maxWidth: .infinity).background(Color.black)
                AppPagesScene()
            }.preferredColorScheme(.dark)
                .environment(\.dynamicTypeSize, AppPageScenario.largeFont ? .accessibility1 : .large)
                .onAppear { scheduleScroll() }
        }
    }
    private func scheduleScroll() {
        guard AppPageScenario.scene.contains("bottom") || AppPageScenario.scene.contains("middle") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now()+1.3) {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            func collect(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            guard let scroll = windows.flatMap({ collect($0) }).filter({ !$0.isHidden && $0.bounds.height > 150 && $0.contentSize.height > $0.bounds.height }).max(by: { $0.bounds.height < $1.bounds.height }) else { return }
            let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
            let y = AppPageScenario.scene.contains("middle") ? end*0.45 : end
            scroll.setContentOffset(CGPoint(x:0,y:y), animated: false)
        }
    }
}

struct AppPagesScene: View {
    private var scene: String { AppPageScenario.scene }
    @ObservedObject private var map = MapFeeder.shared
    var body: some View {
        Group {
            if scene.hasPrefix("page-maintenance") {
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
                ContentView(previewPage:0,previewDestination:.init(name:"测试目的地",address:"合成路线样本",lat:30.01,lng:120.02))
            } else if scene.hasPrefix("page-planner-") { IndependentPlannerView(mode:scene.contains("bicycle") ? .bicycle : .motorcycle) }
            else if scene == "page-navigation-independent" { IndependentNavigationView() }
            else if scene == "page-navigation-drive-controls" { NaviScreen() }
            else if scene.hasPrefix("page-key-setup") { KeySetupView() }
            else if scene == "page-history" { NavigationView { RideHistoryView() } }
            else if scene == "page-place-picker" { PlacePickerView(title:"选择目的地",choose:{_ in}) }
            else if scene == "page-motor-login" { MotorLoginView(page:nil) }
            else { ContentView(previewPage: scene.contains("display") ? 1 : scene.contains("voice") ? 2 : scene.contains("settings") ? 3 : scene.contains("keys") ? 4 : 0) }
        }.background(ContentView.bg)
    }
}
#endif
