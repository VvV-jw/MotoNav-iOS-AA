import SwiftUI

/// Visible before departure; reading this card never starts network requests or navigation.
struct DepartureReadinessView: View {
    @ObservedObject private var ble = BleLink.shared
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var map = MapFeeder.shared
    @ObservedObject private var settings = Settings.shared
    let configureKey: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        CardView {
            Text("出发准备").foregroundColor(.white).bold()
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let fix = location.readiness(at: context.date)
                VStack(alignment: .leading, spacing: 10) {
                    row("蓝牙", title: ble.isReady ? "圆屏已连接" : "等待连接圆屏",
                        detail: ble.isReady ? "导航数据可以发送" : ble.status,
                        color: ble.isReady ? .green : .orange)
                    row("定位", title: fix.title, detail: fix.detail,
                        color: fix.usable ? .green : .orange)
                    if !location.locationError.isEmpty && !fix.usable {
                        Text(location.locationError).font(.caption2).foregroundColor(.orange)
                    }
                    if location.authorization == .denied || location.authorization == .restricted {
                        Button("打开定位设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }.font(.caption).foregroundColor(ContentView.cyan)
                    }
                    if settings.mapOn {
                        let needsFix = !fix.usable && map.readiness.coverage == .covered
                        row("当前地图", title: needsFix && map.readiness.phase == .confirmed
                            ? "覆盖上次位置，等待定位核对" : map.readiness.title,
                            detail: needsFix ? "定位恢复后重新核对地图覆盖范围" : map.readiness.detail,
                            color: needsFix ? .orange : mapColor)
                    }
                }
            }
            row("地图 Key", title: settings.keysMissing ? "尚未填写" : "已填写",
                detail: settings.keysMissing ? "搜索和路线规划需要高德 iOS Key" : "服务授权以搜索和规划结果为准",
                color: settings.keysMissing ? .orange : ContentView.sub)
            if settings.keysMissing {
                Button("填写地图 Key", action: configureKey).font(.caption).foregroundColor(ContentView.cyan)
            }
            if settings.mapOn {
                if settings.theme != 11 {
                    if map.offlineProgress.hasPlan {
                        RouteCoverageSummaryView(result: map.routeCoverage, fromCurrentPosition: map.routeCoverageFromPosition)
                    }
                    row("沿线地图", title: map.offlineProgress.title, detail: map.offlineProgress.detail,
                        color: map.offlineProgress.isComplete ? .green : ContentView.sub)
                    if map.offlineProgress.total > 0 {
                        Text(map.offlineProgress.rangeKm == 0 ? "准备范围：全程" : "准备范围：前方 \(map.offlineProgress.rangeKm) 公里（随行进更新）")
                            .font(.caption2).foregroundColor(ContentView.sub)
                        ProgressView(value: map.offlineProgress.fraction).tint(ContentView.cyan)
                        Text("可用底图 \(map.offlineProgress.ready)/\(map.offlineProgress.total) · 细节完成 \(map.offlineProgress.detailedReady)/\(map.offlineProgress.total)")
                            .font(.caption2).foregroundColor(ContentView.sub)
                        Text("有效期内底图：\(map.offlineProgress.freshReady)/\(map.offlineProgress.total)")
                            .font(.caption2).foregroundColor(map.offlineProgress.isFreshComplete ? ContentView.sub : .orange)
                        if map.offlineProgress.failedCount > 0 {
                            Text("\(map.offlineProgress.failedCount) 块等待重试，其余路段继续准备")
                                .font(.caption2).foregroundColor(.orange)
                        }
                    }
                    if !map.offlineProgress.isComplete {
                        Text("保持 App 前台准备沿线地图；未完成的路段仍需在线更新。")
                            .font(.caption2).foregroundColor(ContentView.sub)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let hint = map.offlineProgress.waitHint(at: context.date) {
                            Text(hint).font(.caption2).foregroundColor(ContentView.cyan)
                        }
                    }
                }
            } else {
                Text("小地图已关闭，仍可使用导航指示。")
                    .font(.caption).foregroundColor(ContentView.sub)
            }
        }
    }

    private var mapColor: Color {
        switch map.readiness.severity {
        case .good: return .green
        case .attention: return .orange
        case .progress: return ContentView.cyan
        case .neutral: return ContentView.sub
        }
    }

    private func row(_ label: String, title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundColor(ContentView.sub)
                Spacer(minLength: 8)
                Text(title).foregroundColor(color).multilineTextAlignment(.trailing)
            }.font(.caption)
            if !detail.isEmpty { Text(detail).font(.caption2).foregroundColor(ContentView.sub) }
        }
    }
}

struct MapCacheManagementView: View {
    @ObservedObject private var map = MapFeeder.shared
    var body: some View {
        CardView {
            Text("离线地图维护").foregroundColor(.white).bold()
            Text(map.cacheInfo).font(.caption).foregroundColor(ContentView.sub)
            Picker("提前准备范围", selection: Binding(get: { map.preparationRangeKm }, set: { map.setPreparationRangeKm($0) })) {
                Text("全程").tag(0)
                Text("前方 5 公里").tag(5)
                Text("前方 20 公里").tag(20)
                Text("前方 50 公里").tag(50)
            }.pickerStyle(.menu).foregroundColor(ContentView.cyan)
            Text("有限范围随行进自动向前延伸，并保留约 1.2 公里后方地图；离线长途可选择全程。地图精度保持不变。")
                .font(.caption2).foregroundColor(ContentView.sub)
            Toggle("仅不计费 Wi-Fi 预下载沿线地图", isOn: Binding(get: { map.prefetchWiFiOnly }, set: { map.setPrefetchWiFiOnly($0) }))
                .font(.caption).foregroundColor(.white).tint(ContentView.cyan)
            Toggle("仅充电时预下载沿线地图", isOn: Binding(get: { map.prefetchChargingOnly }, set: { map.setPrefetchChargingOnly($0) }))
                .font(.caption).foregroundColor(.white).tint(ContentView.cyan)
            Text("默认不限制。仅影响沿线预下载；当前屏地图、导航指示和蓝牙照常工作，已有缓存仍可使用。")
                .font(.caption2).foregroundColor(ContentView.sub)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let hint = map.offlineProgress.waitHint(at: context.date) {
                    Text(hint).font(.caption2).foregroundColor(ContentView.cyan)
                }
            }
            Text("总预算固定分为成品包 512 MB 和 GTA 原始瓦片 256 MB；清理保留当前范围成品包及正在使用的瓦片。")
                .font(.caption2).foregroundColor(ContentView.sub)
            Text("沿线地图默认 7 天更新检查；更新失败保留旧图。")
                .font(.caption2).foregroundColor(ContentView.sub)
            if let date = map.offlineProgress.oldestGeneratedAt {
                if date.timeIntervalSince1970 > 0 {
                    Text("沿线缓存最早生成：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundColor(ContentView.sub)
                } else { Text("包含较早版本缓存，正在检查更新").font(.caption2).foregroundColor(.orange) }
            }
            Button("更新沿线地图") { map.updatePreparedRoute() }
                .foregroundColor(ContentView.cyan).disabled(!map.offlineProgress.hasPlan || map.cacheBusy)
            Button("重试失败路段（\(map.offlineProgress.failedCount)）") { map.retryFailedMapSections() }
                .foregroundColor(ContentView.cyan)
                .disabled(map.offlineProgress.failedCount == 0 || map.cacheBusy || map.memoryPaused || map.configurationPaused ||
                    [.storageBlocked, .memoryBlocked, .configurationBlocked, .rateLimited].contains(map.offlineProgress.phase))
            Button(map.cacheBusy ? "正在处理缓存…" : "清理准备范围外缓存") { map.clearUnusedMaps() }
                .foregroundColor(ContentView.cyan).disabled(map.cacheBusy)
            Button("刷新缓存统计") { map.refreshCacheInfo() }
                .font(.caption).foregroundColor(ContentView.sub).disabled(map.cacheBusy)
            if map.offlineProgress.phase == .storageBlocked {
                Button("已清理空间，继续准备") { map.resumeMapPreparation() }
                    .foregroundColor(ContentView.pink)
            }
            if map.memoryPaused || map.offlineProgress.phase == .memoryBlocked {
                Button("释放内存后，继续准备") { map.resumeMapPreparation() }.foregroundColor(ContentView.pink)
            }
            if map.configurationPaused || map.offlineProgress.phase == .configurationBlocked {
                Button("修正配置后，继续准备") { map.resumeMapPreparation() }.foregroundColor(ContentView.pink)
            }
            if !map.cacheMessage.isEmpty { Text(map.cacheMessage).font(.caption).foregroundColor(ContentView.sub) }
        }.onAppear { map.refreshCacheInfo() }
    }
}

struct PerformanceRecordingView: View {
    @ObservedObject private var ble = BleLink.shared
    @State private var recording = MapPipelineTrace.isEnabled
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var sharing = false
    @State private var error = ""

    var body: some View {
        CardView {
            Text("性能记录").foregroundColor(.white).bold()
            Toggle("记录本次运行", isOn: $recording)
                .foregroundColor(.white).tint(ContentView.pink)
                .onChange(of: recording) { enabled in
                    MapPipelineTrace.setEnabled(enabled)
                    exportURL = nil; error = ""
                }
            Text("开启后复现一次卡顿或地图空白，再导出记录。只保留最近的运行片段，不保存 Key、地图图片和位置坐标。")
                .font(.caption).foregroundColor(ContentView.sub)
            TimelineView(.periodic(from: .now, by: 2)) { context in
                if ble.isReady && context.date.timeIntervalSince(ble.statAt) < 10 && !ble.screenFps.isEmpty {
                    Text("圆屏最近回报：\(ble.screenFps) 帧/秒").font(.caption).foregroundColor(ContentView.cyan)
                } else {
                    Text("等待圆屏回报实测帧率").font(.caption).foregroundColor(ContentView.sub)
                }
            }
            Button(exporting ? "正在整理记录…" : "导出性能记录", action: export)
                .foregroundColor(ContentView.cyan).disabled(exporting)
            if let url = exportURL {
                Button { sharing = true } label: { Label("分享诊断文件", systemImage: "square.and.arrow.up") }
                    .font(.subheadline).foregroundColor(ContentView.pink)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundColor(.orange) }
        }
        .sheet(isPresented: $sharing) { if let url = exportURL { ExportSheet(url: url) } }
    }

    private func export() {
        exporting = true; error = ""; exportURL = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try MapPipelineTrace.export(appVersion: APP_VERSION) }
            DispatchQueue.main.async {
                exporting = false
                switch result {
                case .success(let url): exportURL = url
                case .failure: error = "记录导出失败，请稍后重试"
                }
            }
        }
    }
}
