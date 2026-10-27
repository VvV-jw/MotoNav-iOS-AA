import SwiftUI
import CoreLocation

final class Favorites: ObservableObject {
    static let shared = Favorites()
    struct Place: Codable, Identifiable {
        var id = UUID(); var name: String; var address: String; var lat: Double; var lng: Double
        var searchPlace: SearchService.Place { .init(name: name, address: address, lat: lat, lng: lng) }
    }
    @Published private(set) var places: [Place] = []
    private init() {
        if let data = UserDefaults.standard.data(forKey: "favorite_places") { places = (try? JSONDecoder().decode([Place].self, from: data)) ?? [] }
    }
    func add(_ p: SearchService.Place) {
        guard !places.contains(where: { NaviBridge.distM($0.lat, $0.lng, p.lat, p.lng) < 50 }) else { return }
        places.insert(Place(name: p.name, address: p.address, lat: p.lat, lng: p.lng), at: 0); save()
    }
    func remove(_ p: Place) { places.removeAll { $0.id == p.id }; save() }
    private func save() { if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "favorite_places") } }
}

/// WGS84 only. The controller retains one accepted fix and a page of summaries;
/// all filesystem work, legacy conversion and complete GPX generation is off main.
final class RideRecorder: ObservableObject {
    static let shared = RideRecorder()
    typealias Fix = RideFix
    typealias Ride = RideSummary
    @Published private(set) var rides: [Ride] = []
    @Published private(set) var active: Ride?
    @Published private(set) var loading = false
    @Published private(set) var migrating = false
    @Published private(set) var retainedLegacy = 0
    @Published private(set) var legacyWarning = ""
    @Published private(set) var hasOlder = false
    @Published private(set) var hasNewer = false
    @Published private(set) var exportingID: UUID?
    @Published private(set) var deleting = Set<UUID>()
    @Published var error = ""
    private let store: RideStore
    private var sessionID: UUID?
    private var policy = RideRecordingPolicy()
    private var cursor: RideStore.Cursor?
    private var nextCursor: RideStore.Cursor?
    private var back: [RideStore.Cursor?] = []
    private var reloadPending = false
    private var historyRevision: UInt64 = 0
    private init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Rides", isDirectory: true)
        store = RideStore(root: root)
        store.observeFailures { [weak self] id, failure in
            guard let self = self else { return }
            self.error = failure.message
            if failure != .busy, let id = id, self.sessionID == id {
                self.active = nil; self.policy.noteGap()
            }
        }
        store.observeCatalog { [weak self] in self?.refreshHistory() }
        refreshHistory()
    }
    func start(_ mode: String) {
        finish()
        let ride = Ride(started: Date(), mode: String(mode.prefix(64)))
        sessionID = ride.id; active = ride; policy = RideRecordingPolicy(); error = ""
        store.begin(ride) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.sessionID == ride.id else { return }
                if case .failure(let failure) = result { self.active = nil; self.error = failure.message }
            }
        }
    }
    func fix(_ location: CLLocation) {
        guard let id = sessionID, var ride = active, ride.id == id else { return }
        let previous = policy.last
        let input = Fix(lat: location.coordinate.latitude, lng: location.coordinate.longitude,
            time: location.timestamp, speed: location.speed < 0 ? 0 : location.speed)
        guard let point = policy.accept(input, accuracy: location.horizontalAccuracy, now: Date()) else { return }
        guard store.append(point, to: id) else { policy.noteGap(); return }
        ride.pointCount += 1
        if point.startsSegment || previous == nil { ride.segments += 1 }
        else if let previous = previous { ride.meters += Fix.distance(previous, point) }
        active = ride
    }
    func finish() {
        guard let id = sessionID else { return }
        sessionID = nil; active = nil; policy = RideRecordingPolicy()
        store.finish(id, at: Date()) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let failure) = result { self?.error = failure.message }
                self?.refreshHistory()
            }
        }
    }
    func remove(_ ride: Ride) {
        guard !deleting.contains(ride.id) else { return }
        deleting.insert(ride.id)
        store.remove(ride.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.deleting.remove(ride.id)
                switch result {
                case .success: self.rides.removeAll { $0.id == ride.id }; self.refreshHistory()
                case .failure(let failure): self.error = failure.message
                }
            }
        }
    }
    func export(_ ride: Ride, completion: @escaping (Result<URL, RideStoreFailure>) -> Void) {
        guard exportingID == nil else { return }
        exportingID = ride.id
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("MotoNav-GPX", isDirectory: true)
        store.export(ride.id, to: exports) { [weak self] result in
            DispatchQueue.main.async {
                self?.exportingID = nil
                if case .failure(let failure) = result { self?.error = failure.message }
                completion(result)
            }
        }
    }
    func refreshHistory() {
        guard !loading else { reloadPending = true; return }
        loading = true; historyRevision &+= 1; let expected = historyRevision
        store.page(before: cursor) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.historyRevision == expected else { return }
                self.loading = false
                switch result {
                case .success(let page):
                    self.rides = page.rides; self.nextCursor = page.next
                    self.hasOlder = page.next != nil; self.hasNewer = !self.back.isEmpty
                    self.migrating = page.isMigrating
                    self.retainedLegacy = page.retainedLegacy
                    self.legacyWarning = page.legacyFailures.map(\.message).joined(separator: "\n")
                case .failure(let failure): self.error = failure.message
                }
                if self.reloadPending { self.reloadPending = false; self.refreshHistory() }
            }
        }
    }
    func older() {
        guard !loading, let next = nextCursor else { return }
        back.append(cursor); if back.count > 64 { back.removeFirst() }
        cursor = next; refreshHistory()
    }
    func newer() {
        guard !loading, !back.isEmpty else { return }
        cursor = back.removeLast(); refreshHistory()
    }
    func latest() {
        guard !loading else { return }
        back.removeAll(); cursor = nil; refreshHistory()
    }
}

struct RideHistoryView: View {
    @ObservedObject var recorder = RideRecorder.shared
    @State private var exportURL: URL?
    var body: some View {
        List {
            if let ride = recorder.active {
                Text("记录中 · \(ride.mode) · \(Int(ride.meters)) 米 · 已接收 \(ride.pointCount) 点")
                Text("轨迹在后台增量保存；定位中断处会分段，结束后可导出完整 GPX。")
                    .font(.caption).foregroundColor(AppPalette.secondary)
            }
            if recorder.loading { ProgressView("正在读取轨迹目录…") }
            if recorder.migrating { Text("正在后台整理旧版轨迹，原文件保留。可继续使用导航。") .font(.caption) }
            if recorder.retainedLegacy > 0 {
                Text("有 \(recorder.retainedLegacy) 份旧版轨迹暂未整理，原文件仍在本机。") .foregroundColor(AppPalette.warning)
                Text(recorder.legacyWarning).font(.caption).foregroundColor(AppPalette.secondary)
            }
            if !recorder.error.isEmpty { Text(recorder.error).foregroundColor(AppPalette.error) }
            ForEach(recorder.rides) { ride in
                VStack(alignment: .leading, spacing: 5) {
                    Text(ride.started, style: .date)
                    Text("\(ride.mode) · \(NaviBridge.distText(Int(ride.meters))) · \(ride.pointCount) 个轨迹点 · \(ride.segments) 段")
                    if ride.recovered { Text("上次中断前已保存的记录").font(.caption).foregroundColor(AppPalette.secondary) }
                    if ride.readProblem { Text("记录暂时无法完整读取，原文件保留。") .font(.caption).foregroundColor(AppPalette.warning) }
                    HStack {
                        Button(recorder.exportingID == ride.id ? "正在导出…" : "导出 GPX") {
                            recorder.export(ride) { result in if case .success(let url) = result { exportURL = url } }
                        }.disabled(recorder.exportingID != nil || recorder.deleting.contains(ride.id) || ride.readProblem)
                        Spacer()
                        Button(recorder.deleting.contains(ride.id) ? "正在删除…" : "删除", role: .destructive) { recorder.remove(ride) }
                            .disabled(recorder.deleting.contains(ride.id) || recorder.exportingID == ride.id)
                    }.buttonStyle(AppListActionStyle())
                }.listRowBackground(AppPalette.surface)
            }
            if recorder.hasOlder || recorder.hasNewer {
                HStack {
                    Button("上一页") { recorder.newer() }.disabled(!recorder.hasNewer || recorder.loading)
                    Spacer()
                    Button("下一页") { recorder.older() }.disabled(!recorder.hasOlder || recorder.loading)
                }
                Button("回到最新记录") { recorder.latest() }.disabled(recorder.loading)
            }
            if recorder.rides.isEmpty && recorder.active == nil && !recorder.loading && !recorder.migrating {
                Text("真实导航或巡航开始时自动记录；模拟导航不记录。")
            }
        }.appListSurface().navigationTitle("骑行轨迹")
        .appScreen()
        .onAppear { recorder.refreshHistory() }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let url = exportURL { ExportSheet(url: url) }
        }
    }
}
struct ExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
