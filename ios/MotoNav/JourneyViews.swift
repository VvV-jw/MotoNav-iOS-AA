import SwiftUI

final class JourneyLibrary: ObservableObject {
    static let shared = JourneyLibrary()
    @Published private(set) var entries: [SavedJourney] = []
    @Published var message = ""
    @Published private(set) var busy = false
    private let store = JourneyStore()
    private var intent = UUID()
    private var planningTicket: RoutePlanningGeneration.Ticket?
    init() {
        do { entries = try store.load() }
        catch { message = "常用行程读取失败：\(error.localizedDescription)" }
    }
    @discardableResult func add(_ journey: SavedJourney) -> Bool { commit(entries + [journey]) }
    @discardableResult func remove(_ id: UUID) -> Bool { commit(entries.filter { $0.id != id }) }
    @discardableResult func rename(_ id: UUID, _ name: String) -> Bool {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
        next[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit(next)
    }
    private func commit(_ next: [SavedJourney]) -> Bool {
        do { try store.save(next); entries = next; message = "已保存"; return true }
        catch { message = "常用行程未保存：\(error.localizedDescription)"; return false }
    }
    func cancelPlanning() {
        intent = UUID(); busy = false
        if let ticket = planningTicket { RoutePlanningGeneration.shared.cancel(ticket) }
        planningTicket = nil
    }
    @MainActor func plan(_ journey: SavedJourney) async -> Bool {
        guard journey.isValid, !busy, WebMotorSession.shared.candidateAvailability.canInstallCandidate() else {
            message = "请先结束当前导航、巡航或规划"; return false
        }
        guard !Settings.shared.keysMissing else { message = "请先填写高德 iOS Key"; return false }
        guard let origin = Self.freshPosition() else { message = "请等待新的手机定位，再使用常用行程"; LocationService.shared.start(); return false }
        if journey.mode == .drive {
            let accepted = NaviBridge.shared.planJourney(journey)
            message = accepted ? "正在从当前位置规划；完成后请显式开始导航" : NaviBridge.shared.recoveryStatus
            return accepted
        }
        // This service does not expose a configurable highway strategy. Do not
        // silently discard a saved preference or substitute the driving engine.
        guard !journey.avoidHighway else { message = "此独立规划引擎不支持自定义不走高速设置，请调整行程后再使用"; return false }
        intent = UUID(); let requestIntent = intent
        let ticket = RoutePlanningGeneration.shared.begin(); busy = true
        planningTicket = ticket
        message = "正在从当前位置规划\(journey.mode.title)路线…"
        defer { if requestIntent == intent { busy = false; planningTicket = nil }; RoutePlanningGeneration.shared.finish(ticket) }
        let request = MotorRequest(start: MotorPoint(lat: origin.lat, lng: origin.lng, name: "我的位置"),
            end: MotorPoint(lat: journey.destination.lat, lng: journey.destination.lng, name: journey.destination.name),
            vias: journey.vias.map { MotorPoint(lat: $0.lat, lng: $0.lng, name: $0.name) },
            bicycle: journey.mode == .bicycle, originSource: .currentLocation)
        do {
            let routes = try await MotorRoutes.load(request)
            guard requestIntent == intent, RoutePlanningGeneration.shared.accepts(ticket), !Task.isCancelled else { return false }
            guard let fresh = Self.freshPosition(), NaviBridge.distM(origin.lat, origin.lng, fresh.lat, fresh.lng) <= 100 else {
                message = "位置已变化或定位过期，请重新使用常用行程"; return false
            }
            guard RoutePlanningGeneration.shared.finish(ticket), let route = routes.first,
                  WebMotorSession.shared.selectCandidate(route) else { message = "当前会话已变化，请重试"; return false }
            message = "路线已规划，请核对后显式开始导航"; return true
        } catch {
            guard requestIntent == intent, RoutePlanningGeneration.shared.accepts(ticket) else { return false }
            message = "常用行程规划失败：\(error.localizedDescription)"; return false
        }
    }
    static func freshPosition() -> (lat: Double, lng: Double)? {
        let service = LocationService.shared
        guard service.readiness(at: Date()).usable, let fix = service.location,
              NavigationRecoveryCheckpoint.acceptsFix(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude,
                accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp) else { return nil }
        return MapGeo.wgsToGcj(fix.coordinate.latitude, fix.coordinate.longitude)
    }
}

struct ViaDraftEditor: View {
    let limit: Int
    let onApply: ([JourneyPoint]) -> Void
    let onCancel: () -> Void
    @State private var draft: JourneyDraft<JourneyPoint>
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss
    init(points: [JourneyPoint], limit: Int, onApply: @escaping ([JourneyPoint]) -> Void, onCancel: @escaping () -> Void = {}) {
        self.limit = limit; self.onApply = onApply; self.onCancel = onCancel
        _draft = State(initialValue: JourneyDraft(points))
    }
    var body: some View {
        NavigationView {
            List {
                Text("按顺序经过；编辑只保存为草稿。点应用后统一规划一次。最多\(limit)个途经点。")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(draft.points.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(index + 1). \(draft.points[index].name)")
                        HStack {
                            Button("上移") { draft.move(index, by: -1) }.disabled(index == 0).accessibilityIdentifier("vias.up.\(index)")
                            Button("下移") { draft.move(index, by: 1) }.disabled(index + 1 == draft.points.count).accessibilityIdentifier("vias.down.\(index)")
                            Spacer()
                            Button("删除", role: .destructive) { draft.remove(index) }.accessibilityIdentifier("vias.delete.\(index)")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("添加途经点") { picking = true }.disabled(draft.points.count >= limit)
            }.navigationTitle("编辑途经点").accessibilityIdentifier("vias.editor")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { draft.cancel(); onCancel(); dismiss() }.accessibilityIdentifier("vias.cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("应用并规划") { onApply(draft.points); dismiss() }.accessibilityIdentifier("vias.apply") }
                }
        }.preferredColorScheme(.dark)
            .sheet(isPresented: $picking) {
                PlacePickerView(title: "选择途经点") { point in draft.append(.init(name: point.name, lat: point.lat, lng: point.lng), limit: limit) }
            }
    }
}

struct SaveJourneyButton: View {
    let mode: JourneyMode
    let destination: JourneyPoint
    let vias: [JourneyPoint]
    var avoidHighway = false
    @ObservedObject private var library = JourneyLibrary.shared
    @State private var naming = false
    @State private var name = ""
    @State private var savingJourney: SavedJourney?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("收藏整条行程") {
                name = destination.name
                savingJourney = SavedJourney(name: name, mode: mode, destination: destination, vias: vias, avoidHighway: avoidHighway)
                naming = true
            }
            if !library.message.isEmpty { Text(library.message).font(.caption2).foregroundColor(.orange) }
        }.sheet(isPresented: $naming) {
            JourneyNameSheet(title: "收藏行程", initialName: name) { value in
                guard var snapshot = savingJourney else { return false }
                snapshot.name = value
                return library.add(snapshot)
            }
        }
    }
}

struct JourneyNameSheet: View {
    let title: String
    let save: (String) -> Bool
    @State private var name: String
    @ObservedObject private var library = JourneyLibrary.shared
    @Environment(\.dismiss) private var dismiss
    init(title: String, initialName: String, save: @escaping (String) -> Bool) {
        self.title = title; self.save = save; _name = State(initialValue: initialName)
    }
    var body: some View {
        NavigationView {
            Form {
                TextField("行程名称（最多80字）", text: $name)
                Text(library.message).font(.caption).foregroundColor(.orange)
                Text("仅保存目的地、途经点顺序、出行方式和路线偏好；使用时从新的当前位置重新规划。")
                    .font(.caption).foregroundColor(.secondary)
            }.navigationTitle(title).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if save(name) { dismiss() } } }
            }
        }.preferredColorScheme(.dark)
    }
}

struct JourneyListView: View {
    let onPlanned: (SavedJourney) -> Void
    @ObservedObject private var library = JourneyLibrary.shared
    @State private var renaming: SavedJourney?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                if library.entries.isEmpty { Text("在路线方案下收藏整条行程，即可在这里使用。") }
                if !library.message.isEmpty { Text(library.message).font(.caption).foregroundColor(.orange) }
                ForEach(library.entries) { journey in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(journey.name).font(.headline)
                        Text("\(journey.mode.title) · \(journey.destination.name) · \(journey.vias.count)个途经点\(journey.avoidHighway ? " · 不走高速" : "")").font(.caption)
                        if !journey.vias.isEmpty { Text(journey.vias.map(\.name).joined(separator: " → ")).font(.caption).foregroundColor(.secondary) }
                        HStack {
                            Button("从当前位置规划") {
                                Task { @MainActor in if await library.plan(journey) { onPlanned(journey); dismiss() } }
                            }.disabled(library.busy)
                            Spacer()
                            Button("改名") { renaming = journey }.disabled(library.busy)
                            Button("删除", role: .destructive) { library.remove(journey.id) }.disabled(library.busy)
                        }.buttonStyle(.borderless)
                    }
                }
            }.navigationTitle("常用行程").accessibilityIdentifier("journeys.list").toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
        }.preferredColorScheme(.dark)
            .sheet(item: $renaming) { journey in JourneyNameSheet(title: "修改行程名称", initialName: journey.name) { library.rename(journey.id, $0) } }
            .onDisappear { library.cancelPlanning() }
    }
}
