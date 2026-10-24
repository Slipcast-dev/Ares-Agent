import Foundation
import XCTest
import FileOrganizerCore
import EcosystemLocalIPC
@testable import FileOrganizerMCP

/// Тестируем реальные Encoder/JSONSerialization и публичные модели без IPC,
/// папок пользователя и разрешений: ошибка формы возникает до отправки RPC.
final class RuleMCPNormalizationTests: XCTestCase {
    private struct FailingModel: Encodable {
        enum EncodingFailure: Error { case expected }
        func encode(to encoder: Encoder) throws { throw EncodingFailure.expected }
    }

    func testAutomationRuleDefaultsRoundTripWithoutLosingPermissionFlags() throws {
        let rule = AutomationRule()
        let object = try RuleMCP.encodedModelObject(rule)
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AutomationRule.self, from: data), rule)
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual(object["allowContentReading"] as? Bool, false)
    }

    func testActionAndConditionDefaultsRemainObjects() throws {
        let action = RuleAction(kind: .log)
        let conditions = RuleConditions()
        let actionData = try JSONSerialization.data(withJSONObject: RuleMCP.encodedModelObject(action))
        let conditionData = try JSONSerialization.data(withJSONObject: RuleMCP.encodedModelObject(conditions))
        XCTAssertEqual(try JSONDecoder().decode(RuleAction.self, from: actionData), action)
        XCTAssertEqual(try JSONDecoder().decode(RuleConditions.self, from: conditionData), conditions)
    }

    func testArrayResultReturnsOperationFailedInsteadOfCrashing() {
        XCTAssertThrowsError(try RuleMCP.encodedModelObject([1, 2])) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .operationFailed)
        }
    }

    func testScalarAndNullResultsReturnOperationFailed() {
        XCTAssertThrowsError(try RuleMCP.encodedModelObject("unexpected")) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .operationFailed)
        }
        XCTAssertThrowsError(try RuleMCP.encodedModelObject(42)) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .operationFailed)
        }
        XCTAssertThrowsError(try RuleMCP.encodedModelObject(Optional<String>.none)) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .operationFailed)
        }
    }

    func testEncoderFailureBecomesOperationFailedAndNextCallStillSucceeds() throws {
        XCTAssertThrowsError(try RuleMCP.encodedModelObject(FailingModel())) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .operationFailed)
        }
        XCTAssertEqual(try RuleMCP.encodedModelObject(["value": 7])["value"] as? Int, 7)
    }
}
