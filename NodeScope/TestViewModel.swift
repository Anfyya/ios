import Combine
import Foundation

@MainActor
final class TestViewModel: ObservableObject {
    @Published private(set) var phase: TestPhase = .idle
    @Published private(set) var dnsByID: [String: DNSProbeResult] = [:]
    @Published private(set) var connectivityByID: [String: ConnectivityResult] = [:]
    @Published private(set) var currentIP: String?
    @Published private(set) var sourceObservations: [IPObservation] = []
    @Published private(set) var ipReport: IPQualityReport?
    @Published private(set) var finalRecord: TestRecord?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false

    private let dnsService = DNSPingService()
    private let networkService = NetworkProbeService()
    private let ipService = IPQualityService()
    private var task: Task<Void, Never>?

    var orderedDNS: [DNSProbeResult] {
        DNSProbeTarget.all.compactMap { dnsByID[$0.id] }
    }

    var orderedConnectivity: [ConnectivityResult] {
        ProbeTarget.all.compactMap { connectivityByID[$0.id] }
    }

    var completedDNSAttempts: Int {
        dnsByID.values.reduce(0) { $0 + $1.samples.count }
    }

    var completedProbeAttempts: Int {
        connectivityByID.values.reduce(0) { $0 + $1.samples.count }
    }

    var totalProgress: Double {
        let dnsWork = Double(completedDNSAttempts) / Double(DNSProbeTarget.all.count * 5)
        let probeWork = Double(completedProbeAttempts) / Double(ProbeTarget.all.count * 5)
        let httpWork = Double(connectivityByID.values.filter { $0.httpReachable || $0.httpError != nil || $0.httpStatusCode != nil }.count) / Double(ProbeTarget.all.count)
        let sourceWork = Double(sourceObservations.count) / 6.0
        let ipDetectionWork = currentIP == nil ? 0.0 : 1.0
        return min(1, dnsWork * 0.25 + probeWork * 0.25 + httpWork * 0.1 + ipDetectionWork * 0.05 + sourceWork * 0.3 + (phase == .completed ? 0.05 : 0))
    }

    func start(historyStore: HistoryStore) {
        guard !isRunning else { return }
        task?.cancel()
        reset()
        isRunning = true
        phase = .connectivity

        for target in DNSProbeTarget.all {
            dnsByID[target.id] = DNSProbeResult(target: target)
        }
        for target in ProbeTarget.all {
            connectivityByID[target.id] = ConnectivityResult(target: target)
        }

        task = Task { [weak self] in
            guard let self else { return }

            async let dnsTask = dnsService.runAll { result in
                Task { @MainActor [weak self] in
                    self?.dnsByID[result.target.id] = result
                }
            }
            async let serviceTask = networkService.runAll { result in
                Task { @MainActor [weak self] in
                    self?.connectivityByID[result.target.id] = result
                }
            }

            let (dnsResults, connectivity) = await (dnsTask, serviceTask)
            guard !Task.isCancelled else { return }
            dnsResults.forEach { dnsByID[$0.target.id] = $0 }
            connectivity.forEach { connectivityByID[$0.target.id] = $0 }

            phase = .ipDetection
            do {
                let report = try await ipService.inspect(
                    ipUpdate: { ip in
                        Task { @MainActor [weak self] in
                            self?.currentIP = ip
                            self?.phase = .ipQuality
                        }
                    },
                    sourceUpdate: { observation in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let index = self.sourceObservations.firstIndex(where: { $0.source == observation.source }) {
                                self.sourceObservations[index] = observation
                            } else {
                                self.sourceObservations.append(observation)
                            }
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                ipReport = report
            } catch {
                errorMessage = "IP 质量检测失败：\(error.localizedDescription)"
            }

            phase = .finalizing
            let dns = orderedDNS
            let services = orderedConnectivity
            let conclusion = ConclusionEngine.make(
                dns: dns,
                connectivity: services,
                ipReport: ipReport,
                ipError: errorMessage
            )
            let record = TestRecord(
                dnsResults: dns,
                connectivityResults: services,
                ipReport: ipReport,
                conclusion: conclusion
            )
            historyStore.add(record)
            finalRecord = record
            phase = .completed
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        phase = .idle
    }

    private func reset() {
        phase = .idle
        dnsByID = [:]
        connectivityByID = [:]
        currentIP = nil
        sourceObservations = []
        ipReport = nil
        finalRecord = nil
        errorMessage = nil
    }
}

enum ConclusionEngine {
    static func make(
        dns: [DNSProbeResult],
        connectivity: [ConnectivityResult],
        ipReport: IPQualityReport?,
        ipError: String?
    ) -> FinalConclusion {
        let dnsSummary = DNSConnectivitySummary(results: dns)
        let serviceSummary = ConnectivitySummary(results: connectivity)

        let connectivityText: String
        if dnsSummary.baselinePass {
            let domesticNames = dnsSummary.qualifyingDomesticResults.map { $0.target.name }.joined(separator: "、")
            let globalNames = dnsSummary.reachableGlobalResults.map { $0.target.name }.joined(separator: "、")
            connectivityText = "基础网络合格：国内 DNS 达标（\(domesticNames)），国外 DNS 可达（\(globalNames)）。"
        } else if !dnsSummary.domesticPass && !dnsSummary.globalPass {
            connectivityText = "基础网络不合格：没有国内 DNS 达到门槛，国外 DNS 也全部不可达。"
        } else if !dnsSummary.domesticPass {
            connectivityText = "基础网络不合格：国外 DNS 可达，但没有国内 DNS 达到 80% 成功率、20% 以下丢包和 500ms 以下平均延迟。"
        } else {
            connectivityText = "基础网络不合格：国内 DNS 达标，但国外 DNS 全部不可达。"
        }

        let reachableServices = serviceSummary.reachableTargets.map { $0.target.name }
        let serviceText = reachableServices.isEmpty
            ? "网站服务均未确认可访问"
            : "可访问服务：\(reachableServices.joined(separator: "、"))"

        guard let ipReport else {
            return FinalConclusion(
                grade: dnsSummary.baselinePass ? .caution : .poor,
                title: dnsSummary.baselinePass ? "网络可用，但 IP 质量未知" : "基础网络不合格",
                connectivityText: connectivityText,
                ipQualityText: ipError ?? "IP 质量数据不足，不能判断出口是否干净。",
                detail: "\(serviceText)。DNS、网站服务和 IP 信誉均已分开检测；即使基础网络不合格，也不会提前停止。"
            )
        }

        let ipQualityText = "出口 IP \(ipReport.ip)，网络风险 \(ipReport.networkRiskScore)/100（\(ipReport.networkRiskLevel)），Claude 风险 \(ipReport.claudeRiskScore)/100。\(ipReport.claudeVerdict)"

        let grade: OverallGrade
        if !dnsSummary.baselinePass || ipReport.claudeRiskScore >= 80 || ipReport.networkRiskScore >= 80 {
            grade = .poor
        } else if ipReport.claudeRiskScore >= 35 || ipReport.networkRiskScore >= 35 {
            grade = .caution
        } else if ipReport.claudeRiskScore >= 15 || ipReport.networkRiskScore >= 15 {
            grade = .good
        } else {
            grade = .excellent
        }

        let title: String
        switch grade {
        case .excellent: title = "节点质量优秀"
        case .good: title = "节点基本可用"
        case .caution: title = "节点存在明显风险"
        case .poor: title = dnsSummary.baselinePass ? "IP 风险过高" : "基础网络不合格"
        }

        return FinalConclusion(
            grade: grade,
            title: title,
            connectivityText: connectivityText,
            ipQualityText: ipQualityText,
            detail: "\(serviceText)。DNS ICMP 结果只负责基础网络质量，网站请求只负责具体服务可用性，IP 数据源只负责出口信誉。"
        )
    }
}
