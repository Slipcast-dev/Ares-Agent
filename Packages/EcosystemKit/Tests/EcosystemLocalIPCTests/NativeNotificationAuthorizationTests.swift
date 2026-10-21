import UserNotifications
import XCTest
@testable import EcosystemLocalIPC

/// Проверяем пользовательский смысл статусов, не запрашивая разрешение macOS.
/// Вызов UNUserNotificationCenter здесь недопустим: unit-тест не является
/// согласием пользователя и не доказывает появление системного баннера.
final class NativeNotificationAuthorizationTests: XCTestCase {
    func testFullAuthorizationReportsAuthorized() {
        XCTAssertEqual(NativeLocalNotifications.authorizationState(for: .authorized), "authorized")
    }

    func testProvisionalPermissionDoesNotClaimFullAlertAuthorization() {
        let quiet = NativeLocalNotifications.authorizationState(for: .provisional)
        XCTAssertEqual(quiet, "provisional")
        XCTAssertNotEqual(quiet, NativeLocalNotifications.authorizationState(for: .authorized))
    }

    func testDeniedAndUndeterminedRemainDifferentFromGrantedStates() {
        let denied = NativeLocalNotifications.authorizationState(for: .denied)
        let undetermined = NativeLocalNotifications.authorizationState(for: .notDetermined)
        XCTAssertEqual(denied, "denied")
        XCTAssertEqual(undetermined, "notDetermined")
        XCTAssertEqual(Set([denied, undetermined,
                            NativeLocalNotifications.authorizationState(for: .authorized),
                            NativeLocalNotifications.authorizationState(for: .provisional)]).count, 4)
    }
}
