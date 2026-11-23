import Foundation
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import BKBackend
import BKModel

/// 导入账单选的文件读成 `StatementDocument`（ADR 0029）：PDF 用 PDFKit 取每个字和位置，图片用 Vision 识别，
/// 表格文件交给 `StatementReaders`。模板文件（.json）不在这里读，原样交给 `LedgerBackend.installStatementTemplates`。
/// 都在后台队列上做，不占主线程；不联网，读完不留文件。
enum StatementFileReader {
    enum Content: Sendable {
        case statement(StatementDocument)
        case template(Data)
        /// PDF 上了锁，要密码
        case locked
    }

    enum ReadError: LocalizedError {
        case unsupported
        case unreadable
        case wrongPassword

        var errorDescription: String? {
            switch self {
            case .unsupported: L("不认识这种文件")
            case .unreadable: L("读不了这个文件")
            case .wrongPassword: L("密码不对")
            }
        }
    }

    /// 选文件时能选的类型
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .plainText, .json, .image, .spreadsheet]
        for ext in ["xlsx", "xls", "csv"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    private static let queue = DispatchQueue(label: "rec.statement-reader", qos: .userInitiated)

    /// 读一个文件。PDF 上了锁、没给密码时返回 `.locked`；密码不对抛 `wrongPassword`
    static func read(_ data: Data, name: String, password: String? = nil) async throws -> Content {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try readNow(data, name: name, password: password))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readNow(_ data: Data, name: String, password: String?) throws -> Content {
        let ext = (name as NSString).pathExtension.lowercased()
        let bytes = [UInt8](data.prefix(8))
        if ext == "pdf" || bytes.starts(with: Array("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { throw ReadError.unreadable }
            if document.isLocked {
                guard let password, !password.isEmpty else { return .locked }
                guard document.unlock(withPassword: password) else { throw ReadError.wrongPassword }
            }
            return .statement(StatementDocument(name: name, kind: .pdf, content: .pages(pdfPages(document))))
        }
        switch ext {
        case "json":
            return .template(data)
        case "csv", "txt":
            guard let text = StatementText.decode(data) else { throw ReadError.unreadable }
            return .statement(StatementDocument(name: name, kind: .csv, content: .grid(StatementReaders.csv(text))))
        case "xlsx":
            return .statement(StatementDocument(name: name, kind: .xlsx, content: .grid(try StatementReaders.xlsx(data))))
        case "xls":
            return .statement(StatementDocument(name: name, kind: .xls, content: .grid(try StatementReaders.xls(data))))
        default:
            if UTType(filenameExtension: ext)?.conforms(to: .image) == true || CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0 > 0 {
                return .statement(StatementDocument(name: name, kind: .image, content: .pages([try imageFragments(data)])))
            }
            throw ReadError.unsupported
        }
    }

    // MARK: PDF

    /// 每页的字：按空白和间隔切成一段段，位置按页面大小换成 0…1（原点左上角，转过的页面按显示的方向）。
    /// 斜着、竖着写的字（水印）不要：同一段字里相邻两个字上下错开
    static func pdfPages(_ document: PDFDocument) -> [[ScreenTextLine]] {
        (0..<document.pageCount).map { index -> [ScreenTextLine] in
            guard let page = document.page(at: index), let text = page.string else { return [] }
            let transform = page.transform(for: .cropBox)
            let box = page.bounds(for: .cropBox).applying(transform).standardized
            guard box.width > 0, box.height > 0 else { return [] }
            let ns = text as NSString
            var glyphs: [(text: String, rect: CGRect)] = []
            var location = 0
            while location < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: location)
                location = range.location + range.length
                let character = ns.substring(with: range)
                if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    glyphs.append((text: " ", rect: CGRect.null))
                    continue
                }
                let rect = page.characterBounds(at: range.location).applying(transform).standardized
                // 没有位置的字（隐藏的、零宽的）当空白
                glyphs.append(rect.width <= 0 && rect.height <= 0 ? (text: " ", rect: CGRect.null) : (text: character, rect: rect))
            }
            // 斜着排的字：连着三个字都往同一边上下错开（不是换行，也不是同一行里大小不一样的字）
            func step(_ i: Int) -> Double? {
                guard i + 1 < glyphs.count else { return nil }
                let a = glyphs[i].rect, b = glyphs[i + 1].rect
                guard !a.isNull, !b.isNull, a.height > 0 else { return nil }
                let dy = b.midY - a.midY, dx = b.minX - a.maxX
                guard abs(dy) > a.height * 0.2, abs(dy) < a.height * 2, dx > -a.height * 0.3, dx < a.height * 1.5 else { return nil }
                return dy
            }
            var slanted = Set<Int>()
            for i in glyphs.indices {
                guard let first = step(i), let second = step(i + 1), (first > 0) == (second > 0) else { continue }
                slanted.formUnion([i, i + 1, i + 2])
            }
            var fragments: [ScreenTextLine] = []
            var word: [(String, CGRect)] = []
            func flush() {
                defer { word = [] }
                guard !word.isEmpty else { return }
                let union = word.dropFirst().reduce(word[0].1) { $0.union($1.1) }
                fragments.append(ScreenTextLine(
                    text: word.map { $0.0 }.joined(),
                    x: (union.minX - box.minX) / box.width, y: (box.maxY - union.maxY) / box.height,
                    width: union.width / box.width, height: union.height / box.height
                ))
            }
            for (index, glyph) in glyphs.enumerated() {
                if glyph.rect.isNull || slanted.contains(index) {
                    flush()
                    continue
                }
                if let last = word.last?.1 {
                    let height = max(last.height, glyph.rect.height)
                    // 不在同一行、隔得远、往回走了：另起一段
                    if abs(glyph.rect.midY - last.midY) > height * 0.5 || glyph.rect.minX - last.maxX > height * 0.6 || glyph.rect.minX < last.minX - 1 {
                        flush()
                    }
                }
                word.append((glyph.text, glyph.rect))
            }
            flush()
            return fragments
        }
    }

    // MARK: 图片

    /// 截图、拍的账单：Vision 认字，按空白切成一段段，用每段自己的框
    static func imageFragments(_ data: Data) throws -> [ScreenTextLine] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        // 账单上多是数字、名称：不按语言纠正，免得把卡号、金额「改对」
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var fragments: [ScreenTextLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var start = text.startIndex
            while start < text.endIndex {
                while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
                guard start < text.endIndex else { break }
                var end = start
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                let box = (try? candidate.boundingBox(for: start..<end))?.boundingBox ?? observation.boundingBox
                fragments.append(ScreenTextLine(
                    text: String(text[start..<end]), x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height
                ))
                start = end
            }
        }
        return fragments
    }
}
