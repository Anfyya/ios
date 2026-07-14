import Charts
import SwiftUI

struct DNSResultCard: View {
    let result: DNSProbeResult

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
                    Text(result.target.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GradeChip(title: result.grade.title, color: gradeColor)
            }

            HStack(spacing: 8) {
                AttemptStrip(dnsSamples: result.samples)
                Spacer()
                Label("ICMP Echo", systemImage: "wave.3.right")
                    .font(.caption)
                    .foregroundStyle(result.reachableAtAll ? .green : .secondary)
            }

            HStack(spacing: 18) {
                MetricItem(title: "平均", value: milliseconds(result.averageLatency))
                MetricItem(title: "最低", value: milliseconds(result.minimumLatency))
                MetricItem(title: "最高", value: milliseconds(result.maximumLatency))
                MetricItem(title: "丢包", value: result.samples.isEmpty ? "—" : result.packetLoss.formatted(.percent.precision(.fractionLength(0))))
            }

            ProgressView(value: result.reachability)
                .tint(gradeColor)

            if let error = result.samples.last(where: { !$0.success })?.error, !result.reachableAtAll {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(gradeColor.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private var gradeColor: Color {
        NodeTheme.color(for: result.grade)
    }
}

struct DNSLatencyChart: View {
    let results: [DNSProbeResult]

    private var chartValues: [DNSProbeResult] {
        results.filter { $0.averageLatency != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公共 DNS ICMP 延迟")
                .font(.headline)
            Chart(chartValues) { result in
                BarMark(
                    x: .value("延迟", result.averageLatency ?? 0),
                    y: .value("DNS", result.target.name)
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
            .frame(height: max(220, CGFloat(chartValues.count) * 38))
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct DNSConnectivityThresholdCard: View {
    let summary: DNSConnectivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基础网络门槛")
                .font(.headline)
            ThresholdRow(
                title: "至少一个国内 DNS 达标",
                detail: summary.qualifyingDomesticResults.isEmpty
                    ? "成功率 ≥ 80%，丢包 ≤ 20%，平均延迟 ≤ 500ms"
                    : summary.qualifyingDomesticResults.map { $0.target.name }.joined(separator: "、"),
                passed: summary.domesticPass
            )
            ThresholdRow(
                title: "任意国外 DNS 能通",
                detail: summary.reachableGlobalResults.isEmpty
                    ? "Cloudflare、Google、Quad9 均未收到 ICMP 响应"
                    : summary.reachableGlobalResults.map { $0.target.name }.joined(separator: "、"),
                passed: summary.globalPass
            )
            ThresholdRow(
                title: "基础网络结论",
                detail: summary.baselinePass ? "合格" : "不合格，但仍已继续完成服务和 IP 质量检测",
                passed: summary.baselinePass
            )
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
