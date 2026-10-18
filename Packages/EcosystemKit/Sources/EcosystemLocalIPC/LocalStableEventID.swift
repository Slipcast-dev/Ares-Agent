import CryptoKit
import Foundation

public enum LocalStableEventID {
    /// Производный UUID одинаков после перезапуска и не раскрывает исходный путь.
    public static func make(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
