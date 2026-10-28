import SwiftUI
import CoreLocation
import AVFoundation

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 主界面：圆屏连接状态、搜索目的地 / 导入高德分享路线、选路线、开始导航、巡航、圆屏设置、Key 设置、调试信息
/// （深灰中性色界面）
struct ContentView: View {
    @ObservedObject var ble = BleLink.shared
    @ObservedObject var navi = NaviBridge.shared
    @ObservedObject var independent = WebMotorSession.shared
    @ObservedObject var search = SearchService.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var weather = Weather.shared
    @ObservedObject var map = MapFeeder.shared
    @ObservedObject var history = History.shared
    @ObservedObject var favorites = Favorites.shared
    @State private var page = 0
    @State private var showWebMotor = false
    @State private var independentMode: IndependentMode = .motorcycle
    @State private var plannerDestination: MotorPoint?
    @State private var homeTravelMode = 0 // 0 motorcycle, 1 bicycle, 2 drive; never silently substitutes a mode.
    @State private var homePanelExpanded = false
    @State private var homeCenterRequest = UUID()
    @ObservedObject private var homeLocation = LocationService.shared
    @State private var showRides = false
    @State private var showJourneyList = false
    @State private var showViaEditor = false
    @State private var viaEditTicket: RoutePlanningGeneration.Ticket?
    @AppStorage("voice_rate") private var voiceRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("voice_pitch") private var voicePitch = 1.0
    @AppStorage("voice_id") private var voiceID = ""

    @State private var query = ""
    @State private var dest: SearchService.Place?
    @State private var showNavi = false
    @State private var showDebug = false
    @State private var showKeys = false                 // iOS v0.7 填写地图 Key 页面
    private static var keyPrompted = false              // 这次打开 App 已经提醒过填 key 了
    @State private var shareBusy = false
    @State private var shareIntent = UUID()
    @State private var shareStatus = ""
    @State private var cruiseNote = ""
    @State private var addingVia = false               // 正在搜途经点

    #if MOTONAV_SCREENSHOTS
    /// Only the disposable simulator host can select an initial tab. The shipping
    /// target never defines this compilation flag or reads screenshot arguments.
    init(previewPage: Int = 0, previewDestination: SearchService.Place? = nil, previewTravelMode: Int = 0, previewExpanded: Bool = false) {
        _page = State(initialValue: min(4, max(0, previewPage)))
        _dest = State(initialValue: previewDestination)
        _query = State(initialValue: previewDestination?.name ?? "")
        _homePanelExpanded = State(initialValue: previewDestination != nil || previewExpanded)
        _homeTravelMode = State(initialValue: previewTravelMode)
        ContentView.keyPrompted = true
    }
    #endif

    static let bg = AppPalette.background
    static let card = AppPalette.surface
    static let stroke = AppPalette.border
    // Kept as source-compatible aliases for existing view hosts.
    static let pink = AppPalette.text
    static let cyan = AppPalette.accent
    static let sub = AppPalette.secondary

    var body: some View {
        VStack(spacing: 0) {
            activeNavigationBanner
            ZStack {
                ForEach([page], id: \.self) { index in
                    if index == 0 {
                        mapHome
                    } else { ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            if index == 1 { displayCard; MapCacheManagementView() }
                            else if index == 2 { voiceCard }
                            else if index == 3 { statusCard; settingsCard; PerformanceRecordingView(); debugCard }
                            else { keyCard; Text(weather.detail).foregroundColor(Self.sub) }
                        }.padding(16)
                    } }
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<5) { index in
                    Button { hideKeyboard(); page = index } label: {
                        VStack(spacing: 4) {
                            Image(systemName: ["map", "circle", "speaker.wave.2", "gearshape", "key"][index])
                            Text(["地图", "圆屏显示", "导航语音", "设备设置", "地图 Key"][index]).font(.system(size: 10))
                        }.frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 6)
                            .foregroundColor(page == index ? AppPalette.text : AppPalette.secondary)
                            .background(RoundedRectangle(cornerRadius: 12).fill(page == index ? AppPalette.raised : .clear))
                            .padding(.horizontal, 3)
                    }
                }
            }.padding(.horizontal, 8).padding(.top, 7).background(Self.card)
                .overlay(alignment: .top) { Rectangle().fill(AppPalette.border).frame(height: 1) }
        }
        .background(ContentView.bg.ignoresSafeArea())
        .appScreen()
        .fullScreenCover(isPresented: $showWebMotor) { WebMotorView(mode:independentMode, initialDestination:plannerDestination) }
        .sheet(isPresented: $showJourneyList) {
            JourneyListView { journey in
                if journey.mode == .drive {
                    homeTravelMode = 2; homePanelExpanded = true
                    dest = SearchService.Place(name: journey.destination.name, address: "", lat: journey.destination.lat, lng: journey.destination.lng)
                    query = journey.destination.name; page = 0; addingVia = false
                } else {
                    plannerDestination = nil
                    independentMode = journey.mode == .bicycle ? .bicycle : .motorcycle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showWebMotor = true }
                }
            }
        }
        .sheet(isPresented: $showViaEditor, onDismiss: { navi.cancelViaEditing(ticket: viaEditTicket) }) {
            ViaDraftEditor(points: navi.vias.map { .init(name: $0.name, lat: $0.lat, lng: $0.lng) }, limit: JourneyMode.drive.maximumVias,
                onApply: { navi.applyVias($0, ticket: viaEditTicket) }, onCancel: { navi.cancelViaEditing(ticket: viaEditTicket) })
        }
        .sheet(isPresented: $showRides) { NavigationView { RideHistoryView() } }
        .fullScreenCover(isPresented: $showNavi) { NaviScreen() }
        .sheet(isPresented: $showKeys) { KeySetupView() }
        .onAppear {                                    // iOS v0.7 打开 App 时，高德或高德 key 没填就提醒一次
            homeLocation.start()
            if !ContentView.keyPrompted && settings.keysMissing {
                ContentView.keyPrompted = true
                showKeys = true
            }
        }
        .onOpenURL { url in                            // iOS v0.4 高德里“分享到 MotoNav”：motonav://share?t=分享的文字
            guard url.scheme == "motonav",
                  let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value
            else { return }
            importShare(t)
        }
    }

    private var mapHome: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                HomeMapView(destination: dest, centerRequest: homeCenterRequest) { place in choose(place) }
                    .ignoresSafeArea(edges: .top)
                VStack(spacing: 10) {
                    homeSearchBar
                    HStack(spacing: 8) {
                        Button { page = 3 } label: {
                            Label(ble.isReady ? "圆屏已连接" : "连接圆屏", systemImage: ble.isReady ? "link" : "link.badge.plus")
                                .font(.caption.bold()).padding(.horizontal, 12).frame(minHeight: 44)
                        }.buttonStyle(.plain).background(Capsule().fill(Self.card))
                            .accessibilityIdentifier("home.device")
                        Spacer()
                        Button { homeLocation.start(); homeCenterRequest = UUID() } label: {
                            Image(systemName: "location.fill").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).background(Circle().fill(Self.card))
                            .accessibilityLabel("回到当前位置").accessibilityIdentifier("home.locate")
                    }
                    Spacer(minLength: 8)
                    homeBottomPanel(maxHeight: geometry.size.height * 0.66)
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            }
        }
    }

    private var homeSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(Self.sub)
            TextField(addingVia ? "搜索途经点" : "搜索地点、地址", text: $query)
                .textFieldStyle(.plain).submitLabel(.search)
                .onSubmit { performHomeSearch() }
                .onChange(of: query) { search.queryChanged($0) }
                .onTapGesture { homePanelExpanded = true }
                .accessibilityIdentifier("home.search")
            if !query.isEmpty {
                Button { query = ""; search.clear() } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundColor(Self.sub).accessibilityLabel("清除搜索文字")
            }
            Button("搜索") { performHomeSearch() }.font(.subheadline.bold()).frame(minHeight: 44)
        }.padding(.horizontal, 14).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 18).fill(Self.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Self.stroke, lineWidth: 1))
            .foregroundColor(AppPalette.text)
    }

    private func performHomeSearch() {
        hideKeyboard(); homePanelExpanded = true
        if !needAmapKey() { search.search(query) }
    }

    private func homeBottomPanel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            Button { hideKeyboard(); withAnimation(.easeInOut(duration: 0.2)) { homePanelExpanded.toggle() } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dest?.name ?? "去哪儿？").font(.headline).lineLimit(1)
                        Text(homePanelExpanded ? "地点、路线与骑行工具" : "搜索地点，或长按地图选目的地")
                            .font(.caption).foregroundColor(Self.sub).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: homePanelExpanded ? "chevron.down" : "chevron.up").frame(width: 32)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("home.panel.toggle")
                .accessibilityLabel(homePanelExpanded ? "收起地点与路线面板" : "展开地点与路线面板")
            Picker("出行方式", selection: Binding(get: { homeTravelMode }, set: { mode in
                guard !routeSwitchBlocked, mode != homeTravelMode else { return }
                homeTravelMode = mode; navi.clearPlan(); addingVia = false
                if mode == 2, let point = dest, !needAmapKey() { navi.plan(toLat: point.lat, lng: point.lng, name: point.name) }
            })) {
                Text("摩托车").tag(0); Text("自行车").tag(1); Text("驾车").tag(2)
            }.pickerStyle(.segmented).disabled(routeSwitchBlocked)
                .accessibilityIdentifier("home.travelMode")
            if !homePanelExpanded {
                if let place = dest {
                    Button(homeTravelMode == 2 ? "查看驾车路线" : "规划\(homeTravelMode == 1 ? "自行车" : "摩托车")路线") {
                        if homeTravelMode == 2 { homePanelExpanded = true }
                        else { openPlanner(homeTravelMode == 1 ? .bicycle : .motorcycle, destination: place) }
                    }.buttonStyle(AppSecondaryButtonStyle()).accessibilityIdentifier("home.plan")
                } else {
                    HStack(spacing: 8) {
                        Button("常用行程") { showJourneyList = true }.frame(maxWidth: .infinity).accessibilityIdentifier("journeys.open")
                        Button("导入路线") { homePanelExpanded = true; pasteShare() }.frame(maxWidth: .infinity)
                        Button("骑行工具") { homePanelExpanded = true }.frame(maxWidth: .infinity)
                    }.buttonStyle(AppSecondaryButtonStyle())
                }
                if let checkpoint = navi.pendingRecovery {
                    Button("继续上次路线 · \(checkpoint.destination.name)") { homePanelExpanded = true; restoreRoute(checkpoint) }
                        .font(.caption).frame(minHeight: 44)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        destCard
                        recoveryCard
                        favoritesCard
                        HStack(spacing: 10) {
                            Button("常用行程") { showJourneyList = true }.frame(maxWidth: .infinity).accessibilityIdentifier("journeys.open")
                            Button("骑行轨迹") { showRides = true }.frame(maxWidth: .infinity)
                        }.buttonStyle(AppSecondaryButtonStyle())
                        cruiseCard
                        DepartureReadinessView { showKeys = true }
                    }.padding(.bottom, 6)
                }.frame(maxHeight: max(180, maxHeight - 110))
            }
        }.padding(14).foregroundColor(AppPalette.text)
            .background(RoundedRectangle(cornerRadius: 22).fill(Self.card.opacity(0.98)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Self.stroke, lineWidth: 1))
    }

    private var activeNavigationBanner: some View {
        Group {
            if navi.navigating || independent.running {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("导航继续运行中").bold()
                        Text(independent.running ? (independent.route?.request.end.name ?? "当前目的地") : (navi.journeyDestination?.name ?? "当前目的地"))
                            .font(.caption).lineLimit(1)
                        Text(settings.voiceMuted ? "导航语音已静音" : "导航语音播报已开启")
                            .font(.caption).foregroundColor(settings.voiceMuted ? AppPalette.warning : AppPalette.accent)
                        if settings.voiceMuted { Button("恢复播报") { settings.voiceMuted = false }.font(.caption).accessibilityIdentifier("navigation.resumeVoice") }
                        Text(independent.running ? independent.instruction : "\(navi.uiDir) · \(navi.uiDist) 米")
                            .font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("回到导航") {
                        if independent.running { showWebMotor=true } else { showNavi=true }
                    }.foregroundColor(AppPalette.text).accessibilityIdentifier("navigation.continue")
                }.padding(12).background(Self.card).foregroundColor(AppPalette.text)
            }
        }
    }

    // MARK: 标题
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MotoNav")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundColor(AppPalette.text)
            Text("圆屏导航 · \(APP_VERSION)").font(.caption).foregroundColor(ContentView.sub)
        }
        .padding(.top, 8)
    }

    // MARK: 圆屏状态
    private var statusCard: some View {
        CardView {
            HStack {
                Circle().fill(ble.isReady ? AppPalette.success : AppPalette.warning).frame(width: 10, height: 10)
                Text("圆屏").foregroundColor(AppPalette.text).bold()
                Spacer()
                Button(ble.isReady ? "断开" : "连接") { ble.isReady ? ble.disconnect() : ble.connect() }
                    .foregroundColor(AppPalette.accent)
            }
            Text(ble.status).font(.footnote).foregroundColor(ContentView.sub)
            // iOS v0.6 圆屏画小地图时每 2 秒回报一次帧率
            if ble.isReady, Date().timeIntervalSince(ble.statAt) < 10, !ble.screenFps.isEmpty {
                Text("小地图 \(ble.screenFps) 帧/秒").font(.footnote).foregroundColor(ContentView.sub)
            }
            if navi.navigating {
                Text("导航中：\(navi.uiDir) \(navi.uiDist) 米 · \(navi.uiSpeed) km/h").font(.footnote).foregroundColor(AppPalette.accent)
                if navi.uiRemainM > 0 {
                    Text("剩余 \(NaviBridge.distText(navi.uiRemainM)) · 约 \(NaviBridge.durText(navi.uiRemainS)) · \(ContentView.etaText(navi.uiRemainS)) 到达")
                        .font(.footnote).foregroundColor(AppPalette.text)
                }
                Button("回到导航画面") { showNavi = true }.foregroundColor(AppPalette.text)
            }
            Text("小地图：\(map.shortStatus) · \(settings.theme == 2 ? "OpenFreeMap" : "高德") · \(Settings.themeName(settings.theme))")
                .font(.caption).foregroundColor(ContentView.sub)
        }
    }

    private var recoveryCard: some View {
        Group {
            if let checkpoint = navi.pendingRecovery {
                CardView {
                    Text("继续上次路线").foregroundColor(AppPalette.text).bold()
                    Text(checkpoint.destination.name.isEmpty ? "上次选择的目的地" : checkpoint.destination.name)
                        .foregroundColor(AppPalette.accent)
                    Text("将从当前位置重新规划，确认路线后再开始导航。")
                        .font(.caption).foregroundColor(ContentView.sub)
                    if !navi.recoveryStatus.isEmpty {
                        Text(navi.recoveryStatus).font(.caption).foregroundColor(AppPalette.warning)
                    }
                    Button(navi.recoveryBusy ? "正在重新规划…" : "重新规划上次路线") {
                        restoreRoute(checkpoint)
                    }
                    .foregroundColor(AppPalette.text)
                    .disabled(navi.recoveryBusy || navi.calculating || navi.navigating || navi.cruising || independent.running)
                    Button("放弃上次路线") { cancelPendingImport(); navi.discardPendingRecovery() }
                        .font(.caption).foregroundColor(ContentView.sub)
                }
            } else if !navi.recoveryStatus.isEmpty {
                Text(navi.recoveryStatus).font(.caption).foregroundColor(AppPalette.warning)
            }
        }
    }

    private func restoreRoute(_ checkpoint: NavigationRecoveryCheckpoint) {
        cancelPendingImport()
        guard !needAmapKey() else { return }
        if checkpoint.mode == .drive {
            homeTravelMode = 2; homePanelExpanded = true
            guard navi.restorePendingRecovery() else { return }
            let point = checkpoint.destination
            dest = SearchService.Place(name: point.name.isEmpty ? "恢复的目的地" : point.name,
                address: "", lat: point.lat, lng: point.lng)
            query = dest?.name ?? ""; addingVia = false; search.clear()
            shareStatus = "" // Existing route status displays planning, success or failure as it arrives.
        } else {
            Task { @MainActor in
                if await navi.preparePendingIndependentRecovery() {
                    plannerDestination = nil
                    independentMode = checkpoint.mode == .bicycle ? .bicycle : .motorcycle
                    showWebMotor = true
                }
            }
        }
    }

    // MARK: 去哪儿
    private var destCard: some View {
        CardView {
            // iOS v0.3 导入高德 App 分享的路线（比如高德里规划好的摩托车路线）
            if !addingVia {
            Button { pasteShare() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                    Text(shareBusy ? "正在读取分享的路线…" : "粘贴高德分享的路线")
                }
                .font(.subheadline).foregroundColor(AppPalette.warning)
            }
            .disabled(shareBusy)
            Text("在高德里规划好路线 → 分享 → 选 MotoNav；或者复制链接后点上面这行").font(.caption2).foregroundColor(ContentView.sub)
            }
            if !shareStatus.isEmpty { Text(shareStatus).font(.footnote).foregroundColor(ContentView.sub) }
            if !search.status.isEmpty { Text(search.status).font(.footnote).foregroundColor(ContentView.sub) }
            ForEach(search.results.prefix(8)) { p in
                Button { choose(p) } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundColor(AppPalette.text)
                            Text(p.address).font(.caption).foregroundColor(ContentView.sub).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let d = distanceTo(p) { Text(d).font(.caption).foregroundColor(AppPalette.accent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44).padding(.vertical, 6)
                }
                Divider().background(ContentView.stroke)
            }
            // iOS v0.4 最近去过（还没选目的地、或者正在选途经点时显示）
            if search.results.isEmpty && (dest == nil || addingVia) && !history.places.isEmpty {
                Text(addingVia ? "从最近去过里选途经点" : "最近去过").font(.caption).foregroundColor(ContentView.sub).padding(.top, 4)
                ForEach(history.places.prefix(8)) { p in
                    Button { choose(p) } label: {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundColor(AppPalette.text)
                                if !p.address.isEmpty { Text(p.address).font(.caption).foregroundColor(ContentView.sub).lineLimit(1) }
                            }
                            Spacer(minLength: 4)
                            if let d = distanceTo(p) { Text(d).font(.caption).foregroundColor(AppPalette.accent) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44).padding(.vertical, 4)
                    }
                    Divider().background(ContentView.stroke)
                }
                Button("清除记录") { history.clear() }.font(.caption).foregroundColor(ContentView.sub)
            }
            if let d = dest {
                HStack {
                    Text("目的地：\(d.name)").font(.footnote).foregroundColor(AppPalette.text)
                    Button("收藏") { favorites.add(d) }.foregroundColor(AppPalette.accent)
                    Spacer()
                    if !navi.navigating {
                        Button("换目的地") {
                            cancelPendingImport()
                            dest = nil; query = ""; addingVia = false; shareStatus = ""
                            search.clear()
                            navi.clearPlan()
                        }
                        .font(.caption).foregroundColor(AppPalette.accent)
                    }
                }
                if homeTravelMode != 2 {
                    Text(homeTravelMode == 1 ? "按自行车规则规划，不交给驾车引擎。" : "按摩托车规则规划，确认路线后再开始导航。")
                        .font(.caption).foregroundColor(ContentView.sub)
                    PillButton(title: "规划\(homeTravelMode == 1 ? "自行车" : "摩托车")路线", color: AppPalette.action,
                        enabled: !routeSwitchBlocked) { openPlanner(homeTravelMode == 1 ? .bicycle : .motorcycle, destination: d) }
                } else {
                if let sr = navi.shareRoute {
                    Text("按高德分享的\(sr.kind)路线走（原路线 \(NaviBridge.distText(Int(sr.total)))）").font(.caption).foregroundColor(AppPalette.warning)
                    if !navi.shareMatch.isEmpty { Text(navi.shareMatch).font(.caption).foregroundColor(ContentView.sub) }
                }
                if navi.shareRoute == nil {
                    Text(navi.vias.isEmpty ? "途经：无" : "途经：" + navi.vias.map { $0.name }.joined(separator: " → "))
                        .font(.caption).foregroundColor(ContentView.sub).lineLimit(3)
                    Button("编辑途经点（添加／删除／排序）") {
                        viaEditTicket = navi.beginViaEditing(); showViaEditor = viaEditTicket != nil
                    }.font(.caption).foregroundColor(AppPalette.accent).disabled(navi.navigating)
                }
                Toggle("不走高速", isOn: $settings.avoidHighway)
                    .foregroundColor(AppPalette.text).tint(AppPalette.control)
                    .onChange(of: settings.avoidHighway) { _ in navi.replanForPreferenceChange() }
                if navi.calculating || navi.routeOptions.isEmpty {
                    Text(navi.calculating ? "正在规划路线…" : navi.info).font(.footnote).foregroundColor(ContentView.sub)
                }
                if navi.planFailed && !navi.calculating {   // iOS v0.6 规划失败 / 超时
                    Text(navi.info).font(.caption).foregroundColor(AppPalette.warning)
                    Button { navi.replan() } label: {
                        Label("重新规划", systemImage: "arrow.clockwise").font(.subheadline.bold()).foregroundColor(AppPalette.accent)
                    }
                }
                if !navi.routeOptions.isEmpty {
                    RouteMapView(routes: navi.routeOptions, selected: navi.selectedRouteID,
                                 ghost: navi.shareRoute?.pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } ?? [],
                                 dest: navi.destCoord,
                                 vias: navi.vias.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
                                 night: settings.paletteNight)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack(spacing: 8) {
                        ForEach(navi.routeOptions) { o in
                            RouteCard(option: o, selected: o.id == navi.selectedRouteID)
                                .onTapGesture { navi.select(routeID: o.id) }
                        }
                    }
                }
                if navi.routeReady, navi.shareRoute == nil, let destination = navi.journeyDestination {
                    SaveJourneyButton(mode: .drive, destination: destination,
                        vias: navi.vias.map { .init(name: $0.name, lat: $0.lat, lng: $0.lng) }, avoidHighway: settings.avoidHighway)
                        .foregroundColor(AppPalette.accent)
                }
                HStack(spacing: 12) {
                    PillButton(title: "开始导航", color: AppPalette.action, enabled: navi.routeReady && !navi.editingVias) {
                        navi.start(emulate: false); showNavi = true
                    }
                    PillButton(title: "模拟导航", color: AppPalette.raised, secondary: true, enabled: navi.routeReady && !navi.editingVias) {
                        navi.start(emulate: true); showNavi = true
                    }
                }
                }
            }
        }
    }

    /// 离现在位置的直线距离（搜索结果、最近去过右边显示）
    private func distanceTo(_ p: SearchService.Place) -> String? {
        guard let me = navi.myPosition() else { return nil }
        let d = Int(NaviBridge.distM(me.lat, me.lng, p.lat, p.lng))
        return d >= 1000 ? String(format: "%.1f 公里", Double(d) / 1000) : "\(d) 米"
    }

    /// 剩余秒数 → 到达时间“18:52”
    static func etaText(_ remainS: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(TimeInterval(remainS)))
    }

    /// 点了搜索结果或最近去过：选目的地，或者（正在选途经点时）加一个途经点
    private func choose(_ p: SearchService.Place) {
        guard !navi.navigating else {shareStatus="导航仍在运行；如需更换目的地，请先结束导航";return}
        guard !WebMotorSession.shared.running else { shareStatus = "请先结束网页导航"; return }
        cancelPendingImport()
        search.clear()
        hideKeyboard()
        if addingVia {
            addingVia = false
            query = dest?.name ?? ""
            navi.addVia(name: p.name, lat: p.lat, lng: p.lng)
            return
        }
        dest = p
        query = p.name                                  // 只改文字，不会再触发搜索
        homePanelExpanded = true
        shareStatus = ""
        History.shared.add(p)
        if needAmapKey() { return }
        if homeTravelMode == 2 { navi.plan(toLat: p.lat, lng: p.lng, name: p.name) }
    }

    /// 读剪贴板里的高德分享链接，还原路线后按它规划
    private func pasteShare() {
        guard let t = UIPasteboard.general.string, AmapShare.findUrl(t) != nil else {
            cancelPendingImport()
            shareStatus = "剪贴板里没有高德的分享链接：先在高德里打开路线 → 分享 → 复制链接"
            return
        }
        importShare(t)
    }

    /// 导入高德分享的路线（剪贴板粘贴，或者从高德“分享到 MotoNav”过来）
    private func importShare(_ t: String) {
        guard !routeSwitchBlocked else { shareStatus = "请先完成或取消途经点编辑，并等待当前导航、巡航或规划结束"; return }
        cancelPendingImport()
        guard AmapShare.findUrl(t) != nil else { shareStatus = "分享的内容里没有高德链接"; return }
        addingVia = false
        hideKeyboard()
        shareBusy = true
        let intent = shareIntent
        shareStatus = "正在读取高德分享的路线…"
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Result { try AmapShare.load(t) }
            DispatchQueue.main.async {
                guard intent == shareIntent else { return }
                shareBusy = false
                guard !routeSwitchBlocked else { shareStatus = "当前会话已变化，请结束导航或巡航后重新导入"; return }
                switch res {
                case .success(let r):
                    guard !needAmapKey() else { shareStatus = "路线已读取；填写地图 Key 后请重新导入"; return }
                    if r.kind == "自行车" || r.kind == "摩托车" {
                        guard WebMotorSession.shared.installImportedPlan(MotorRoutes.fromShare(r), source: r) else {
                            shareStatus = "当前会话无法切换，路线未导入，请稍后重试"; return
                        }
                    }
                    shareStatus = "已读取：\(r.kind)路线 \(NaviBridge.distText(r.distance > 0 ? r.distance : Int(r.total)))" +
                        (r.timeS > 0 ? "，约 \(NaviBridge.durText(r.timeS))" : "") +
                        (r.restored ? "" : "（高德没能原样还原，可能和分享的稍有不同）")
                    let name = r.endName.isEmpty ? "分享的目的地" : r.endName
                    dest = SearchService.Place(name: name, address: "高德分享的\(r.kind)路线", lat: r.endLat, lng: r.endLng)
                    History.shared.add(SearchService.Place(name: name, address: "", lat: r.endLat, lng: r.endLng))
                    query = name
                    search.clear()
                    if r.kind == "自行车" || r.kind == "摩托车" {
                        plannerDestination = nil
                        independentMode = r.kind == "自行车" ? .bicycle : .motorcycle
                        showWebMotor = true
                    } else if !needAmapKey() { homeTravelMode = 2; homePanelExpanded = true; navi.plan(toLat: r.endLat, lng: r.endLng, share: r, name: name) }
                case .failure(let e):
                    shareStatus = "读取失败：\(e.localizedDescription)"
                }
            }
        }
    }

    private func cancelPendingImport() {
        shareIntent = UUID()
        shareBusy = false
        navi.cancelRecoveryAttempt()
    }

    private var routeSwitchBlocked: Bool {
        navi.navigating || navi.cruising || navi.calculating || navi.recoveryBusy || navi.editingVias || independent.running || RoutePlanningGeneration.shared.isBusy
    }

    private func openPlanner(_ mode: IndependentMode, destination: SearchService.Place? = nil) {
        guard !routeSwitchBlocked else { shareStatus = "请先结束当前导航或巡航，并等待规划或编辑完成"; return }
        cancelPendingImport()
        plannerDestination = destination.map { MotorPoint(lat: $0.lat, lng: $0.lng, name: $0.name) }
        independent.arrived = false; independentMode = mode; showWebMotor = true
    }

    // MARK: 巡航
    private var cruiseCard: some View {
        CardView {
            HStack {
                Text("巡航模式").foregroundColor(AppPalette.text).bold()
                Spacer()
                if navi.cruising { Text("进行中 · \(navi.uiSpeed) km/h").font(.caption).foregroundColor(AppPalette.accent) }
            }
            Text("不设目的地：骑车时提醒前方测速、电子眼和急弯、学校、事故多发等道路安全提示，圆屏照常显示小地图")
                .font(.caption).foregroundColor(ContentView.sub)
            if navi.cruising { Text(navi.info).font(.footnote).foregroundColor(ContentView.sub) }
            PillButton(title: navi.cruising ? "结束巡航" : "开始巡航", color: navi.cruising ? AppPalette.raised : AppPalette.action, secondary: navi.cruising,
                       enabled: !navi.navigating && !WebMotorSession.shared.running) {
                cruiseNote = ""
                if navi.cruising { navi.stopCruise() }
                else if !needAmapKey(), let err = navi.startCruise() { cruiseNote = err }
            }
            if !cruiseNote.isEmpty { Text(cruiseNote).font(.caption).foregroundColor(AppPalette.warning) }
        }
    }

    // MARK: 圆屏设置
    private var settingsCard: some View {
        CardView {
            Text("圆屏设置").foregroundColor(AppPalette.text).bold()
            Picker("开机动画", selection: $settings.bootBrand) {
                ForEach(Settings.bootBrands.indices, id: \.self) { i in Text(Settings.bootBrands[i]).tag(i) }
            }.tint(AppPalette.accent)
            Text(settings.bootStatus).font(.caption).foregroundColor(ContentView.sub)
            Toggle("蓝牙媒体按键（QQ 音乐等）", isOn: $settings.musicHID).foregroundColor(AppPalette.text).tint(AppPalette.control)
            if settings.musicHID {
                Text(ble.mediaHIDSupported
                     ? (ble.mediaHIDReady && ble.mediaHIDMode ? "媒体按键已就绪" : ble.mediaAMSControls > 0 && ble.mediaHIDMode ? "AMS 媒体控制已就绪，HID 当前不可用" : "请在 iPhone 设置 → 蓝牙中配对 MotoNav；按圆屏配对码提示完成")
                     : "需要圆屏 HID 固件 v7.9.0 或更新版，连接后自动同步")
                    .font(.caption).foregroundColor(ContentView.sub)
                if !ble.mediaSongInfo.isEmpty {
                    Text(ble.mediaSongInfo).font(.caption).foregroundColor(AppPalette.accent)
                }
                Toggle("显示逐句歌词", isOn: $settings.musicLyrics).foregroundColor(AppPalette.text).tint(AppPalette.control)
                Text("默认关闭，上方歌名、下方歌手。开启后按歌曲信息从 LRCLIB 匹配歌词，歌词显示在歌手下方；未匹配到时保留歌名和歌手。")
                    .font(.caption).foregroundColor(ContentView.sub)
                if !settings.musicLyrics && ble.mediaLyricsActive { Text("正在关闭圆屏歌词…").font(.caption).foregroundColor(ContentView.sub) }
                if settings.musicLyrics {
                    Text(ble.mediaLyricsSupported ? ble.mediaLyricsStatus : "需要圆屏固件 v7.11.0 或更新版")
                        .font(.caption).foregroundColor(AppPalette.accent)
                }
                Text("先在网易云或 QQ 音乐开始播放，再用圆屏控制。新固件通过 iPhone AMS 显示歌名、歌手和状态，信息取决于当前播放器提供的内容。HID SENT 表示按键已发送。")
                    .font(.caption).foregroundColor(ContentView.sub)
            } else {
                Button("授权 Apple Music 圆屏控制") { MusicBridge.shared.authorize() }
                    .foregroundColor(AppPalette.accent)
            }
            Text("关闭蓝牙媒体按键后，改用系统音乐 App 控制。不读取来电号码。巡航连续停车 10 分钟自动结束。")
                .font(.caption).foregroundColor(ContentView.sub)
            Text("圆屏方向").foregroundColor(AppPalette.text).padding(.top, 6)
            RotationDial(degrees: $settings.rotationDeg)      // iOS v0.5.1 按住圆盘转动调角度
            Text("按住圆盘转动（顺时针为正），浅色指针是画面上方在圆屏上朝的方向，圆屏会跟着实时转。转到 0°/90°/180°/270° 附近会吸住。任意角度要圆屏固件 v7.10.1；旧固件会转到最接近的 90°")
                .font(.caption2).foregroundColor(ContentView.sub)
            // iOS v0.6 屏幕刷新速度、快速刷屏（圆屏存起来并自动重启；当前值来自圆屏的帧率回报）
            Text("刷新速度").foregroundColor(AppPalette.text).padding(.top, 6)
            Picker("刷新速度", selection: Binding(get: { ble.screenMHz }, set: { ble.setScreenMHz($0) })) {
                Text("40 标准").tag(40); Text("60").tag(60); Text("80").tag(80)
            }
            .pickerStyle(.segmented)
            .disabled(!ble.isReady)
            Toggle("快速刷屏", isOn: Binding(get: { ble.screenFast == 1 }, set: { ble.setScreenFast($0) }))
                .foregroundColor(AppPalette.text).tint(AppPalette.control)
                .disabled(!ble.isReady)
            Text(ble.screenMHz < 0
                 ? "越快画面撕裂越轻；花屏就切回 40、关掉快速刷屏。切换后圆屏会自动重启。现在的值要等圆屏显示过小地图才知道"
                 : "越快画面撕裂越轻；花屏就切回 40、关掉快速刷屏。切换后圆屏会自动重启")
                .font(.caption2).foregroundColor(ContentView.sub)
            Toggle("亮度跟着昼夜自动调", isOn: $settings.brightAuto).foregroundColor(AppPalette.text).tint(AppPalette.control)
            if settings.brightAuto {
                HStack {
                    Text("白天").foregroundColor(AppPalette.text)
                    Slider(value: $settings.brightDay, in: 5...255, step: 5).tint(AppPalette.accent)
                    Text("\(Int(settings.brightDay))").font(.caption).foregroundColor(ContentView.sub).frame(width: 34)
                }
                HStack {
                    Text("夜间").foregroundColor(AppPalette.text)
                    Slider(value: $settings.brightNight, in: 5...255, step: 5).tint(AppPalette.accent)
                    Text("\(Int(settings.brightNight))").font(.caption).foregroundColor(ContentView.sub).frame(width: 34)
                }
                if !settings.brightDesc.isEmpty { Text(settings.brightDesc).font(.caption2).foregroundColor(ContentView.sub) }
            } else {
                HStack {
                    Text("亮度").foregroundColor(AppPalette.text)
                    Slider(value: $settings.brightness, in: 5...255, step: 5).tint(AppPalette.accent)
                    Text("\(Int(settings.brightness))").font(.caption).foregroundColor(ContentView.sub).frame(width: 34)
                }
            }
        }
    }

    private var displayCard: some View {
        CardView {
            Text("圆屏显示").foregroundColor(AppPalette.text).bold()
            Toggle("路程进度环", isOn: $settings.progressRing).foregroundColor(AppPalette.text).tint(AppPalette.control)
            Picker("预判", selection: $settings.leadMs) {
                Text("关闭").tag(0); Text("0.3秒").tag(300); Text("0.6秒").tag(600)
            }.pickerStyle(.segmented)
            Text("地图状态：\(map.shortStatus)").font(.caption).foregroundColor(Self.sub)
            HStack {
                Text("风格").foregroundColor(AppPalette.text)
                Spacer()
                Picker("风格", selection: $settings.theme) {
                    ForEach(Settings.themeOrder, id: \.self) { t in Text(Settings.themeName(t)).tag(t) }
                }
                .tint(AppPalette.accent)
            }
            Text(Settings.themeDesc(settings.theme)).font(.caption2).foregroundColor(ContentView.sub)
            Toggle("小地图", isOn: $settings.mapOn).foregroundColor(AppPalette.text).tint(AppPalette.control)
            if settings.mapOn {
                Text(settings.theme == 2 ? "地图来源：OpenFreeMap / OpenStreetMap（GTA5 矢量路网）" : "地图来源：高德")
                    .font(.caption).foregroundColor(ContentView.sub)
                if settings.mapSource == MapFeeder.SRC_AMAP && settings.theme == 1 {
                    Toggle("俯视建筑轮廓", isOn: $settings.buildings).foregroundColor(AppPalette.text).tint(AppPalette.control)
                    Text(ble.buildingsSupported ? "圆屏支持建筑图层，默认提取高德建筑俯视轮廓" : "正在查询圆屏建筑能力；确认前先显示普通底图")
                        .font(.caption2).foregroundColor(ContentView.sub)
                    if ble.isReady && !ble.buildingsSupported {
                        Button("重新查询建筑能力") { ble.retryBuildingCapability() }
                    }
                    if !map.buildingInfo.isEmpty { Text(map.buildingInfo).font(.caption).foregroundColor(ContentView.sub) }
                }
                Text(map.offlineStatus).font(.caption).foregroundColor(ContentView.sub)
                Text("选定路线后，前台自动下载沿途地图；锁屏使用已保存地图包。请等下载完成再出发。")
                    .font(.caption2).foregroundColor(ContentView.sub)
                Text("走过的路线").foregroundColor(AppPalette.text)
                Picker("走过的路线", selection: $settings.trail) {
                    Text("变灰").tag(1); Text("擦除").tag(2)
                }
                .pickerStyle(.segmented)
                Toggle("清爽模式", isOn: $settings.clean).foregroundColor(AppPalette.text).tint(AppPalette.control)
                Text("清爽模式：地图保留，去掉红绿灯、电子眼、安全提示、测速牌和行程信息").font(.caption2).foregroundColor(ContentView.sub)
            }
            Text("夜间配色").foregroundColor(AppPalette.text)
            Picker("夜间配色", selection: $settings.nightMode) {
                Text("自动（日出日落）").tag(0); Text("白天").tag(1); Text("夜间").tag(2)
            }
            .pickerStyle(.segmented)
            if !settings.nightDesc.isEmpty { Text(settings.nightDesc).font(.caption2).foregroundColor(ContentView.sub) }
            Toggle("弯道急缓上色", isOn: $settings.curve).foregroundColor(AppPalette.text).tint(AppPalette.control)
        }
    }
    private var favoritesCard: some View {
        CardView {
            Text("常用目的地").foregroundColor(AppPalette.text).bold()
            if favorites.places.isEmpty { Text("选择目的地后点收藏").foregroundColor(Self.sub) }
            ForEach(favorites.places) { place in
                HStack {
                    Button(place.name) { choose(place.searchPlace) }.foregroundColor(AppPalette.accent)
                    Spacer()
                    Button("移除") { favorites.remove(place) }.foregroundColor(Self.sub)
                }
            }
        }
    }
    private var voiceCard: some View {
        CardView {
            Text("导航语音").foregroundColor(AppPalette.text).bold()
            Toggle("导航静音", isOn: $settings.voiceMuted)
            Toggle("播报时压低音乐", isOn: $settings.duck)
            Picker("系统音色", selection: $voiceID) {
                Text("自动优选中文").tag("")
                ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            Text("语速"); Slider(value: $voiceRate, in: 0.3...0.6)
            Text("音调"); Slider(value: $voicePitch, in: 0.7...1.4)
            Button("试听播报") { Speech.shared.test() }
        }.foregroundColor(AppPalette.text).tint(AppPalette.control)
    }

    // MARK: Key 设置
    private var keyCard: some View {
        CardView {
            Text("Key 设置").foregroundColor(AppPalette.text).bold()
            Text("高德 Key：\(Settings.mask(settings.amapKeyInUse))（搜索、导航、巡航用）")
                .font(.footnote).foregroundColor(settings.amapKeyInUse.isEmpty ? AppPalette.warning : ContentView.sub)
            Text("和风天气：\(weather.host.isEmpty || weather.key.isEmpty ? "未配置（可选）" : "已配置")")
                .font(.footnote).foregroundColor(ContentView.sub)
            Button(settings.keysMissing ? "去填写" : "修改") { showKeys = true }
                .foregroundColor(AppPalette.accent)
        }
    }

    /// 没填高德 key：弹出填写页，返回 true（调用的地方就不往下做了）
    private func needAmapKey() -> Bool {
        if settings.amapKeyInUse.isEmpty { hideKeyboard(); showKeys = true; return true }
        return false
    }

    // MARK: 调试信息
    private var debugCard: some View {
        CardView {
            Button(showDebug ? "收起调试信息" : "调试信息") { showDebug.toggle() }.foregroundColor(AppPalette.accent)
            if showDebug {
                Text("""
                圆屏：\(ble.status)
                已发送 \(ble.sentCount) 条，最近：\(ble.lastSent)
                \(ble.screenStats)
                导航：\(navi.info)
                路名：\(navi.uiRoad)
                \(navi.laneRaw)
                电子眼：\(navi.camRaw)
                巡航：\(navi.cruiseRaw)
                \(navi.extraInfo)
                小地图：\(map.infoText)
                地图数据累计发送 \(ble.bulkKB) KB
                天气：\(weather.info)
                """)
                .font(.caption.monospaced())
                .foregroundColor(ContentView.sub)
                .textSelection(.enabled)
            }
        }
    }
}

// MARK: - 小组件

struct CardView<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(ContentView.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ContentView.stroke, lineWidth: 1))
            .foregroundColor(AppPalette.text)
    }
}

/// 一条路线的对比卡片：标签、时间、距离 · 红绿灯 · 收费
struct RouteCard: View {
    let option: NaviBridge.RouteOption
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.label).font(.caption).foregroundColor(selected ? AppPalette.text : ContentView.sub).lineLimit(1)
            Text(NaviBridge.durText(option.timeS)).font(.headline).foregroundColor(AppPalette.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(NaviBridge.distText(option.length) + (option.lights > 0 ? " · \(option.lights)灯" : "") + (option.toll > 0 ? " · ¥\(option.toll)" : ""))
                .font(.caption2).foregroundColor(ContentView.sub).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? AppPalette.raised : AppPalette.background))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? AppPalette.accent : AppPalette.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

struct PillButton: View {
    let title: String
    let color: Color
    var secondary = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline)
                .foregroundColor(enabled ? (secondary ? AppPalette.text : AppPalette.actionText) : AppPalette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(enabled ? color : AppPalette.raised))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(secondary || !enabled ? AppPalette.border : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 收起键盘
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
