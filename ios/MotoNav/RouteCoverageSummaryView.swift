import SwiftUI

/// Read-only departure information. This view performs no disk, geometry, network or navigation work.
struct RouteCoverageSummaryView: View {
    let result: RouteCoverage.Result?
    var fromCurrentPosition = false
    private let muted = Color(red: 0.59, green: 0.65, blue: 0.70)
    private var accent: Color { result?.state == .ready ? .green : (result?.state == .gap ? .orange : .cyan) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("沿线路网").foregroundColor(muted)
                Spacer(minLength: 8)
                Text(result?.title ?? "选择路线后核对").foregroundColor(accent).multilineTextAlignment(.trailing)
            }.font(.caption)
            if let result = result {
                if result.state == .scanning {
                    Text("缓存检查完成后显示连续可用距离；不影响开始导航")
                        .font(.caption2).foregroundColor(muted)
                } else {
                    Text("从\(fromCurrentPosition ? "沿线第 " + String(format: "%.1f", result.progressMeters / 1000) + " 公里处" : "路线起点")连续可用 \(String(format: "%.1f", result.contiguousMetersAhead / 1000)) 公里")
                        .font(.caption).foregroundColor(.white)
                    if result.state == .gap {
                        Text("首个待准备位置：路线第 \(String(format: "%.1f", result.firstGapMeters / 1000)) 公里")
                            .font(.caption2).foregroundColor(.orange)
                    } else if result.state == .unknown {
                        Text("仅核对至路线第 \(String(format: "%.1f", result.inspectedEndMeters / 1000)) 公里；范围外尚未核对")
                            .font(.caption2).foregroundColor(muted)
                    }
                    Text("按完整圆屏视野核对本机可用地图；不代表圆屏已收到或道路数据实时最新")
                        .font(.caption2).foregroundColor(muted)
                }
            }
        }.padding(.vertical, 3)
    }
}
