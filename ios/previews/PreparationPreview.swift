import SwiftUI

// Shared product colors only; the real coverage view is compiled unchanged beside this host.
enum ContentView {
    static let bg = Color(red: 0.055, green: 0.04, blue: 0.08)
    static let card = Color(red: 0.10, green: 0.08, blue: 0.14)
    static let sub = Color(red: 0.62, green: 0.58, blue: 0.67)
    static let pink = Color(red: 1.0, green: 0.31, blue: 0.71)
    static let cyan = Color(red: 0.26, green: 0.88, blue: 0.94)
}

private enum PreviewInputs {
    static func result(_ state: String) -> RouteCoverage.Result {
        if state == "scanning" { return RouteCoverage.scanning(totalMeters: 12_000) }
        let last = state == "gap" ? 3_000 : 12_000
        let centers = stride(from: 0, through: last, by: 600).flatMap { [Double($0), 0.0] }
        return RouteCoverage.evaluate(routeXY: [0, 0, 12_000, 0], readyCentersXY: centers,
            half: 1200, progressMeters: 0, inspectedStartMeters: 0,
            inspectedEndMeters: state == "unknown" ? 5_000 : 12_000)
    }
}

private struct PreviewScreen: View {
    let scene = CommandLine.arguments.dropFirst().first ?? "overview"
    private func card(_ state: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.caption).foregroundColor(ContentView.sub)
            RouteCoverageSummaryView(result: PreviewInputs.result(state))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(ContentView.card).cornerRadius(14)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MotoNav").font(.system(size: 34, weight: .heavy, design: .rounded)).italic().foregroundColor(ContentView.pink)
                Text("出发准备 · iOS 原生组件预览").font(.headline)
                Text("模拟器截图 · 12 公里测试路线").font(.caption).foregroundColor(ContentView.cyan)
                if scene == "overview" {
                    card("scanning", "缓存核对中")
                    card("gap", "已核对范围存在缺口")
                    card("unknown", "仅核对前方 5 公里")
                    card("ready", "沿线地图连续可用")
                } else {
                    card(scene, "沿线地图覆盖")
                    VStack(alignment: .leading, spacing: 12) {
                        Text("检查结果仅作出发前提示").font(.headline)
                        Text("不新增确认步骤，不阻止开始导航。")
                        Text("当前地图和导航数据保持优先。")
                    }.font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ContentView.card).cornerRadius(14)
                }
                Text("截图使用真实覆盖计算与正式组件；输入为合成测试路线。未连接手机或圆屏，不表示真机地图、蓝牙或帧率结果。")
                    .font(.caption).foregroundColor(ContentView.sub)
            }.padding(20)
        }.foregroundColor(.white).background(ContentView.bg.ignoresSafeArea()).preferredColorScheme(.dark)
    }
}

@main struct PreparationPreviewApp: App {
    var body: some Scene { WindowGroup { PreviewScreen() } }
}
