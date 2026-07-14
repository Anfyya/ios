import Foundation

enum DNSRegion: String, Codable, Sendable {
    case domestic
    case global
}

struct DNSProbeTarget: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String
    let region: DNSRegion

    static let all: [DNSProbeTarget] = [
        .init(id: "alidns", name: "阿里公共 DNS", address: "223.5.5.5", region: .domestic),
        .init(id: "dnspod", name: "DNSPod Public DNS", address: "119.29.29.29", region: .domestic),
        .init(id: "114dns", name: "114DNS", address: "114.114.114.114", region: .domestic),
        .init(id: "cloudflare", name: "Cloudflare DNS", address: "1.1.1.1", region: .global),
        .init(id: "google-dns", name: "Google Public DNS", address: "8.8.8.8", region: .global),
        .init(id: "quad9", name: "Quad9", address: "9.9.9.9", region: .global)
    ]
}

struct DNSProbeSample: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let attempt: Int
    let success: Bool
    let latencyMilliseconds: Double?
    let error: String?
    let createdAt: Date

    init(attempt: Int, success: Bool, latencyMilliseconds: Double?, error: String?) {
        id = UUID()
        self.attempt = attempt
        self.success = success
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
        createdAt = Date()
    }
}

struct DNSProbeResult: Identifiable, Codable, Hashable, Sendable {
    var id: String { target.id }
    let target: DNSProbeTarget
    var samples: [DNSProbeSample]

    init(target: DNSProbeTarget, samples: [DNSProbeSample] = []) {
        self.target = target
        self.samples = samples
    }

    var successCount: Int { samples.filter(\.success).count }
    var attemptedCount: Int { samples.count }
    var isComplete: Bool { attemptedCount >= 5 }
    var reachability: Double { samples.isEmpty ? 0 : Double(successCount) / Double(samples.count) }
    var packetLoss: Double { samples.isEmpty ? 1 : 1 - reachability }
    var reachableAtAll: Bool { successCount > 0 }

    var successfulLatencies: [Double] {
        samples.compactMap { $0.success ? $0.latencyMilliseconds : nil }
    }

    var averageLatency: Double? {
        guard !successfulLatencies.isEmpty else { return nil }
        return successfulLatencies.reduce(0, +) / Double(successfulLatencies.count)
    }

    var minimumLatency: Double? { successfulLatencies.min() }
    var maximumLatency: Double? { successfulLatencies.max() }

    var meetsDomesticThreshold: Bool {
        guard target.region == .domestic, isComplete, let averageLatency else { return false }
        return reachability >= 0.8 && packetLoss <= 0.2 && averageLatency <= 500
    }

    var grade: ProbeGrade {
        guard !samples.isEmpty else { return .testing }
        guard reachableAtAll else { return isComplete ? .unreachable : .testing }
        let latency = averageLatency ?? 9_999
        if reachability == 1, latency < 80 { return .excellent }
        if reachability >= 0.8, latency < 200 { return .good }
        if reachability >= 0.6, latency < 500 { return .usable }
        return .poor
    }
}

struct DNSConnectivitySummary: Sendable {
    let results: [DNSProbeResult]

    var qualifyingDomesticResults: [DNSProbeResult] {
        results.filter(\.meetsDomesticThreshold)
    }

    var reachableGlobalResults: [DNSProbeResult] {
        results.filter { $0.target.region == .global && $0.reachableAtAll }
    }

    var domesticPass: Bool { !qualifyingDomesticResults.isEmpty }
    var globalPass: Bool { !reachableGlobalResults.isEmpty }
    var baselinePass: Bool { domesticPass && globalPass }

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
