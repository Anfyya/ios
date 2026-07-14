import Charts
import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
    }
}

// MARK: - Design tokens

enum NodeTheme {
    static func color(for grade: ProbeGrade) -> Color {
        switch grade {
        case .testing: .blue
        case .excellent: .green
        case .good: .mint
        case .usable: Color.yellow.mix(with: .orange, by: 0.55)
        case .poor: .orange
        case .unreachable: .red
        }
    }

    static func color(for grade: OverallGrade) -> Color {
        switch grade {
        case .excellent: .green
        case .good: .mint
        case .caution: .orange
        case .poor: .red
        }
    }

    static func latencyTint(_ milliseconds: Double?) -> Color {
        guard let milliseconds else { return .red }
        if milliseconds < 80 { return .green }
        if milliseconds < 200 { return .mint }
        if milliseconds < 500 { return Color.yellow.mix(with: .orange, by: 0.55) }
        return .orange
    }

    static func riskTint(_ score: Int) -> Color {
        if score < 0 { return .gray }
        if score < 30 { return .green }
        if score < 60 { return .orange }
        return .red
    }
}

// MARK: - Shared components

struct AttemptSegment: Identifiable, Hashable {
    enum State: Hashable {
        case pending
        case success(Double?)
        case failure
    }

    let id: Int
    let state: State
}

struct AttemptStrip: View {
    let segments: [AttemptSegment]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(segments) { segment in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill(for: segment.state))
                    .overlay {
                        if segment.state == .pending {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .frame(width: 22, height: 8)
            }
        }
    }

    private func fill(for state: AttemptSegment.State) -> Color {
        switch state {
        case .pending: .clear
        case .success(let latency): NodeTheme.latencyTint(latency)
        case .failure: .red
        }
    }
}

extension AttemptStrip {
    init(dnsSamples samples: [DNSProbeSample]) {
        self.init(segments: (1...5).map { attempt in
            guard let sample = samples.first(where: { $0.attempt == attempt }) else {
                return AttemptSegment(id: attempt, state: .pending)
            }
            return AttemptSegment(
                id: attempt,
                state: sample.success ? .success(sample.latencyMilliseconds) : .failure
            )
        })
    }

    init(probeSamples samples: [ProbeSample]) {
        self.init(segments: (1...5).map { attempt in
            guard let sample = samples.first(where: { $0.attempt == attempt }) else {
                return AttemptSegment(id: attempt, state: .pending)
            }
            return AttemptSegment(
                id: attempt,
                state: sample.success ? .success(sample.latencyMilliseconds) : .failure
            )
        })
    }
}

struct GradeChip: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Background

struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                Color.indigo.opacity(colorScheme == .dark ? 0.22 : 0.10),
                Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.05),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottom
        )
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}

// MARK: - Home

struct HomeView: View {
    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 36) {
                Spacer()

                VStack(spacing: 14) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 56, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                    Text("节点体检")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                }

                NavigationLink {
                    LiveTestView()
                } label: {
                    Label("开始测试", systemImage: "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: 230)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)

                Spacer()
                Spacer()
            }
            .padding(28)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("历史记录")
            }
        }
    }
}

// MARK: - Live test dashboard

struct LiveTestView: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @StateObject private var model = TestViewModel()

    @State private var selectedDNS: DNSProbeResult?
    @State private var selectedEndpoint: ConnectivityResult?
    @State private var showIPDetail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VerdictHeader(
                    phase: model.phase,
                    progress: model.totalProgress,
                    currentIP: model.currentIP,
                    record: model.finalRecord
                )

                DNSGroup(results: model.orderedDNS) { selectedDNS = $0 }

                ServiceGroup(results: model.orderedConnectivity) { selectedEndpoint = $0 }

                if showIPSection {
                    IPGroup(
                        observations: model.sourceObservations,
                        report: model.finalRecord?.ipReport,
                        isLoading: model.phase != .completed && model.phase != .failed
                    ) {
                        showIPDetail = true
                    }
                }

                if let record = model.finalRecord {
                    FullReportLink(record: record)
                } else if let error = model.errorMessage {
                    ErrorCard(message: error)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(AmbientBackground())
        .navigationTitle("节点检测")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止", role: .destructive) {
                        model.cancel()
                    }
                }
            }
        }
        .task {
            if model.phase == .idle {
                model.start(historyStore: historyStore)
            }
        }
        .sheet(item: $selectedDNS) { result in
            DetailSheet(title: result.target.name) {
                DNSResultCard(result: result)
            }
        }
        .sheet(item: $selectedEndpoint) { result in
            DetailSheet(title: result.target.name) {
                EndpointResultCard(result: result)
            }
        }
        .sheet(isPresented: $showIPDetail) {
            IPDetailSheet(
                observations: model.sourceObservations,
                report: model.finalRecord?.ipReport
            )
        }
    }

    private var showIPSection: Bool {
        switch model.phase {
        case .ipDetection, .ipQuality, .finalizing, .completed: true
        default: false
        }
    }
}

// MARK: - Verdict header

struct VerdictHeader: View {
    let phase: TestPhase
    let progress: Double
    let currentIP: String?
    let record: TestRecord?

    var body: some View {
        Group {
            if let record {
                completed(record)
            } else {
                running
            }
        }
    }

    private func completed(_ record: TestRecord) -> some View {
        let color = NodeTheme.color(for: record.conclusion.grade)
        return HStack(spacing: 16) {
            Image(systemName: record.conclusion.grade.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.conclusion.title)
                    .font(.title3.bold())
                HStack(spacing: 8) {
                    Text(record.conclusion.grade.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                    if let ip = record.ipReport?.ip {
                        Text(ip)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .glassEffect(.regular.tint(color.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.title)
                        .font(.subheadline.weight(.semibold))
                    if let currentIP {
                        Text(currentIP)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            ProgressView(value: progress)
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

// MARK: - Group container

struct GroupCard<Content: View>: View {
    let title: String
    let statusText: String?
    let statusColor: Color
    let content: Content

    init(
        title: String,
        statusText: String? = nil,
        statusColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.statusText = statusText
        self.statusColor = statusColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let statusText {
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }
            content
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

// MARK: - DNS group

struct DNSGroup: View {
    let results: [DNSProbeResult]
    let onSelect: (DNSProbeResult) -> Void

    var body: some View {
        GroupCard(title: "基础网络", statusText: statusText, statusColor: statusColor) {
            VStack(spacing: 0) {
                ForEach(results) { result in
                    Button {
                        onSelect(result)
                    } label: {
                        CompactRow(
                            color: NodeTheme.color(for: result.grade),
                            name: result.target.name,
                            trailing: trailingText(result),
                            isTesting: result.grade == .testing
                        )
                    }
                    .buttonStyle(.plain)
                    if result.id != results.last?.id {
                        Divider().padding(.leading, 18)
                    }
                }
            }
        }
    }

    private var summary: DNSConnectivitySummary { .init(results: results) }
    private var allComplete: Bool { results.allSatisfy(\.isComplete) && !results.isEmpty }

    private var statusText: String? {
        guard allComplete else { return nil }
        return summary.baselinePass ? "合格" : "未达标"
    }

    private var statusColor: Color {
        summary.baselinePass ? .green : .red
    }

    private func trailingText(_ result: DNSProbeResult) -> String? {
        if result.grade == .testing { return nil }
        if !result.reachableAtAll { return "不可达" }
        return milliseconds(result.averageLatency)
    }
}

// MARK: - Service group

struct ServiceGroup: View {
    let results: [ConnectivityResult]
    let onSelect: (ConnectivityResult) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        GroupCard(title: "服务可用性", statusText: statusText, statusColor: statusColor) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(results) { result in
                    Button {
                        onSelect(result)
                    } label: {
                        ServiceTile(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private var allComplete: Bool { results.allSatisfy(\.isComplete) && !results.isEmpty }
    private var reachableCount: Int { results.filter(\.httpReachable).count }

    private var statusText: String? {
        guard allComplete else { return nil }
        return "\(reachableCount)/\(results.count) 可访问"
    }

    private var statusColor: Color {
        reachableCount > 0 ? .green : .red
    }
}

struct ServiceTile: View {
    let result: ConnectivityResult

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(NodeTheme.color(for: result.grade))
                .frame(width: 7, height: 7)
            Text(result.target.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if result.grade == .testing {
            ProgressView()
                .controlSize(.mini)
        } else if !result.reachableAtAll {
            Text("×")
                .font(.caption.bold())
                .foregroundStyle(.red)
        } else {
            Text(milliseconds(result.averageLatency ?? result.httpLatencyMilliseconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - IP group

struct IPGroup: View {
    let observations: [IPObservation]
    let report: IPQualityReport?
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        GroupCard(title: "IP 质量", statusText: statusText, statusColor: .secondary) {
            if let report {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(report.ip)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text("可信度 \(report.confidence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 14) {
                            RiskLabel(title: "网络风险", score: report.networkRiskScore)
                            RiskLabel(title: "Claude 风险", score: report.claudeRiskScore)
                            Spacer()
                        }
                        Text(report.claudeVerdict)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(observations.isEmpty ? "正在获取出口 IP…" : "数据源 \(okCount)/\(observations.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var okCount: Int { observations.filter(\.ok).count }

    private var statusText: String? {
        report == nil ? nil : "\(okCount) 个数据源"
    }
}

struct RiskLabel: View {
    let title: String
    let score: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(score < 0 ? "?" : "\(score)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(NodeTheme.riskTint(score))
        }
    }
}

// MARK: - Compact row

struct CompactRow: View {
    let color: Color
    let name: String
    let trailing: String?
    let isTesting: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline)
            Spacer()
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
            } else if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail sheets

struct DetailSheet<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct IPDetailSheet: View {
    let observations: [IPObservation]
    let report: IPQualityReport?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let report {
                        IPReportCard(report: report)
                    }
                    ForEach(observations) { observation in
                        IPSourceCard(observation: observation)
                    }
                }
                .padding(16)
            }
            .navigationTitle("IP 质量")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

// MARK: - Full report

struct FullReportLink: View {
    let record: TestRecord

    var body: some View {
        NavigationLink {
            FullReportView(record: record)
        } label: {
            Label("查看完整报告", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.glass)
    }
}

struct FullReportView: View {
    let record: TestRecord

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ConclusionCard(conclusion: record.conclusion)
                DNSConnectivityThresholdCard(summary: record.dnsSummary)
                DNSLatencyChart(results: record.resolvedDNSResults)
                ServiceAvailabilityCard(summary: record.connectivitySummary)
                ConnectivityChart(results: record.connectivityResults)
                if let report = record.ipReport {
                    IPReportCard(report: report)
                    ForEach(report.observations) { observation in
                        IPSourceCard(observation: observation)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(AmbientBackground())
        .navigationTitle("完整报告")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Detail cards

struct EndpointResultCard: View {
    let result: ConnectivityResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: result.grade.symbol)
                    .font(.title2)
                    .foregroundStyle(gradeColor)
                    .symbolEffect(.pulse, isActive: result.grade == .testing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.target.name)
                        .font(.headline)
                    Text(result.target.host)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GradeChip(title: result.grade.title, color: gradeColor)
            }

            HStack(spacing: 8) {
                AttemptStrip(probeSamples: result.samples)
                Spacer()
                Label(
                    result.httpReachable ? "HTTPS 可访问" : (result.httpError == nil ? "等待 HTTPS" : "HTTPS 失败"),
                    systemImage: result.httpReachable ? "lock.open.fill" : "lock.slash"
                )
                .font(.caption)
                .foregroundStyle(result.httpReachable ? .green : .secondary)
            }

            HStack(spacing: 18) {
                MetricItem(title: "TCP 平均", value: milliseconds(result.averageLatency))
                MetricItem(title: "最低", value: milliseconds(result.minimumLatency))
                MetricItem(title: "HTTPS", value: milliseconds(result.httpLatencyMilliseconds))
                MetricItem(title: "失败率", value: result.samples.isEmpty ? "—" : result.packetLoss.formatted(.percent.precision(.fractionLength(0))))
            }

            if let status = result.httpStatusCode {
                Text("HTTP \(status) · HTTPS 延迟 \(milliseconds(result.httpLatencyMilliseconds))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let error = result.httpError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var gradeColor: Color {
        NodeTheme.color(for: result.grade)
    }
}

struct MetricItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IPSourceCard: View {
    let observation: IPObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: observation.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(observation.ok ? .green : .red)
                Text(observation.source)
                    .font(.headline)
                Spacer()
                GradeChip(title: observation.ok ? "成功" : "失败", color: observation.ok ? .green : .red)
            }

            if observation.ok {
                let location = [observation.country, observation.region, observation.city].compactMap { $0 }.joined(separator: " / ")
                LabeledContent("位置", value: location.isEmpty ? "未知" : location)
                LabeledContent("ASN", value: [observation.asn, observation.asName].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "未知")
                FlagGrid(observation: observation)
                ForEach(observation.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(observation.error ?? "未知错误")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct FlagGrid: View {
    let observation: IPObservation

    var body: some View {
        HStack(spacing: 7) {
            FlagChip(title: "代理", value: observation.proxy)
            FlagChip(title: "VPN", value: observation.vpn)
            FlagChip(title: "Tor", value: observation.tor)
            FlagChip(title: "机房", value: observation.hosting)
            FlagChip(title: "滥用", value: observation.abuser ?? observation.spammer)
        }
    }
}

struct FlagChip: View {
    let title: String
    let value: Bool?

    var body: some View {
        Text("\(title) \(value == nil ? "?" : (value == true ? "是" : "否"))")
            .font(.caption2.bold())
            .foregroundStyle(value == true ? .red : (value == false ? .green : .secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chipBackground, in: Capsule())
    }

    private var chipBackground: AnyShapeStyle {
        if value == true {
            AnyShapeStyle(Color.red.opacity(0.12))
        } else {
            AnyShapeStyle(.thinMaterial)
        }
    }
}

struct ConclusionCard: View {
    let conclusion: FinalConclusion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: conclusion.grade.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(conclusionColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conclusion.title)
                        .font(.title2.bold())
                    Text(conclusion.grade.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(conclusionColor)
                }
            }
            Divider()
            Label(conclusion.connectivityText, systemImage: "network")
            Label(conclusion.ipQualityText, systemImage: "shield.lefthalf.filled")
            Text(conclusion.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular.tint(conclusionColor.opacity(0.08)), in: .rect(cornerRadius: 28))
    }

    private var conclusionColor: Color {
        NodeTheme.color(for: conclusion.grade)
    }
}

struct ConnectivityChart: View {
    let results: [ConnectivityResult]

    private var chartValues: [ConnectivityResult] {
        results.filter { $0.averageLatency != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网站 TCP 平均延迟")
                .font(.headline)
            Chart(chartValues) { result in
                BarMark(
                    x: .value("延迟", result.averageLatency ?? 0),
                    y: .value("站点", result.target.name)
                )
                .foregroundStyle(NodeTheme.latencyTint(result.averageLatency).gradient)
                .cornerRadius(5)
                .annotation(position: .trailing) {
                    Text(milliseconds(result.averageLatency))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxisLabel("毫秒")
            .frame(height: max(260, CGFloat(chartValues.count) * 34))
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct ServiceAvailabilityCard: View {
    let summary: ConnectivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("服务可用性")
                .font(.headline)
            ThresholdRow(
                title: "国外服务",
                detail: summary.reachableForeignTargets.isEmpty
                    ? "Google、Gemini、OpenAI、ChatGPT、Claude、Grok、xAI 均未确认可访问"
                    : summary.reachableForeignTargets.map { $0.target.name }.joined(separator: "、"),
                passed: !summary.reachableForeignTargets.isEmpty
            )
            ThresholdRow(
                title: "国内服务",
                detail: summary.reachableDomesticTargets.isEmpty
                    ? "百度、哔哩哔哩、my78.cyou 均未确认可访问"
                    : summary.reachableDomesticTargets.map { $0.target.name }.joined(separator: "、"),
                passed: !summary.reachableDomesticTargets.isEmpty
            )
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct ThresholdRow: View {
    let title: String
    let detail: String
    let passed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct IPReportCard: View {
    let report: IPQualityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("出口 IP 质量")
                        .font(.headline)
                    Text(report.ip)
                        .font(.subheadline.monospaced())
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("可信度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(report.confidence)/100")
                        .font(.headline.monospacedDigit())
                }
            }

            HStack(spacing: 12) {
                ScoreGauge(title: "网络风险", score: report.networkRiskScore)
                ScoreGauge(title: "Claude 风险", score: report.claudeRiskScore)
            }

            LabeledContent("位置", value: report.locationText.nilIfEmpty ?? "未知")
            LabeledContent("ASN", value: [report.asn, report.asName].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "未知")
            LabeledContent("ISP/组织", value: report.isp ?? report.org ?? "未知")
            LabeledContent("Claude 结论", value: report.claudeVerdict)

            Divider()
            Text("判断依据")
                .font(.subheadline.bold())
            ForEach(report.reasons, id: \.self) { reason in
                Label(reason, systemImage: "circle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct ScoreGauge: View {
    let title: String
    let score: Int

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: Double(max(0, score)), in: 0...100) {
                Text(title)
            } currentValueLabel: {
                Text(score < 0 ? "?" : "\(score)")
                    .font(.headline.monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(NodeTheme.riskTint(score))
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ErrorCard: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 22))
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var historyStore: HistoryStore

    var body: some View {
        Group {
            if historyStore.records.isEmpty {
                ContentUnavailableView(
                    "暂无历史记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成一次节点检测后会自动保存在这里。")
                )
            } else {
                List {
                    ForEach(historyStore.records) { record in
                        NavigationLink {
                            HistoryDetailView(record: record)
                        } label: {
                            HistoryRow(record: record)
                        }
                    }
                    .onDelete(perform: historyStore.delete)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("历史记录")
        .toolbar {
            if !historyStore.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) {
                        historyStore.clear()
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: TestRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.conclusion.grade.symbol)
                .font(.title2)
                .foregroundStyle(NodeTheme.color(for: record.conclusion.grade))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.conclusion.title)
                    .font(.headline)
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let ip = record.ipReport?.ip {
                    Text(ip)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct HistoryDetailView: View {
    let record: TestRecord

    @State private var selectedDNS: DNSProbeResult?
    @State private var selectedEndpoint: ConnectivityResult?
    @State private var showIPDetail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VerdictHeader(phase: .completed, progress: 1, currentIP: record.ipReport?.ip, record: record)

                DNSGroup(results: record.resolvedDNSResults) { selectedDNS = $0 }

                ServiceGroup(results: record.connectivityResults) { selectedEndpoint = $0 }

                if record.ipReport != nil {
                    IPGroup(
                        observations: record.ipReport?.observations ?? [],
                        report: record.ipReport,
                        isLoading: false
                    ) {
                        showIPDetail = true
                    }
                }

                FullReportLink(record: record)
            }
            .padding(16)
        }
        .background(AmbientBackground())
        .navigationTitle("检测详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedDNS) { result in
            DetailSheet(title: result.target.name) {
                DNSResultCard(result: result)
            }
        }
        .sheet(item: $selectedEndpoint) { result in
            DetailSheet(title: result.target.name) {
                EndpointResultCard(result: result)
            }
        }
        .sheet(isPresented: $showIPDetail) {
            IPDetailSheet(
                observations: record.ipReport?.observations ?? [],
                report: record.ipReport
            )
        }
    }
}

// MARK: - Helpers

func milliseconds(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))ms"
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
