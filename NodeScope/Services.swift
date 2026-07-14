import Foundation
import Network

// MARK: - Connectivity probe

actor NetworkProbeService {
    private let attemptCount = 5
    private let timeoutSeconds: TimeInterval = 5
    private let queue = DispatchQueue(label: "com.anfyya.NodeScope.probe", qos: .userInitiated)

    func runAll(
        update: @escaping @Sendable (ConnectivityResult) -> Void
    ) async -> [ConnectivityResult] {
        await withTaskGroup(of: ConnectivityResult.self) { group in
            for target in ProbeTarget.all {
                group.addTask { [self] in
                    await probe(target: target, update: update)
                }
            }

            var collected: [ConnectivityResult] = []
            for await result in group {
                collected.append(result)
            }

            let order = Dictionary(uniqueKeysWithValues: ProbeTarget.all.enumerated().map { ($1.id, $0) })
            return collected.sorted { (order[$0.target.id] ?? 999) < (order[$1.target.id] ?? 999) }
        }
    }

    private func probe(
        target: ProbeTarget,
        update: @escaping @Sendable (ConnectivityResult) -> Void
    ) async -> ConnectivityResult {
        var result = ConnectivityResult(target: target)
        update(result)

        for attempt in 1...attemptCount {
            let sample = await tcpProbe(host: target.host, attempt: attempt)
            result.samples.append(sample)
            update(result)
            if attempt < attemptCount {
                try? await Task.sleep(for: .milliseconds(220))
            }
        }

        let http = await httpProbe(urlString: target.urlString)
        result.httpReachable = http.reachable
        result.httpStatusCode = http.statusCode
        result.httpLatencyMilliseconds = http.latency
        result.httpError = http.error
        update(result)
        return result
    }

    private func tcpProbe(host: String, attempt: Int) async -> ProbeSample {
        await withCheckedContinuation { continuation in
            let startedAt = CFAbsoluteTimeGetCurrent()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: 443,
                using: .tcp
            )
            let state = LockedProbeState()

            func finish(success: Bool, error: String?) {
                guard state.claim() else { return }
                let latency = success ? (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000 : nil
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: ProbeSample(
                    attempt: attempt,
                    success: success,
                    latencyMilliseconds: latency,
                    error: error
                ))
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    finish(success: true, error: nil)
                case .failed(let error):
                    finish(success: false, error: error.localizedDescription)
                case .cancelled:
                    finish(success: false, error: "连接被取消")
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(success: false, error: "连接超时")
            }
        }
    }

    private func httpProbe(urlString: String) async -> HTTPProbeResult {
        guard let url = URL(string: urlString) else {
            return .init(reachable: false, statusCode: nil, latency: nil, error: "无效 URL")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeoutSeconds
        request.setValue("NodeScope/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            let latency = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            session.invalidateAndCancel()
            return .init(reachable: true, statusCode: statusCode, latency: latency, error: nil)
        } catch {
            session.invalidateAndCancel()
            return .init(reachable: false, statusCode: nil, latency: nil, error: error.localizedDescription)
        }
    }
}

private final class LockedProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

private struct HTTPProbeResult: Sendable {
    let reachable: Bool
    let statusCode: Int?
    let latency: Double?
    let error: String?
}

// MARK: - IP quality inspection

actor IPQualityService {
    private let timeoutSeconds: TimeInterval = 8

    private let sourceWeights: [String: Int] = [
        "ipapi.is": 5,
        "ip-api.com": 5,
        "ipwho.is": 4,
        "ipapi.co": 3,
        "proxycheck.io": 4,
        "StopForumSpam": 2
    ]

    private let mainlandASNKeywords = [
        "chinanet", "china telecom", "china unicom", "china mobile", "cmnet",
        "china netcom", "china education", "cernet", "drpeng", "great wall broadband",
        "alibaba", "aliyun", "alicloud", "tencent", "qcloud", "huawei cloud",
        "huaweicloud", "baidu", "baidubce", "volcengine", "volces", "bytedance",
        "jd cloud", "ucloud", "kingsoft cloud", "ksyun", "qingcloud", "netease",
        "china science and technology network", "cncgroup", "cstnet"
    ]

    private let cloudKeywords = [
        "amazon", "aws", "google cloud", "microsoft azure", "azure", "oracle cloud",
        "digitalocean", "vultr", "linode", "akamai", "ovh", "hetzner", "leaseweb",
        "contabo", "choopa", "cloudflare", "alibaba", "aliyun", "tencent", "qcloud",
        "huawei cloud", "baidu cloud", "volcengine", "ucloud", "kingsoft cloud",
        "hosting", "host", "server", "datacenter", "data center", "colo", "vps"
    ]

    func inspect(
        ipUpdate: @escaping @Sendable (String) -> Void,
        sourceUpdate: @escaping @Sendable (IPObservation) -> Void
    ) async throws -> IPQualityReport {
        let ip = try await detectCurrentIP()
        ipUpdate(ip)

        let observations = await withTaskGroup(of: IPObservation.self) { group in
            group.addTask { [self] in await queryIPAPIIS(ip: ip) }
            group.addTask { [self] in await queryIPAPI(ip: ip) }
            group.addTask { [self] in await queryIPWho(ip: ip) }
            group.addTask { [self] in await queryIPAPICo(ip: ip) }
            group.addTask { [self] in await queryProxyCheck(ip: ip) }
            group.addTask { [self] in await queryStopForumSpam(ip: ip) }

            var values: [IPObservation] = []
            for await observation in group {
                values.append(observation)
                sourceUpdate(observation)
            }
            let order = ["ipapi.is", "ip-api.com", "ipwho.is", "ipapi.co", "proxycheck.io", "StopForumSpam"]
            let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            return values.sorted { (positions[$0.source] ?? 99) < (positions[$1.source] ?? 99) }
        }

        return buildReport(ip: ip, observations: observations)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private func fetchJSON(_ urlString: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw ServiceError.invalidURL }
        let session = makeSession()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeoutSeconds
        request.setValue("NodeScope/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw ServiceError.invalidURL }
        let session = makeSession()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeoutSeconds
        request.setValue("NodeScope/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request)
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ServiceError.invalidResponse
        }
        return text
    }

    private func detectCurrentIP() async throws -> String {
        let endpoints = [
            "https://api.ipify.org",
            "https://ipv4.icanhazip.com",
            "https://v4.ident.me"
        ]
        var errors: [String] = []
        for endpoint in endpoints {
            do {
                let value = try await fetchText(endpoint)
                guard value.split(separator: ".").count == 4 else {
                    throw ServiceError.invalidIP
                }
                return value
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        throw ServiceError.allIPProvidersFailed(errors.joined(separator: "；"))
    }

    private func queryIPAPIIS(ip: String) async -> IPObservation {
        let source = "ipapi.is"
        do {
            let object = try await fetchJSON("https://api.ipapi.is/?q=\(encoded(ip))")
            guard let data = object as? [String: Any] else { throw ServiceError.invalidResponse }
            if data["error"] != nil { throw ServiceError.provider(message: clean(data["error"]) ?? "接口返回错误") }
            let location = data["location"] as? [String: Any] ?? [:]
            let asnData = data["asn"] as? [String: Any] ?? [:]
            let company = data["company"] as? [String: Any] ?? [:]
            let abuse = data["abuse"] as? [String: Any] ?? [:]
            return IPObservation(
                source: source,
                country: clean(location["country"] ?? data["country"]),
                countryCode: clean(location["country_code"] ?? data["country_code"]),
                region: clean(location["state"] ?? location["region"]),
                city: clean(location["city"]),
                asn: normalizeASN(asnData["asn"] ?? data["asn"]),
                asName: clean(asnData["descr"] ?? asnData["name"] ?? asnData["org"]),
                isp: clean(company["name"] ?? asnData["org"]),
                org: clean(company["name"] ?? company["domain"]),
                proxy: boolValue(data["is_proxy"]),
                vpn: boolValue(data["is_vpn"]),
                tor: boolValue(data["is_tor"]),
                hosting: boolValue(data["is_datacenter"] ?? data["is_hosting"]),
                mobile: boolValue(data["is_mobile"]),
                abuser: boolValue(data["is_abuser"] ?? abuse["is_abuser"])
            )
        } catch {
            return failed(source, error)
        }
    }

    private func queryIPAPI(ip: String) async -> IPObservation {
        let source = "ip-api.com"
        let fields = "status,message,query,country,countryCode,regionName,city,isp,org,as,asname,mobile,proxy,hosting"
        do {
            let object = try await fetchJSON("http://ip-api.com/json/\(encoded(ip))?fields=\(encoded(fields))&lang=zh-CN")
            guard let data = object as? [String: Any], clean(data["status"]) == "success" else {
                throw ServiceError.provider(message: clean((object as? [String: Any])?["message"]) ?? "查询失败")
            }
            return IPObservation(
                source: source,
                country: clean(data["country"]),
                countryCode: clean(data["countryCode"]),
                region: clean(data["regionName"]),
                city: clean(data["city"]),
                asn: normalizeASN(data["as"]),
                asName: clean(data["asname"]),
                isp: clean(data["isp"]),
                org: clean(data["org"]),
                proxy: boolValue(data["proxy"]),
                hosting: boolValue(data["hosting"]),
                mobile: boolValue(data["mobile"])
            )
        } catch {
            return failed(source, error)
        }
    }

    private func queryIPWho(ip: String) async -> IPObservation {
        let source = "ipwho.is"
        do {
            let object = try await fetchJSON("https://ipwho.is/\(encoded(ip))")
            guard let data = object as? [String: Any] else { throw ServiceError.invalidResponse }
            if boolValue(data["success"]) == false {
                throw ServiceError.provider(message: clean(data["message"]) ?? "查询失败")
            }
            let connection = data["connection"] as? [String: Any] ?? [:]
            let security = data["security"] as? [String: Any] ?? [:]
            return IPObservation(
                source: source,
                country: clean(data["country"]),
                countryCode: clean(data["country_code"]),
                region: clean(data["region"]),
                city: clean(data["city"]),
                asn: normalizeASN(connection["asn"]),
                asName: clean(connection["org"]),
                isp: clean(connection["isp"]),
                org: clean(connection["org"] ?? connection["domain"]),
                proxy: boolValue(security["proxy"]),
                vpn: boolValue(security["vpn"]),
                tor: boolValue(security["tor"]),
                hosting: boolValue(security["hosting"])
            )
        } catch {
            return failed(source, error)
        }
    }

    private func queryIPAPICo(ip: String) async -> IPObservation {
        let source = "ipapi.co"
        do {
            let object = try await fetchJSON("https://ipapi.co/\(encoded(ip))/json/")
            guard let data = object as? [String: Any] else { throw ServiceError.invalidResponse }
            if boolValue(data["error"]) == true {
                throw ServiceError.provider(message: clean(data["reason"]) ?? "接口返回错误")
            }
            return IPObservation(
                source: source,
                country: clean(data["country_name"]),
                countryCode: clean(data["country_code"]),
                region: clean(data["region"]),
                city: clean(data["city"]),
                asn: normalizeASN(data["asn"]),
                asName: clean(data["org"]),
                isp: clean(data["org"]),
                org: clean(data["org"])
            )
        } catch {
            return failed(source, error)
        }
    }

    private func queryProxyCheck(ip: String) async -> IPObservation {
        let source = "proxycheck.io"
        do {
            let url = "https://proxycheck.io/v2/\(encoded(ip))?vpn=1&asn=1&risk=1&port=1&seen=1&days=7"
            let object = try await fetchJSON(url)
            guard let data = object as? [String: Any] else { throw ServiceError.invalidResponse }
            let status = clean(data["status"])?.lowercased()
            guard status == "ok" || status == "warning" else {
                throw ServiceError.provider(message: clean(data["message"] ?? data["status"]) ?? "查询失败")
            }
            let item = (data[ip] as? [String: Any]) ?? data.values.compactMap { $0 as? [String: Any] }.first
            guard let item else { throw ServiceError.invalidResponse }
            let detected = boolValue(item["proxy"])
            let type = clean(item["type"])?.lowercased() ?? ""
            let provider = clean(item["provider"])
            let operatorData = item["operator"] as? [String: Any] ?? [:]
            var notes: [String] = []
            if let provider { notes.append("服务商：\(provider)") }
            if let lastSeen = clean(item["last seen"]) { notes.append("最后发现：\(lastSeen)") }
            return IPObservation(
                source: source,
                country: clean(item["country"]),
                countryCode: clean(item["isocode"]),
                region: clean(item["region"]),
                city: clean(item["city"]),
                asn: normalizeASN(item["asn"]),
                asName: clean(operatorData["name"] ?? provider),
                isp: clean(item["provider"] ?? operatorData["name"]),
                org: clean(operatorData["name"] ?? item["provider"]),
                proxy: detected,
                vpn: detected == true && type.contains("vpn") ? true : (detected == false ? false : nil),
                tor: detected == true && type.contains("tor") ? true : (detected == false ? false : nil),
                hosting: detected == true && ["hosting", "server", "business"].contains { type.contains($0) } ? true : nil,
                providerRisk: intValue(item["risk"]),
                notes: notes
            )
        } catch {
            return failed(source, error)
        }
    }

    private func queryStopForumSpam(ip: String) async -> IPObservation {
        let source = "StopForumSpam"
        do {
            let object = try await fetchJSON("https://api.stopforumspam.org/api?ip=\(encoded(ip))&json")
            guard let data = object as? [String: Any], intValue(data["success"]) == 1 else {
                throw ServiceError.provider(message: "查询失败")
            }
            let item = data["ip"] as? [String: Any] ?? [:]
            let appears = boolValue(item["appears"])
            let frequency = intValue(item["frequency"])
            var notes: [String] = []
            if let frequency { notes.append("垃圾活动记录：\(frequency) 次") }
            if let confidence = clean(item["confidence"]) { notes.append("命中置信度：\(confidence)%") }
            if let lastSeen = clean(item["lastseen"]) { notes.append("最后记录：\(lastSeen)") }
            return IPObservation(
                source: source,
                spammer: appears,
                providerRisk: appears == true ? min(100, (frequency ?? 0) * 5) : 0,
                notes: notes
            )
        } catch {
            return failed(source, error)
        }
    }

    private func buildReport(ip: String, observations: [IPObservation]) -> IPQualityReport {
        let successful = observations.filter(\.ok)
        let failed = Dictionary(uniqueKeysWithValues: observations.filter { !$0.ok }.map { ($0.source, $0.error ?? "未知错误") })

        guard !successful.isEmpty else {
            return IPQualityReport(
                ip: ip, country: nil, countryCode: nil, region: nil, city: nil,
                asn: nil, asName: nil, isp: nil, org: nil,
                proxy: false, vpn: false, tor: false, hosting: false, mobile: false,
                abuser: false, spammer: false, mainlandGeo: false, mainlandASN: false,
                networkRiskScore: -1, networkRiskLevel: "无法判断", claudeRiskScore: -1,
                claudeVerdict: "无法判断：所有数据源均查询失败",
                confidence: 0,
                reasons: ["所有外部数据源均查询失败，未获得有效证据"],
                successfulSources: [], failedSources: failed, observations: observations
            )
        }

        let country = weightedString(successful, \.country)
        let countryCode = weightedString(successful, \.countryCode)?.uppercased()
        let region = weightedString(successful, \.region)
        let city = weightedString(successful, \.city)
        let asn = weightedString(successful, \.asn)
        let asName = weightedString(successful, \.asName)
        let isp = weightedString(successful, \.isp)
        let org = weightedString(successful, \.org)

        let proxyState = flagResult(successful, \.proxy)
        let vpnState = flagResult(successful, \.vpn)
        let torState = flagResult(successful, \.tor)
        var hostingState = flagResult(successful, \.hosting)
        let mobileState = flagResult(successful, \.mobile)
        let abuserState = flagResult(successful, \.abuser)
        let spammerState = flagResult(successful, \.spammer)

        if containsKeyword([asName, isp, org], keywords: cloudKeywords) {
            hostingState.detected = true
        }

        let mainlandGeo = successful.contains {
            ($0.countryCode ?? "").uppercased() == "CN" ||
            ["china", "中国", "中国大陆", "mainland china"].contains(($0.country ?? "").lowercased())
        }
        let mainlandASN = containsKeyword([asName, isp, org], keywords: mainlandASNKeywords)
        let maxProviderRisk = successful.compactMap(\.providerRisk).max() ?? 0

        var reasons: [String] = []
        var networkScore = 0
        if torState.detected {
            networkScore += 65
            reasons.append("Tor 出口命中（\(torState.yes) 个来源）")
        }
        if proxyState.detected {
            networkScore += 28
            reasons.append("代理出口命中（\(proxyState.yes) 个来源，\(proxyState.no) 个来源未命中）")
        }
        if vpnState.detected {
            networkScore += 22
            reasons.append("VPN 命中（\(vpnState.yes) 个来源，\(vpnState.no) 个来源未命中）")
        }
        if hostingState.detected {
            networkScore += 20
            reasons.append(hostingState.yes > 0 ? "机房/云服务器命中（\(hostingState.yes) 个来源）" : "ASN/组织名称具有机房或云服务器特征")
        }
        if abuserState.detected {
            networkScore += 35
            reasons.append("滥用网络命中（\(abuserState.yes) 个来源）")
        }
        if spammerState.detected {
            networkScore += 35
            reasons.append("垃圾信息历史命中（\(spammerState.yes) 个来源）")
        }
        if maxProviderRisk > 0 {
            let contribution = Int((Double(maxProviderRisk) * 0.2).rounded())
            networkScore += contribution
            reasons.append("外部风险分最高 \(maxProviderRisk)/100（计入 \(contribution) 分）")
        }
        networkScore = min(100, networkScore)

        let claudeScore: Int
        if mainlandGeo {
            claudeScore = 100
            reasons.append("中国大陆地理位置命中：Claude 地区限制风险为硬性风险")
        } else {
            var score = 0
            if mainlandASN {
                score += 75
                reasons.append("ASN/运营商具有中国大陆网络特征")
            }
            if torState.detected { score += 55 }
            if proxyState.detected { score += 20 }
            if vpnState.detected { score += 18 }
            if hostingState.detected { score += 24 }
            if abuserState.detected || spammerState.detected { score += 22 }
            if maxProviderRisk >= 75 { score += 15 }
            else if maxProviderRisk >= 40 { score += 8 }
            claudeScore = min(100, score)
        }

        if reasons.isEmpty {
            reasons.append("未发现代理、VPN、Tor、机房、滥用或中国大陆地区特征")
        }

        var confidence = min(80, successful.count * 14)
        for state in [proxyState, vpnState, hostingState] where state.yes + state.no >= 2 && (state.yes == 0 || state.no == 0) {
            confidence += 5
        }
        confidence = min(100, confidence)

        return IPQualityReport(
            ip: ip,
            country: country,
            countryCode: countryCode,
            region: region,
            city: city,
            asn: asn,
            asName: asName,
            isp: isp,
            org: org,
            proxy: proxyState.detected,
            vpn: vpnState.detected,
            tor: torState.detected,
            hosting: hostingState.detected,
            mobile: mobileState.detected,
            abuser: abuserState.detected,
            spammer: spammerState.detected,
            mainlandGeo: mainlandGeo,
            mainlandASN: mainlandASN,
            networkRiskScore: networkScore,
            networkRiskLevel: riskLevel(networkScore),
            claudeRiskScore: claudeScore,
            claudeVerdict: claudeVerdict(score: claudeScore, mainlandGeo: mainlandGeo, mainlandASN: mainlandASN),
            confidence: confidence,
            reasons: reasons,
            successfulSources: successful.map(\.source),
            failedSources: failed,
            observations: observations
        )
    }

    private func weightedString(_ values: [IPObservation], _ keyPath: KeyPath<IPObservation, String?>) -> String? {
        var scores: [String: Int] = [:]
        var originals: [String: String] = [:]
        for value in values {
            guard let raw = value[keyPath: keyPath], !raw.isEmpty else { continue }
            let key = raw.lowercased()
            scores[key, default: 0] += sourceWeights[value.source, default: 1]
            originals[key] = originals[key] ?? raw
        }
        guard let winner = scores.max(by: { $0.value < $1.value })?.key else { return nil }
        return originals[winner]
    }

    private func flagResult(_ values: [IPObservation], _ keyPath: KeyPath<IPObservation, Bool?>) -> FlagState {
        var yes = 0
        var no = 0
        var positiveWeight = 0
        for value in values {
            guard let flag = value[keyPath: keyPath] else { continue }
            if flag {
                yes += 1
                positiveWeight += sourceWeights[value.source, default: 1]
            } else {
                no += 1
            }
        }
        return FlagState(detected: positiveWeight > 0, yes: yes, no: no)
    }

    private func containsKeyword(_ values: [String?], keywords: [String]) -> Bool {
        let text = values.compactMap { $0 }.joined(separator: " ").lowercased()
        return keywords.contains { text.contains($0.lowercased()) }
    }

    private func riskLevel(_ score: Int) -> String {
        if score >= 80 { return "极高风险" }
        if score >= 60 { return "高风险" }
        if score >= 35 { return "中风险" }
        if score >= 15 { return "低风险" }
        return "较干净"
    }

    private func claudeVerdict(score: Int, mainlandGeo: Bool, mainlandASN: Bool) -> String {
        if mainlandGeo { return "不可用于 Claude：出口位置被识别为中国大陆" }
        if mainlandASN { return "极不建议：出口仍带有中国大陆 ASN/运营商特征" }
        if score >= 80 { return "极不建议：很可能触发地区或代理风控" }
        if score >= 60 { return "不建议：Claude 风控风险较高" }
        if score >= 35 { return "可尝试，但存在明显风控因素" }
        if score >= 15 { return "基本可用，但不是最干净的出口" }
        return "适合使用 Claude，未发现明显地区或代理风险"
    }

    private func failed(_ source: String, _ error: Error) -> IPObservation {
        IPObservation(source: source, ok: false, error: error.localizedDescription)
    }

    private func clean(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        guard let text = clean(value)?.lowercased() else { return nil }
        if ["yes", "true", "1", "y", "detected", "listed"].contains(text) { return true }
        if ["no", "false", "0", "n", "not detected", "unlisted"].contains(text) { return false }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        guard let text = clean(value), let number = Double(text) else { return nil }
        return Int(number)
    }

    private func normalizeASN(_ value: Any?) -> String? {
        guard let text = clean(value) else { return nil }
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? text : "AS\(digits)"
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private struct FlagState: Sendable {
    var detected: Bool
    let yes: Int
    let no: Int
}

private enum ServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidIP
    case allIPProvidersFailed(String)
    case provider(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无效 URL"
        case .invalidResponse: "接口返回格式无效"
        case .invalidIP: "接口返回的不是有效 IPv4"
        case .allIPProvidersFailed(let detail): "自动获取出口 IP 失败：\(detail)"
        case .provider(let message): message
        }
    }
}
