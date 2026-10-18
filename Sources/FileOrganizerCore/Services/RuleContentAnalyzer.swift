import Darwin
import Foundation
import PDFKit
import Vision

/// Локальный анализ ограничен размером и явным consent-флагом. Извлечённый текст
/// используется только в памяти; SQLite и история получают булев результат.
public actor RuleContentAnalyzer {
    public init() {}
    public func matches(url: URL, event: RuleEvent, value: String, consent: Bool) throws -> Bool {
        guard consent else { throw RuleExecutionError.contentConsentRequired }
        // Foundation иногда оставляет системный alias /var после resolvingSymlinks.
        // Совместимый URL API получает физический путь через realpath. Runtime
        // вызывает matchesVerified напрямую с уже выданным bookmark-root.
        guard let physical = realpath(url.deletingLastPathComponent().path, nil) else { throw AresFileFailure.unsafePath }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let version = try VerifiedFileReader.capture(root: root, relative: url.lastPathComponent)
        return try matchesVerified(root: root, relative: url.lastPathComponent, expected: version, event: event, value: value, consent: consent)
    }
    public func matchesVerified(root: URL, relative: String, expected: FileVersion, event: RuleEvent, value: String, consent: Bool) throws -> Bool {
        guard consent else { throw RuleExecutionError.contentConsentRequired }
        guard !value.isEmpty else { throw RuleExecutionError.invalidConfiguration }
        guard expected.byteSize <= 10_000_000 else { return false }
        let fileExtension = (relative as NSString).pathExtension.lowercased()
        if event == .imageText {
            guard ["png", "jpg", "jpeg", "heic", "tiff"].contains(fileExtension) else { return false }
        } else {
            guard ["pdf", "txt", "md", "csv", "json", "log", "xml", "html"].contains(fileExtension) else { return false }
        }
        let data = try VerifiedFileReader.data(root: root, relative: relative, expected: expected)
        let text: String
        if event == .imageText {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } else if fileExtension == "pdf" {
            guard let pdf = PDFDocument(data: data) else { return false }
            text = (0..<min(pdf.pageCount, 50)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }
        if event == .documentType {
            // Классификация эвристическая: интерфейс сообщает ограничение и не
            // выдаёт совпадение ключевых слов за достоверное распознавание типа.
            let vocabulary = ["счёт": ["счёт", "счет", "invoice"], "договор": ["договор", "contract", "agreement"], "чек": ["кассовый чек", "receipt", "итого"]]
            return (vocabulary[value.lowercased()] ?? [value]).contains { text.localizedCaseInsensitiveContains($0) }
        }
        return text.localizedCaseInsensitiveContains(value)
    }
}
