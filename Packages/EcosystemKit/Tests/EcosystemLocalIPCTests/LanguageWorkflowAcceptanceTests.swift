import Foundation
import XCTest
import EcosystemLocalization
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

/// Управляемое время исключает sleep/таймеры и позволяет проверить fencing
/// после смены языка на действительно просроченном lease, а не на имитации.
private final class LanguageAcceptanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds)
    }
}

final class LanguageWorkflowAcceptanceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/language-acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    private func preferenceBytes(in directory: URL) throws -> Data? {
        let file = directory.appendingPathComponent("language-v1.json")
        // System в старом профиле не обязан создавать sidecar: отсутствие файла
        // является валидным снимком, ошибки чтения существующего файла не скрываем.
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }

    func testAllSixDomainSettingsRemainIndependentAcrossNineChoicePairsAndRestart() async throws {
        let ares = try directory(), athena = try directory()
        defer { try? FileManager.default.removeItem(at: ares); try? FileManager.default.removeItem(at: athena) }
        let a = try LocalLanguagePreferences(directory: ares, domain: "ares", preferredLanguages: { ["ru_RU"] })
        let b = try LocalLanguagePreferences(directory: athena, domain: "athena", preferredLanguages: { ["en-GB"] })
        for first in AgentLanguagePreference.allCases {
            let previousB = try preferenceBytes(in: athena)
            _ = try await a.set(first)
            XCTAssertEqual(try preferenceBytes(in: athena), previousB)
            let aBytes = try preferenceBytes(in: ares)
            for second in AgentLanguagePreference.allCases {
                _ = try await b.set(second)
                let aStatus = await a.status(), bStatus = await b.status()
                XCTAssertEqual(aStatus.preference, first)
                XCTAssertEqual(bStatus.preference, second)
                XCTAssertEqual(aStatus.effectiveLanguage, first == .en ? .english : .russian)
                XCTAssertEqual(bStatus.effectiveLanguage, second == .ru ? .russian : .english)
                XCTAssertEqual(try preferenceBytes(in: ares), aBytes)
                let restoredA = try LocalLanguagePreferences(directory: ares, domain: "ares", preferredLanguages: { ["ru_RU"] })
                let restoredB = try LocalLanguagePreferences(directory: athena, domain: "athena", preferredLanguages: { ["en-GB"] })
                let savedA = await restoredA.status(), savedB = await restoredB.status()
                XCTAssertEqual(savedA, aStatus)
                XCTAssertEqual(savedB, bStatus)
            }
        }
    }

    func testBothDomainsKeepInFlightMutationAndReceiptWhenLanguageChangesThenFenceExpiry() async throws {
        for domain in ["ares", "athena"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let agent: AgentID = domain == "ares" ? .ares : .athena
            let clock = LanguageAcceptanceClock()
            let queue = try DurableTaskQueue(directory: root.appendingPathComponent("queue"), agentID: agent, clock: { clock.now() })
            let language = try LocalLanguagePreferences(directory: root, domain: domain, preferredLanguages: { ["ru-RU"] })
            let request = try TaskRequest(requestID: UUID(), agentID: agent,
                capabilityID: domain == "ares" ? "rule.run" : "monitor.create", parameters: ["sample": 1],
                origin: .user, idempotencyKey: "language-accepted-mutation", rootID: UUID(),
                createdAt: UTCTimestamp("2027-01-15T08:00:00Z"))
            // Admission здесь доверенный: доменные grants/plan approval этим
            // storage-тестом не выдаются и проверяются отдельными domain suites.
            let submission = try QueueSubmission(request: request, resources: ["fixture.resource"], mutating: true)
            let accepted = try await queue.accept(submission)
            let lease = try await queue.claim(accepted.id, leaseSeconds: 5)
            let summary = "История %@ 100% 😀"
            let receipt = try await queue.beginReceipt(lease, actionKey: "fixture.effect", summary: summary)
            let before = try await queue.task(accepted.id)
            let beforeBytes = try LocalWire.encode(XCTUnwrap(before))
            for choice in AgentLanguagePreference.allCases {
                _ = try await language.set(choice)
                let after = try await queue.task(accepted.id)
                XCTAssertEqual(try LocalWire.encode(XCTUnwrap(after)), beforeBytes)
                try await queue.checkpoint(lease)
                let receiptValues = try await queue.receipts(accepted.id)
                XCTAssertEqual(receiptValues.map(\.id), [receipt.id])
                XCTAssertEqual(receiptValues.first?.summary, summary)
                XCTAssertEqual(receiptValues.first?.state, .started)
            }
            clock.advance(6)
            try await queue.recoverExpiredLeases()
            _ = try await language.set(.en)
            let quarantined = try await queue.task(accepted.id)
            XCTAssertEqual(quarantined?.status, .recoveryRequired)
            XCTAssertEqual(quarantined?.fingerprint, accepted.fingerprint)
            XCTAssertEqual(quarantined?.request, accepted.request)
            XCTAssertNil(quarantined?.result)
            let reserved = try await queue.hasReservation("fixture.resource")
            XCTAssertTrue(reserved)
            do {
                _ = try await queue.finish(lease, status: .completed, result: Data("false success".utf8))
                XCTFail("Language change revived a stale writer in \(domain)")
            } catch { XCTAssertEqual(error as? QueueFailure, .staleLease) }
            let duplicate = try await queue.accept(submission)
            XCTAssertEqual(duplicate.id, accepted.id)
            XCTAssertEqual(duplicate.status, .recoveryRequired)
            let receipts = try await queue.receipts(accepted.id)
            XCTAssertEqual(receipts.map(\.id), [receipt.id])
            XCTAssertEqual(receipts.first?.summary, summary)
            XCTAssertEqual(receipts.first?.fencingToken, lease.fencingToken)
            XCTAssertEqual(receipts.first?.state, .started)
        }
    }
}
