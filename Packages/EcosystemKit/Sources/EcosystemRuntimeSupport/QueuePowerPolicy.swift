import Foundation
import IOKit.ps

/// Категория задаётся только реестром runtime. Параметры внешнего клиента не
/// могут превратить полный файловый обход в дешёвую диагностику.
public enum QueueWorkload: Sendable { case light, heavy }

/// Снимок состояния нужен только перед новым admission. Принятый callback не
/// замораживается и не перезапускается при смене питания или thermal state.
public struct QueuePowerState: Sendable {
    public let onBattery: Bool?
    public let lowPower: Bool
    public let thermallyConstrained: Bool
    public init(onBattery: Bool?, lowPower: Bool, thermallyConstrained: Bool) {
        self.onBattery = onBattery; self.lowPower = lowPower
        self.thermallyConstrained = thermallyConstrained
    }
    /// Неизвестный источник питания выбирает безопасный последовательный режим;
    /// неизвестность не откладывает работу: как минимум одна heavy запускается.
    public var limitsHeavyConcurrency: Bool { onBattery != false || lowPower || thermallyConstrained }

    public static func current() -> Self {
        let process = ProcessInfo.processInfo
        var battery: Bool?
        // IOKit возвращает snapshot без shell/субпроцесса и без записи настроек.
        // Copy передаёт владение вызывающему; Get возвращает borrowed CFString.
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            if source == kIOPSBatteryPowerValue { battery = true }
            else if source == kIOPSACPowerValue { battery = false }
        }
        let thermal: Bool
        switch process.thermalState {
        case .nominal: thermal = false
        case .fair, .serious, .critical: thermal = true
        @unknown default: thermal = true
        }
        return Self(onBattery: battery, lowPower: process.isLowPowerModeEnabled, thermallyConstrained: thermal)
    }
}
