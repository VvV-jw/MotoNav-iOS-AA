import SwiftUI
import CoreLocation

enum IndependentMode: String, CaseIterable, Identifiable {
    case motorcycle="摩托车", bicycle="自行车"
    var id: String { rawValue }
}

final class IndependentPlanner: ObservableObject {
    @Published private var origin = RouteOriginSelection<MotorPoint>()
    var start: MotorPoint? {
        get { origin.selectedPlace }
        set { origin.selectedPlace = newValue }
    }
    @Published var end: MotorPoint?
    @Published var vias: [MotorPoint]=[]
    @Published var routes: [MotorRoute]=[]
    @Published var selected=0
    @Published var busy=false
    @Published var editingVias=false
    @Published var message=""
    private var generation=UUID()
    private var task: Task<Void,Never>?
    private var planningTicket: RoutePlanningGeneration.Ticket?
    private let viaDraftLease = RouteDraftLease()
    private var viaEditTicket: RoutePlanningGeneration.Ticket?
    func invalidate() {
        if let ticket = viaEditTicket { viaDraftLease.cancel(ticket) }
        viaEditTicket = nil; editingVias = false
        generation=UUID()
        if let ticket=planningTicket { RoutePlanningGeneration.shared.cancel(ticket) }
        planningTicket=nil;task?.cancel();task=nil;routes=[];selected=0;busy=false
    }
    func beginViaEditing() -> RoutePlanningGeneration.Ticket {
        if busy { message = "已暂停本次规划；取消草稿后可重新规划" }
        generation = UUID()
        if let ticket = planningTicket { RoutePlanningGeneration.shared.cancel(ticket) }
        planningTicket = nil; task?.cancel(); task = nil; busy = false; editingVias = true
        let ticket = viaDraftLease.begin(); viaEditTicket = ticket; return ticket
    }
    func cancelViaEditing(_ ticket: RoutePlanningGeneration.Ticket?) {
        guard let ticket = ticket, viaDraftLease.cancel(ticket) else { return }
        editingVias = false; viaEditTicket = nil
    }
    func applyVias(_ points: [JourneyPoint], ticket: RoutePlanningGeneration.Ticket?, mode: IndependentMode) {
        guard let ticket = ticket, editingVias else { return }
        guard viaDraftLease.apply(ticket, commit: {
            editingVias = false; viaEditTicket = nil
            vias = points.map { MotorPoint(lat: $0.lat, lng: $0.lng, name: $0.name) }
            plan(mode)
        }) else {
            cancelViaEditing(ticket); routes = []; message = "行程已变化，旧草稿未应用，请重新核对路线"; return
        }
    }
    func plan(_ mode: IndependentMode) {
        guard !editingVias else { return }
        guard vias.count <= (mode == .bicycle ? 0 : JourneyMode.motorcycle.maximumVias) else { message = "此出行方式不支持当前途经点数量"; return }
        guard WebMotorSession.shared.candidateAvailability.canInstallCandidate() else { message="请先结束当前导航、巡航或路线规划";return }
        guard !Settings.shared.keysMissing else { message="请先在地图 Key 页面填写自己的高德 iOS Key";return }
        let source = origin.source
        guard let startPoint = origin.resolve(current: {
            guard LocationService.shared.readiness(at: Date()).usable,
                  let fix=LocationService.shared.location,
                  NavigationRecoveryCheckpoint.acceptsFix(lat:fix.coordinate.latitude,lng:fix.coordinate.longitude,
                    accuracy:fix.horizontalAccuracy,timestamp:fix.timestamp) else { return nil }
            let g=MapGeo.wgsToGcj(fix.coordinate.latitude,fix.coordinate.longitude)
            return MotorPoint(lat:g.lat,lng:g.lng,name:"我的位置")
        }) else { message="当前位置尚未就绪，请等待定位或手动选择起点";LocationService.shared.start();return }
        guard let end=end else { message="请选择目的地";return }
        invalidate();let token=generation;let planTicket=RoutePlanningGeneration.shared.begin()
        planningTicket=planTicket
        let request=MotorRequest(start:startPoint,end:end,vias:mode == .bicycle ? [] : vias,bicycle:mode == .bicycle,originSource:source)
        busy=true;message="正在规划\(mode.rawValue)路线…"
        task=Task { @MainActor [weak self] in
            do {
                let result=try await MotorRoutes.load(request)
                guard let self=self,self.generation==token,!Task.isCancelled else { return }
                guard RoutePlanningGeneration.shared.finish(planTicket), WebMotorSession.shared.candidateAvailability.canInstallCandidate() else {
                    self.busy=false;self.message="当前导航已开始，本次规划已取消";return
                }
                guard let first = result.first, WebMotorSession.shared.selectCandidate(first) else {
                    self.busy=false;self.message="当前会话无法接收路线，请稍后重试";return
                }
                self.routes=result;self.selected=0;self.busy=false
                self.message="已找到 \(result.count) 条路线，请选择方案"
            } catch {
                guard let self=self,self.generation==token,!Task.isCancelled else { return }
                guard RoutePlanningGeneration.shared.finish(planTicket) else {
                    self.busy=false;self.message="当前会话已变化，本次规划已取消";return
                }
                self.busy=false;self.message=error.localizedDescription
            }
        }
    }
}

struct PlacePickerView: View {
    let title: String
    let choose: (MotorPoint)->Void
    @StateObject private var search=SearchService()
    @State private var query=""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                HStack {
                    TextField("搜索地点或地址",text:$query).submitLabel(.search).onSubmit{search.search(query)}
                        .onChange(of:query){search.queryChanged($0)}
                    Button("搜索"){search.search(query)}
                }
                if !search.status.isEmpty { Text(search.status).font(.caption) }
                ForEach(search.results) { p in
                    Button {
                        search.clear();choose(MotorPoint(lat:p.lat,lng:p.lng,name:p.name));dismiss()
                    } label: {
                        VStack(alignment:.leading,spacing:4){Text(p.name);Text(p.address).font(.caption).foregroundColor(AppPalette.secondary)}
                    }
                }
                if search.results.isEmpty && query.isEmpty {
                    ForEach(History.shared.places) { p in
                        Button(p.name){search.clear();choose(MotorPoint(lat:p.lat,lng:p.lng,name:p.name));dismiss()}
                    }
                }
            }.appListSurface().navigationTitle(title).toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){search.clear();dismiss()}}}
        }.appScreen()
            .onDisappear{search.clear()}
    }
}

struct MotorLoginView: View {
    @StateObject private var browser=MotorBrowser()
    let page: URL?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            VStack {
                Text("仅在登录或验证时打开网页。登录保存在本机，正常规划可直接在 App 完成。").font(.caption).padding()
                MotorBrowserView(browser:browser)
                Text(browser.status).font(.caption)
            }.navigationTitle("高德登录／验证").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}
        }.onAppear{if let page=page {browser.web.load(URLRequest(url:page))}}
    }
}

struct IndependentPlannerView: View {
    @StateObject private var model=IndependentPlanner()
    @ObservedObject var guide=WebMotorSession.shared
    @State private var mode: IndependentMode
    @State private var pick: Int? // 0 origin, 1 destination, 2 via
    @State private var login=false
    @State private var showViaEditor=false
    @State private var viaEditorTicket: RoutePlanningGeneration.Ticket?
    @State private var loaded=false
    @Environment(\.dismiss) private var dismiss
    init(mode: IndependentMode) { _mode=State(initialValue:mode) }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Picker("出行方式",selection:$mode){ForEach(IndependentMode.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                        .onChange(of:mode){_ in model.invalidate();model.message="";if mode == .bicycle { model.vias=[] }}
                    CardView {
                        Button{pick=0}label:{Label(model.start?.name.isEmpty == false ? model.start!.name : "我的位置（点此更改起点）",systemImage:"location")}
                        if model.start != nil {Button("使用当前位置"){model.start=nil;model.invalidate()}.font(.caption)}
                        Divider()
                        Button{pick=1}label:{Label(model.end?.name.isEmpty == false ? model.end!.name : "输入目的地",systemImage:"mappin.and.ellipse")}
                        if mode == .motorcycle {
                            Text(model.vias.isEmpty ? "途经：无" : model.vias.map { $0.name }.joined(separator: " → "))
                                .font(.caption).foregroundColor(ContentView.sub)
                            Button("编辑途经点（添加／删除／排序）") { viaEditorTicket = model.beginViaEditing(); showViaEditor = true }
                        }
                        PillButton(title:model.busy ? "正在规划…" : "规划\(mode.rawValue)路线",color:AppPalette.action,enabled:!model.busy && model.end != nil){model.plan(mode)}
                    }
                    if !model.message.isEmpty {Text(model.message).font(.footnote).foregroundColor(ContentView.sub)}
                    if mode == .motorcycle {Button("高德登录／验证"){login=true}.font(.footnote).foregroundColor(AppPalette.accent)}
                    if let route=model.routes.indices.contains(model.selected) ? model.routes[model.selected] : nil {
                        MotorMap(route:route,position:nil,overview:true).frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
                        ForEach(Array(model.routes.enumerated()),id:\.offset){i,r in
                            Button{if guide.selectCandidate(r){model.selected=i}else{model.message="请先结束当前导航、巡航或路线规划"}}label:{
                                HStack{
                                    Image(systemName:model.selected==i ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment:.leading,spacing:4){Text("方案 \(i+1) · \(NaviBridge.durText(r.seconds))").bold();Text(NaviBridge.distText(r.totalMeters)).font(.subheadline)}
                                    Spacer()
                                }.padding(14).background(RoundedRectangle(cornerRadius:16).fill(model.selected == i ? AppPalette.raised : AppPalette.surface))
                                    .overlay(RoundedRectangle(cornerRadius:16).stroke(model.selected == i ? AppPalette.accent : AppPalette.border, lineWidth:1))
                            }
                        }
                        SaveJourneyButton(mode: mode == .bicycle ? .bicycle : .motorcycle,
                            destination: .init(name: route.request.end.name, lat: route.request.end.lat, lng: route.request.end.lng),
                            vias: route.request.vias.map { .init(name: $0.name, lat: $0.lat, lng: $0.lng) })
                        HStack {
                            PillButton(title:"开始导航",color:AppPalette.action,enabled:!model.busy && !model.editingVias){begin(route,false)}
                            PillButton(title:"模拟导航",color:AppPalette.raised,secondary:true,enabled:!model.busy && !model.editingVias){begin(route,true)}
                        }
                    }
                    Text(mode == .motorcycle ? "路线由高德摩托车网页服务规划；登录或验证过期时按上方入口处理。" : "使用高德 iOS SDK 自行车规划，路线不会交给驾车导航引擎。").font(.caption).foregroundColor(ContentView.sub)
                    if mode == .motorcycle { Text("摩托车规划采用默认道路规则，暂不提供自定义不走高速选项。").font(.caption).foregroundColor(ContentView.sub) }
                }.padding(16)
            }.background(ContentView.bg).navigationTitle("\(mode.rawValue)路线")
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("返回首页"){dismiss()}}}
        }.appScreen()
        .sheet(isPresented:Binding(get:{pick != nil},set:{if !$0{pick=nil}})){
            PlacePickerView(title:pick==0 ? "选择起点" : pick==2 ? "选择途经点" : "选择目的地"){point in
                if pick==0{model.start=point}else if pick==2{model.vias.append(point)}else{model.end=point}
                model.invalidate();pick=nil
            }
        }
        .sheet(isPresented:$showViaEditor, onDismiss:{ model.cancelViaEditing(viaEditorTicket) }) {
            ViaDraftEditor(points:model.vias.map { .init(name:$0.name,lat:$0.lat,lng:$0.lng) }, limit:JourneyMode.motorcycle.maximumVias,
                onApply: { model.applyVias($0, ticket: viaEditorTicket, mode: mode) },
                onCancel:{ model.cancelViaEditing(viaEditorTicket) })
        }
        .sheet(isPresented:$login){MotorLoginView(page:nil)}
        .onAppear{
            guard !loaded else{return};loaded=true
            if let route=guide.route,route.request.bicycle == (mode == .bicycle),!guide.running {
                model.start=RouteOriginSelection(source:route.request.originSource,plannedStart:route.request.start).selectedPlace
                model.end=route.request.end;model.vias=route.request.vias;model.routes=[route]
            }
        }
        .onDisappear{model.invalidate()}
    }
    private func begin(_ route:MotorRoute,_ simulate:Bool){
        guard !model.editingVias, guide.candidateAvailability.canInstallCandidate() else{model.message="请先结束当前导航、巡航或路线规划";return}
        if !simulate, route.request.originSource == .currentLocation {
            guard let fresh = JourneyLibrary.freshPosition(), NaviBridge.distM(route.request.start.lat, route.request.start.lng, fresh.lat, fresh.lng) <= 100 else {
                model.invalidate(); model.message = "定位已过期或位置已变化，请重新规划后再开始导航"; return
            }
        }
        History.shared.add(SearchService.Place(name:route.request.end.name,address:"",lat:route.request.end.lat,lng:route.request.end.lng))
        guide.start(route,simulate:simulate)
    }
}

struct IndependentNavigationView: View {
    @ObservedObject var guide=WebMotorSession.shared
    @ObservedObject var settings=Settings.shared
    @ObservedObject var metadata=WebRouteMetadata.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmExit=false
    @State private var confirmSkip=false
    @State private var pendingSkip: JourneySkipIntent?
    @State private var pendingExit: UUID?
    var body: some View {
        ZStack(alignment:.top){
            if let route=guide.route {MotorMap(route:route,position:guide.position,overview:guide.overview).ignoresSafeArea()}
            VStack(spacing:12){
                HStack(alignment:.center,spacing:18){
                    Image(systemName:arrow).font(.system(size:48,weight:.bold)).foregroundColor(AppPalette.text).frame(width:58)
                    VStack(alignment:.leading,spacing:6){
                        Text(NaviBridge.distText(guide.turnMetres)).font(.system(size:30,weight:.heavy))
                        Text(guide.instruction).font(.headline).lineLimit(2)
                        Text(guide.status).font(.caption).foregroundColor(ContentView.sub)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let notice = guide.recalculationNotice.snapshot(at: context.date) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(notice.title).foregroundColor(notice.phase == .failed ? AppPalette.warning : AppPalette.accent)
                                    Text(notice.detail).foregroundColor(ContentView.sub).lineLimit(2)
                                    Text(notice.retryHint).foregroundColor(ContentView.sub).lineLimit(2)
                                }.font(.caption2)
                            }
                        }
                    };Spacer(minLength:0)
                }.padding(18).background(RoundedRectangle(cornerRadius:20).fill(AppPalette.surface.opacity(0.97)))
                    .overlay(RoundedRectangle(cornerRadius:20).stroke(AppPalette.border,lineWidth:1))
                Spacer()
                VStack(spacing:12){
                    HStack{
                        Text("\(guide.speed)").font(.system(size:32,weight:.bold))+Text(" km/h").font(.caption)
                        Spacer()
                        VStack(alignment:.trailing){Text("剩余 \(NaviBridge.distText(guide.remaining))").bold();Text("约 \(NaviBridge.durText(guide.remainingSeconds))").font(.caption)}
                    }
                    if !metadata.status.isEmpty {Text(metadata.status).font(.caption2).foregroundColor(ContentView.sub)}
                    if let name = guide.nextViaName {
                        Text("下一站：\(name)").font(.caption)
                        Button(guide.skipBusy ? "正在规划跳过…" : "跳过下一站") { pendingSkip=guide.skipIntent; confirmSkip=pendingSkip != nil }.disabled(!guide.canSkipVia)
                        if guide.simulation { Text("手动跳过需要真实的新鲜定位，模拟导航不支持").font(.caption2) }
                    }
                    if !guide.skipStatus.isEmpty { Text(guide.skipStatus).font(.caption).foregroundColor(AppPalette.warning) }
                    Text(settings.voiceMuted ? "导航语音已静音" : "导航语音播报已开启").font(.caption).foregroundColor(settings.voiceMuted ? AppPalette.warning : AppPalette.accent)
                    VStack(spacing: 8) {
                        if dynamicTypeSize >= .xxLarge {
                            voiceAction
                            homeAction
                        } else {
                            HStack(spacing: 10) { voiceAction; homeAction }
                        }
                        Button("全览／跟随"){guide.overview.toggle()}.buttonStyle(AppListActionStyle())
                    }
                    if guide.simulation {
                        HStack(spacing:10){Button(guide.paused ? "继续" : "暂停"){guide.paused.toggle()};Button("\(guide.speed) km/h"){guide.speed=guide.speed==60 ? 120 : guide.speed==120 ? 180 : 60}}.buttonStyle(AppSecondaryButtonStyle())
                    }
                    Button("结束导航"){pendingExit=guide.navigationOwner;confirmExit=pendingExit != nil}.foregroundColor(AppPalette.error).frame(minHeight:44)
                }.padding(18).background(RoundedRectangle(cornerRadius:20).fill(AppPalette.surface.opacity(0.97)))
                    .overlay(RoundedRectangle(cornerRadius:20).stroke(AppPalette.border,lineWidth:1))
            }.padding(16)
            if guide.arrived {
                VStack(spacing:18){Text("已到达目的地").font(.title.bold());Button("返回首页"){guide.arrived=false;dismiss()}}
                    .padding(30).background(RoundedRectangle(cornerRadius:22).fill(ContentView.bg)).frame(maxHeight:.infinity)
            }
        }.appScreen()
        .confirmationDialog("跳过下一站？",isPresented:$confirmSkip){Button("跳过并重新规划"){guide.skipNextVia(expected:pendingSkip)};Button("继续原路线",role:.cancel){}}message:{Text("新路线成功且位置、行程仍匹配后才替换；失败继续原导航。")}
        .alert("结束导航？",isPresented:$confirmExit){Button("结束",role:.destructive){if guide.stop(ifOwner:pendingExit){guide.arrived=false;dismiss()}};Button("继续导航",role:.cancel){}}
    }
    private var voiceAction: some View {
        Button(settings.voiceMuted ? "恢复播报" : "静音") {
            settings.voiceMuted.toggle(); if settings.voiceMuted { Speech.shared.stopNow() }
        }.buttonStyle(AppSecondaryButtonStyle()).accessibilityIdentifier("navigation.resumeVoice")
    }
    private var homeAction: some View {
        Button("返回首页") { dismiss() }.buttonStyle(AppSecondaryButtonStyle()).accessibilityIdentifier("navigation.home")
    }
    private var arrow:String {
        switch guide.turnDirection {case "L":return "arrow.turn.up.left";case "R":return "arrow.turn.up.right";case "SL":return "arrow.up.left";case "SR":return "arrow.up.right";case "U":return "arrow.uturn.down";default:return "arrow.up"}
    }
}
