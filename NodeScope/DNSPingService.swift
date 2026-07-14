import Foundation
@preconcurrency import SwiftyPing

final class DNSPingService: @unchecked Sendable {
    private let attemptCount = 5
    private let callbackQueue = DispatchQueue(label: "com.anfyya.NodeScope.icmp", qos: .userInitiated)

    func runAll(
        update: @escaping @Sendable (DNSProbeResult) -> Void
    ) async -> [DNSProbeResult] {
        await withTaskGroup(of: DNSProbeResult.self) { group in
            for target in DNSProbeTarget.all {
                group.addTask { [self] in
                    await probe(target: target, update: update)
                }
            }

            var collected: [DNSProbeResult] = []
            for await result in group {
                collected.append(result)
            }

            let order = Dictionary(uniqueKeysWithValues: DNSProbeTarget.all.enumerated().map { ($1.id, $0) })
            return collected.sorted { (order[$0.target.id] ?? 999) < (order[$1.target.id] ?? 999) }
        }
    }

    private func probe(
        target: DNSProbeTarget,
        update: @escaping @Sendable (DNSProbeResult) -> Void
    ) async -> DNSProbeResult {
        update(DNSProbeResult(target: target))

        return await withCheckedContinuation { continuation in
            let operation = DNSPingOperation(
                target: target,
                attemptCount: attemptCount,
                update: update,
                continuation: continuation
            )

            do {
                var configuration = PingConfiguration(interval: 0.35, with: 1.5)
                configuration.handleBackgroundTransitions = false
                configuration.payloadSize = 32
                configuration.haltAfterTarget = true

                let pinger = try SwiftyPing(
                    ipv4Address: target.address,
                    config: configuration,
                    queue: callbackQueue
                )
                operation.attach(pinger)
                pinger.targetCount = attemptCount
                pinger.observer = { response in
                    operation.record(response)
                }
                pinger.finished = { result in
                    operation.finish(with: result)
                }
                try pinger.startPinging()
            } catch {
                operation.fail(error)
            }
        }
    }
}

private final class DNSPingOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let target: DNSProbeTarget
    private let attemptCount: Int
    private let update: @Sendable (DNSProbeResult) -> Void
    private var continuation: CheckedContinuation<DNSProbeResult, Never>?
    private var pinger: SwiftyPing?
    private var samples: [DNSProbeSample] = []
    private var completed = false

    init(
        target: DNSProbeTarget,
        attemptCount: Int,
        update: @escaping @Sendable (DNSProbeResult) -> Void,
        continuation: CheckedContinuation<DNSProbeResult, Never>
    ) {
        self.target = target
        self.attemptCount = attemptCount
        self.update = update
        self.continuation = continuation
    }

    func attach(_ pinger: SwiftyPing) {
        lock.lock()
        self.pinger = pinger
        lock.unlock()
    }

    func record(_ response: PingResponse) {
        lock.lock()
        guard !completed, samples.count < attemptCount else {
            lock.unlock()
            return
        }
        let sample = makeSample(response, attempt: samples.count + 1)
        samples.append(sample)
        let snapshot = DNSProbeResult(target: target, samples: samples)
        lock.unlock()
        update(snapshot)
    }

    func finish(with result: PingResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }

        var finalSamples = result.responses.enumerated().prefix(attemptCount).map { index, response in
            makeSample(response, attempt: index + 1)
        }
        while finalSamples.count < attemptCount {
            finalSamples.append(DNSProbeSample(
                attempt: finalSamples.count + 1,
                success: false,
                latencyMilliseconds: nil,
                error: "ICMP 响应超时"
            ))
        }

        completed = true
        samples = finalSamples
        let finalResult = DNSProbeResult(target: target, samples: finalSamples)
        let savedContinuation = continuation
        continuation = nil
        pinger = nil
        lock.unlock()

        update(finalResult)
        savedContinuation?.resume(returning: finalResult)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }

        let message = String(describing: error)
        let failedSamples = (1...attemptCount).map {
            DNSProbeSample(attempt: $0, success: false, latencyMilliseconds: nil, error: message)
        }
        completed = true
        samples = failedSamples
        let result = DNSProbeResult(target: target, samples: failedSamples)
        let savedContinuation = continuation
        continuation = nil
        pinger = nil
        lock.unlock()

        update(result)
        savedContinuation?.resume(returning: result)
    }

    private func makeSample(_ response: PingResponse, attempt: Int) -> DNSProbeSample {
        let success = response.error == nil
        return DNSProbeSample(
            attempt: attempt,
            success: success,
            latencyMilliseconds: success ? response.duration * 1_000 : nil,
            error: response.error.map { String(describing: $0) }
        )
    }
}
