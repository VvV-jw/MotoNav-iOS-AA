import Foundation

protocol MapStorageFailure: Error { var isStorageBlocked: Bool { get } }

/// Provider boundaries report structured failures; messages and request URLs are never parsed.
enum MapServiceError: Error, LocalizedError {
    case http(status: Int, retryAfter: TimeInterval?)
    case configuration(String)
    case timeout
    case invalidData(String)
    case memoryPressure

    var errorDescription: String? {
        switch self {
        case .http(let status, _): return "地图服务返回 HTTP \(status)"
        case .configuration: return "地图服务配置或授权不可用，请检查 Key、平台及权限"
        case .timeout: return "地图服务响应超时，已有地图仍可使用"
        case .invalidData: return "地图数据无效或超过大小限制，已有地图仍可使用"
        case .memoryPressure: return "系统报告内存紧张，已暂停地图预取"
        }
    }
}

enum MapFailurePolicy {
    enum Category: String { case network, timeout, rateLimited, configuration, invalidData, memory, storage, cancelled, unknown }
    enum Action: Equatable {
        case retryBlock
        case cooldown(TimeInterval)
        case pauseConfiguration, pauseMemory, pauseStorage, cancel
    }
    struct Decision {
        let category: Category
        let action: Action
        /// Safe UI/log message; NSError descriptions can include URLs containing credentials.
        let message: String
    }
    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(text), seconds.isFinite {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss zzz", "EEEE',' dd-MMM-yy HH':'mm':'ss zzz", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
    static func classify(_ error: Error, depth: Int = 0) -> Decision {
        guard depth < 10 else { return unknown }
        if let service = error as? MapServiceError {
            switch service {
            case .http(let status, let retryAfter) where status == 429 || status == 503:
                let seconds = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 60
                return Decision(category: .rateLimited, action: .cooldown(max(1, seconds)), message: "地图服务繁忙或请求受限，按服务端要求等待后再继续")
            case .http(let status, _) where status == 401 || status == 403:
                return Decision(category: .configuration, action: .pauseConfiguration, message: "地图服务拒绝授权，请检查 Key、平台及服务权限后继续")
            case .configuration:
                return Decision(category: .configuration, action: .pauseConfiguration, message: service.localizedDescription)
            case .timeout:
                return Decision(category: .timeout, action: .retryBlock, message: service.localizedDescription)
            case .invalidData:
                return Decision(category: .invalidData, action: .retryBlock, message: service.localizedDescription)
            case .memoryPressure:
                return Decision(category: .memory, action: .pauseMemory, message: service.localizedDescription)
            case .http(let status, _):
                return Decision(category: .unknown, action: .retryBlock, message: "地图服务暂时失败（HTTP \(status)），稍后重试")
            }
        }
        if let storage = error as? MapStorageFailure, storage.isStorageBlocked {
            return Decision(category: .storage, action: .pauseStorage, message: "地图缓存或手机存储空间不足，清理后继续")
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            switch value.code {
            case NSURLErrorCancelled:
                return Decision(category: .cancelled, action: .cancel, message: "地图任务已取消")
            case NSURLErrorTimedOut:
                return Decision(category: .timeout, action: .retryBlock, message: "地图请求超时，稍后重试")
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive, NSURLErrorDataNotAllowed:
                return Decision(category: .network, action: .retryBlock, message: "地图网络暂不可用，已有地图仍可使用")
            default: break
            }
        }
        if (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError) ||
           (value.domain == NSPOSIXErrorDomain && value.code == 28) {
            return Decision(category: .storage, action: .pauseStorage, message: "手机存储空间不足，清理后继续")
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
            let nested = classify(underlying, depth: depth + 1)
            if nested.category != .unknown { return nested }
        }
        return unknown
    }
    private static var unknown: Decision {
        Decision(category: .unknown, action: .retryBlock, message: "地图处理暂未完成，保留已有地图并稍后重试")
    }

    /// Only the SDK's declared search error domain opts into these documented search codes.
    /// MAMapView's arbitrary NSError numbers must never be guessed to mean authorization errors.
    /// https://lbs.amap.com/api/ios-sdk/guide/map-tool/errorcode/ (search callbacks, v3.3+)
    static func amapSearchFailure(_ error: NSError, expectedDomain: String) -> MapServiceError? {
        guard !expectedDomain.isEmpty, error.domain == expectedDomain else { return nil }
        switch error.code {
        case 1001, 1002, 1003, 1008, 1009, 1012, 1013: return .configuration("高德搜索 SDK 授权或平台配置不可用")
        case 1102, 1103, 1802: return .timeout
        default: return nil
        }
    }
}
