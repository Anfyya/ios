import Combine
import Foundation

@MainActor
final class TestViewModel: ObservableObject {
    @Published private(set) var phase: TestPhase = .idle
    @Published private(set) var connectivityByID: [String: ConnectivityResult] = [:]
    @Published private(set) var currentIP: String?
    @Published private(set) var sourceObservations: [IPObservation] = []
    @Published private(set) var ipReport: IPQualityReport?
    @Published private(set) var finalRecord: TestRecord?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false

    private let networkService = NetworkProbeService()
    private let ipService = IPQualityService()
    private var task: Task<Void, Never>?

    var orderedConnectivity: [ConnectivityResult] {
        ProbeTarget.all.compactMap { connectivityByID[$0.id] }
    }

    var completedProbeAttempts: Int {
        connectivityByID.values.reduce(0) { $0 + $1.samples.count }
    }

    var totalProgress: Double {
        let probeWork = Double(completedProbeAttempts) / Double(ProbeTarget.all.count * 5)
        let httpWork = Double(connectivityByID.values.filter { $0.httpReachable || $0.httpError != nil || $0.httpStatusCode != nil }.count) / Double(ProbeTarget.all.count)
        let sourceWork = Double(sourceObservations.count) / 6.0
        let ipDetectionWork = currentIP == nil ? 0.0 : 1.0
        return min(1, probeWork * 0.55 + httpWork * 0.1 + ipDetectionWork * 0.05 + sourceWork * 0.25 + (phase == .completed ? 0.05 : 0))
    }

    func start(historyStore: HistoryStore) {
        guard !isRunning else { return }
        task?.cancel()
        reset()
        isRunning = true
        phase = .connectivity

        for target in ProbeTarget.all {
            connectivityByID[target.id] = ConnectivityResult(target: target)
        }

        task = Task { [weak self] in
            guard let self else { return }
            let connectivity = await networkService.runAll { result in
                Task { @MainActor [weak self] in
                    self?.connectivityByID[result.target.id] = result
                }
            }
            guard !Task.isCancelled else { return }
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
            let results = orderedConnectivity
            let conclusion = ConclusionEngine.make(connectivity: results, ipReport: ipReport, ipError: errorMessage)
            let record = TestRecord(connectivityResults: results, ipReport: ipReport, conclusion: conclusion)
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
        connectivity: [ConnectivityResult],
        ipReport: IPQualityReport?,
        ipError: String?
    ) -> FinalConclusion {
        let summary = ConnectivitySummary(results: connectivity)
        let connectivityText: String
        if summary.baselinePass {
            let foreignNames = summary.reachableForeignTargets.map { $0.target.name }.joined(separator: "、")
            connectivityText = "基础联通合格：百度达标，国外可达站点为 \(foreignNames)。"
        } else if !summary.baiduPass && !summary.foreignPass {
            connectivityText = "基础联通不合格：百度未达标，且全部国外站点均不可达。"
        } else if !summary.baiduPass {
            connectivityText = "基础联通不合格：存在国外站点可达，但百度未达到 80% 成功率、20% 以下丢包、500ms 以下平均延迟且 HTTPS 可访问的门槛。"
        } else {
            connectivityText = "基础联通不合格：百度达标，但没有任何国外站点能够建立连接或完成 HTTPS 探测。"
        }

        guard let ipReport else {
            return FinalConclusion(
                grade: summary.baselinePass ? .caution : .poor,
                title: summary.baselinePass ? "联通可用，但 IP 质量未知" : "节点联通不合格",
                connectivityText: connectivityText,
                ipQualityText: ipError ?? "IP 质量数据不足，不能判断出口是否干净。",
                detail: "全部联通项目已完成；IP 质量部分失败，因此不会把未知结果误判为低风险。"
            )
        }

        let ipQualityText = "出口 IP \(ipReport.ip)，网络风险 \(ipReport.networkRiskScore)/100（\(ipReport.networkRiskLevel)），Claude 风险 \(ipReport.claudeRiskScore)/100。\(ipReport.claudeVerdict)"

        let grade: OverallGrade
        if !summary.baselinePass || ipReport.claudeRiskScore >= 80 || ipReport.networkRiskScore >= 80 {
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
        case .poor: title = summary.baselinePass ? "IP 风险过高" : "节点联通不合格"
        }

        let detail = "联通性与 IP 信誉分开评分。即使基础联通失败，应用仍会完成全部 IP 数据源检测；即使 IP 很干净，联通不稳定也不会被判定为好节点。"
        return FinalConclusion(
            grade: grade,
            title: title,
            connectivityText: connectivityText,
            ipQualityText: ipQualityText,
            detail: detail
        )
    }
}
