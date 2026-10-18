import Foundation

/// Известные v1 коды перечислены централизованно. Wire code остаётся String,
/// чтобы новый minor мог добавить код без потери исходного значения клиентом.
public enum KnownErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT", unknownCapability = "UNKNOWN_CAPABILITY"
    case incompatibleVersion = "INCOMPATIBLE_VERSION", permissionDenied = "PERMISSION_DENIED"
    case approvalRequired = "APPROVAL_REQUIRED", grantRevoked = "GRANT_REVOKED"
    case rootUnavailable = "ROOT_UNAVAILABLE", staleBookmark = "STALE_BOOKMARK"
    case resourceBusy = "RESOURCE_BUSY", staleSnapshot = "STALE_SNAPSHOT"
    case planExpired = "PLAN_EXPIRED", taskNotFound = "TASK_NOT_FOUND"
    case deadlineExceeded = "DEADLINE_EXCEEDED", cancelled = "CANCELLED"
    case partialResult = "PARTIAL_RESULT", recoveryRequired = "RECOVERY_REQUIRED"
    case storageFull = "STORAGE_FULL", clientUnavailable = "CLIENT_UNAVAILABLE"
    case internalError = "INTERNAL_ERROR"
}
