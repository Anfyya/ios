import Foundation

// MARK: - Connectivity models

enum TargetRegion: String, Codable, Sendable {
    case global
    case domestic
}

struct ProbeTarget: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let urlString: String
    let region: TargetRegion

    var isForeign: Bool { region == .global }

    static let all: [ProbeTarget] = [
        .init(id: "google", name: "Google", host: "www.google.com", urlString: "https://www.google.com/generate_204", region: .global),
        .init(id: "gemini", name: "Gemini", host: "gemini.google.com", urlString: "https://gemini.google.com/", region: .global),
        .init(id: "openai", name: "OpenAI", host: "openai.com", urlString: "https://openai.com/", region: .global),
        .init(id: "chatgpt", name: "ChatGPT", host: "chatgpt.com", urlString: "https://chatgpt.com/", region: .global),
        .init(id: "claude-ai", name: "Claude.ai", host: "claude.ai", urlString: "https://claude.ai/", region: .global),
        .init(id: "claude-com", name: "Claude.com", host: "claude.com", urlString: "https://claude.com/", region: .global),
        .init(id: "grok", name: "Grok", host: "grok.com", urlString: "https://grok.com/", region: .global),
        .init(id: "xai", name: "xAI", host: "x.ai", urlString: "https://x.ai/", region: .global),
        .init(id: "baidu", name: "百度", host: "baidu.com", urlString: "https://www.baidu.com/", region: .domestic),
        .init(id: "bilibili", name: "哔哩哔哩", host: "bilibili.com", urlString: "https://www.bilibili.com/", region: .domestic),
        .init(id: "my78", name: "my78.cyou", host: "my78.cyou", urlString: "https://my78.cyou/", region: .domestic)
    ]
}

struct ProbeSample: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let attempt: Int
    let success: Bool
    let latencyMilliseconds: Double?
    let error: String?
    let createdAt: Date

    init(attempt: Int, success: Bool, latencyMilliseconds: Double?, error: String?) {
        self.id = UUID()
        self.attempt = attempt
        self.success = success
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
        self.createdAt = Date()
    }
}

enum ProbeGrade: String, Codable, Sendable {
    case testing
    case excellent
    case good
    case usable
    case poor
    case unreachable

    var title: String {
        switch self {
        case .testing: "检测中"
        case .excellent: "优秀"
        case .good: "良好"
        case .usable: "可用"
        case .poor: "不稳定"
        case .unreachable: "不可达"
        }
    }

    var symbol: String {
        switch self {
        case .testing: "wave.3.right"
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .usable: "circlebadge.fill"
        case .poor: "exclamationmark.triangle.fill"
        case .unreachable: "xmark.octagon.fill"
        }
    }
}

struct ConnectivityResult: Identifiable, Codable, Hashable, Sendable {
    var id: String { target.id }
    let target: ProbeTarget
    var samples: [ProbeSample]
    var httpReachable: Bool
    var httpStatusCode: Int?
    var httpLatencyMilliseconds: Double?
    var httpError: String?

    init(
        target: ProbeTarget,
        samples: [ProbeSample] = [],
        httpReachable: Bool = false,
        httpStatusCode: Int? = nil,
        httpLatencyMilliseconds: Double? = nil,
        httpError: String? = nil
    ) {
        self.target = target
        self.samples = samples
        self.httpReachable = httpReachable
        self.httpStatusCode = httpStatusCode
        self.httpLatencyMilliseconds = httpLatencyMilliseconds
        self.httpError = httpError
    }

    var successCount: Int { samples.filter(\.success).count }
    var attemptedCount: Int { samples.count }
    var isComplete: Bool { samples.count >= 5 && (httpReachable || httpError != nil || httpStatusCode != nil) }
    var reachability: Double { samples.isEmpty ? 0 : Double(successCount) / Double(samples.count) }
    var packetLoss: Double { samples.isEmpty ? 1 : 1 - reachability }

    var successfulLatencies: [Double] {
        samples.compactMap { $0.success ? $0.latencyMilliseconds : nil }
    }

    var averageLatency: Double? {
        guard !successfulLatencies.isEmpty else { return nil }
        return successfulLatencies.reduce(0, +) / Double(successfulLatencies.count)
    }

    var minimumLatency: Double? { successfulLatencies.min() }
    var maximumLatency: Double? { successfulLatencies.max() }

    var reachableAtAll: Bool {
        successCount > 0 || httpReachable
    }

    var grade: ProbeGrade {
        guard !samples.isEmpty else { return .testing }
        guard reachableAtAll else { return .unreachable }
        let latency = averageLatency ?? httpLatencyMilliseconds ?? 9_999
        if reachability == 1, latency < 150, httpReachable { return .excellent }
        if reachability >= 0.8, latency < 300, httpReachable { return .good }
        if reachability >= 0.6, latency < 800 { return .usable }
        return .poor
    }
}

struct ConnectivitySummary: Sendable {
    let results: [ConnectivityResult]

    var baiduResult: ConnectivityResult? {
        results.first { $0.target.id == "baidu" }
    }

    // 用户指定的基础门槛：百度达标 + 任意一个国外站点能通。
    var baiduPass: Bool {
        guard let result = baiduResult, let average = result.averageLatency else { return false }
        return result.reachability >= 0.8 && result.packetLoss <= 0.2 && average <= 500 && result.httpReachable
    }

    var reachableForeignTargets: [ConnectivityResult] {
        results.filter { $0.target.isForeign && $0.reachableAtAll }
    }

    var foreignPass: Bool { !reachableForeignTargets.isEmpty }
    var baselinePass: Bool { baiduPass && foreignPass }

    var overallReachability: Double {
        let attempted = results.reduce(0) { $0 + $1.attemptedCount }
        guard attempted > 0 else { return 0 }
        let successes = results.reduce(0) { $0 + $1.successCount }
        return Double(successes) / Double(attempted)
    }

    var overallAverageLatency: Double? {
        let values = results.compactMap(\.averageLatency)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - IP quality models

struct IPObservation: Identifiable, Codable, Hashable, Sendable {
    var id: String { source }
    let source: String
    var ok: Bool = true
    var error: String?
    var country: String?
    var countryCode: String?
    var region: String?
    var city: String?
    var asn: String?
    var asName: String?
    var isp: String?
    var org: String?
    var proxy: Bool?
    var vpn: Bool?
    var tor: Bool?
    var hosting: Bool?
    var mobile: Bool?
    var abuser: Bool?
    var spammer: Bool?
    var providerRisk: Int?
    var notes: [String] = []
}

struct IPQualityReport: Codable, Hashable, Sendable {
    let ip: String
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let asn: String?
    let asName: String?
    let isp: String?
    let org: String?
    let proxy: Bool
    let vpn: Bool
    let tor: Bool
    let hosting: Bool
    let mobile: Bool
    let abuser: Bool
    let spammer: Bool
    let mainlandGeo: Bool
    let mainlandASN: Bool
    let networkRiskScore: Int
    let networkRiskLevel: String
    let claudeRiskScore: Int
    let claudeVerdict: String
    let confidence: Int
    let reasons: [String]
    let successfulSources: [String]
    let failedSources: [String: String]
    let observations: [IPObservation]

    var locationText: String {
        [country, region, city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
    }
}

enum OverallGrade: String, Codable, Sendable {
    case excellent
    case good
    case caution
    case poor

    var title: String {
        switch self {
        case .excellent: "推荐使用"
        case .good: "基本可用"
        case .caution: "谨慎使用"
        case .poor: "不建议使用"
        }
    }

    var symbol: String {
        switch self {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .poor: "xmark.octagon.fill"
        }
    }
}

struct FinalConclusion: Codable, Hashable, Sendable {
    let grade: OverallGrade
    let title: String
    let connectivityText: String
    let ipQualityText: String
    let detail: String
}

struct TestRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let connectivityResults: [ConnectivityResult]
    let ipReport: IPQualityReport?
    let conclusion: FinalConclusion

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        connectivityResults: [ConnectivityResult],
        ipReport: IPQualityReport?,
        conclusion: FinalConclusion
    ) {
        self.id = id
        self.createdAt = createdAt
        self.connectivityResults = connectivityResults
        self.ipReport = ipReport
        self.conclusion = conclusion
    }

    var connectivitySummary: ConnectivitySummary {
        ConnectivitySummary(results: connectivityResults)
    }
}

enum TestPhase: String, Sendable {
    case idle
    case connectivity
    case ipDetection
    case ipQuality
    case finalizing
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: "准备检测"
        case .connectivity: "正在检测站点联通"
        case .ipDetection: "正在获取出口 IP"
        case .ipQuality: "正在检测 IP 质量"
        case .finalizing: "正在生成结论"
        case .completed: "检测完成"
        case .failed: "检测遇到问题"
        }
    }
}
