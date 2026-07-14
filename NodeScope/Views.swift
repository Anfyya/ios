import Charts
import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
    }
}

struct HomeView: View {
    @State private var animateBackground = false

    var body: some View {
        ZStack {
            AmbientBackground(isAnimating: animateBackground)

            VStack(spacing: 26) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 54, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    Text("节点体检")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("DNS、服务可用性与 IP 风险一次测完")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                animateBackground = true
            }
        }
    }
}

struct AmbientBackground: View {
    let isAnimating: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.2), Color.cyan.opacity(0.12), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 310, height: 310)
                .blur(radius: 42)
                .offset(x: isAnimating ? 150 : 90, y: isAnimating ? -250 : -180)
            Circle()
                .fill(Color.purple.opacity(0.15))
                .frame(width: 260, height: 260)
                .blur(radius: 48)
                .offset(x: isAnimating ? -140 : -80, y: isAnimating ? 300 : 220)
        }
        .ignoresSafeArea()
    }
}

struct LiveTestView: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @StateObject private var model = TestViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ProgressHeader(
                    phase: model.phase,
                    progress: model.totalProgress,
                    currentIP: model.currentIP
                )

                SectionHeader(
                    title: "基础网络",
                    subtitle: "6 个公共 DNS 各执行 5 次真实 ICMP Echo，统计延迟、成功率与丢包"
                )
                ForEach(model.orderedDNS) { result in
                    DNSResultCard(result: result)
                }

                SectionHeader(
                    title: "服务可用性",
                    subtitle: "网站探测只判断对应服务能否访问，不参与基础网络达标"
                )
                ForEach(model.orderedConnectivity) { result in
                    EndpointResultCard(result: result)
                }

                if model.phase == .ipDetection || model.phase == .ipQuality || model.phase == .finalizing || model.phase == .completed {
                    SectionHeader(title: "IP 质量", subtitle: "6 个免 Key 数据源交叉验证，未知不会当作干净")

                    if model.sourceObservations.isEmpty && model.phase != .completed {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在获取出口 IP 与查询数据源…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(18)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }

                    ForEach(model.sourceObservations) { observation in
                        IPSourceCard(observation: observation)
                    }
                }

                if let record = model.finalRecord {
                    FinalResultView(record: record)
                } else if let error = model.errorMessage {
                    ErrorCard(message: error)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(AmbientBackground(isAnimating: true))
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
    }
}

struct ProgressHeader: View {
    let phase: TestPhase
    let progress: Double
    let currentIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(phase.title)
                        .font(.title3.bold())
                    if let currentIP {
                        Text("出口 IP：\(currentIP)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: progress)
                .controlSize(.large)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

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
                Text(result.grade.title)
                    .font(.caption.bold())
                    .foregroundStyle(gradeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(gradeColor.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { index in
                    let sample = result.samples.first { $0.attempt == index }
                    Circle()
                        .fill(sampleColor(sample))
                        .frame(width: 10, height: 10)
                        .overlay {
                            if sample == nil {
                                Circle().stroke(.secondary.opacity(0.35), lineWidth: 1)
                            }
                        }
                }
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

            ProgressView(value: result.reachability)
                .tint(gradeColor)

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
        switch result.grade {
        case .testing: .blue
        case .excellent: .green
        case .good: .mint
        case .usable: .yellow
        case .poor: .orange
        case .unreachable: .red
        }
    }

    private func sampleColor(_ sample: ProbeSample?) -> Color {
        guard let sample else { return .clear }
        return sample.success ? .green : .red
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
                Text(observation.ok ? "成功" : "失败")
                    .font(.caption.bold())
                    .foregroundStyle(observation.ok ? .green : .red)
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
            .background(.thinMaterial, in: Capsule())
    }
}

struct FinalResultView: View {
    let record: TestRecord

    var body: some View {
        VStack(spacing: 18) {
            ConclusionCard(conclusion: record.conclusion)
            DNSLatencyChart(results: record.resolvedDNSResults)
            DNSConnectivityThresholdCard(summary: record.dnsSummary)
            ConnectivityChart(results: record.connectivityResults)
            ServiceAvailabilityCard(summary: record.connectivitySummary)
            if let report = record.ipReport {
                IPReportCard(report: report)
            }
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
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var conclusionColor: Color {
        switch conclusion.grade {
        case .excellent: .green
        case .good: .mint
        case .caution: .orange
        case .poor: .red
        }
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
                .annotation(position: .trailing) {
                    Text(milliseconds(result.averageLatency))
                        .font(.caption2.monospacedDigit())
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
            Text("这里不参与基础网络合格判定，只说明对应网站当前是否可访问。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

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
                .foregroundStyle(historyColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.conclusion.title)
                    .font(.headline)
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let ip = record.ipReport?.ip {
                    Text(ip)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var historyColor: Color {
        switch record.conclusion.grade {
        case .excellent: .green
        case .good: .mint
        case .caution: .orange
        case .poor: .red
        }
    }
}

struct HistoryDetailView: View {
    let record: TestRecord

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FinalResultView(record: record)

                SectionHeader(title: "DNS 明细", subtitle: "保存了每次 ICMP Echo 的延迟、成功与超时结果")
                ForEach(record.resolvedDNSResults) { result in
                    DNSResultCard(result: result)
                }

                SectionHeader(title: "服务明细", subtitle: "保存了每次 TCP 443 与 HTTPS 检测结果")
                ForEach(record.connectivityResults) { result in
                    EndpointResultCard(result: result)
                }

                if let report = record.ipReport {
                    SectionHeader(title: "数据源明细", subtitle: "当次检测的完整 IP 观察结果")
                    ForEach(report.observations) { observation in
                        IPSourceCard(observation: observation)
                    }
                }
            }
            .padding(16)
        }
        .background(AmbientBackground(isAnimating: true))
        .navigationTitle("检测详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func milliseconds(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))ms"
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
