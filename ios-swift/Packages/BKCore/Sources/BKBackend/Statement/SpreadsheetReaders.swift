import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 把账单文件读成一格一格的表（ADR 0029）。CSV、xlsx、老的 xls 都在这里读；PDF、图片的文字由 App 读出来（PDFKit、Vision），
/// 交过来的是每一段字和它在页面上的位置（`StatementContent.pages`）。
public enum StatementReaders {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable
        /// 文件里没有表（xlsx 没有工作表）
        case empty
    }

    // MARK: CSV

    /// CSV 的文字（App 已经按 UTF-8、GB18030 解码好）。引号里的逗号、换行照常处理；每格去掉首尾空白（支付宝的单号后面带制表符）
    public static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        func finishCell() {
            row.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
            cell = ""
        }
        func finishRow() {
            finishCell()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while let scalar = pending {
            pending = iterator.next()
            if quoted {
                if scalar == "\"" {
                    if pending == "\"" {
                        cell.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    cell.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where cell.trimmingCharacters(in: .whitespaces).isEmpty:
                cell = ""
                quoted = true
            case ",":
                finishCell()
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                finishRow()
            case "\n":
                finishRow()
            case "\u{FEFF}" where rows.isEmpty && row.isEmpty && cell.isEmpty:
                continue
            default:
                cell.unicodeScalars.append(scalar)
            }
        }
        if !cell.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }

    // MARK: xlsx

    /// 第一个工作表。日期格式的数字换成「yyyy-MM-dd HH:mm:ss」（只有日期的是「yyyy-MM-dd」）
    public static func xlsx(_ data: Data) throws -> [[String]] {
        let files: [String: Data]
        do {
            files = try ZipReader.files(data)
        } catch {
            throw Failure.unreadable
        }
        let sheetPath = firstSheetPath(files) ?? "xl/worksheets/sheet1.xml"
        guard let sheet = files[sheetPath] else { throw Failure.empty }
        let shared = files["xl/sharedStrings.xml"].map(SharedStrings.parse) ?? []
        let dateStyles = files["xl/styles.xml"].map(DateStyles.parse) ?? [:]
        return try SheetCells.parse(sheet, shared: shared, dateStyles: dateStyles)
    }

    private static func firstSheetPath(_ files: [String: Data]) -> String? {
        guard let workbook = files["xl/workbook.xml"], let rels = files["xl/_rels/workbook.xml.rels"] else { return nil }
        let sheetID = XMLScan.attributes(workbook, element: "sheet").first?["r:id"]
        guard let sheetID else { return nil }
        guard let target = XMLScan.attributes(rels, element: "Relationship").first(where: { $0["Id"] == sheetID })?["Target"] else { return nil }
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        return "xl/" + target
    }

    // MARK: xls

    /// 老的 Excel（BIFF8，Excel 97–2003）。银行导出的「.xls」有的其实是网页或 xlsx，按文件开头认
    public static func xls(_ data: Data) throws -> [[String]] {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try xlsx(data) }
        guard let workbook = CompoundFile.stream(bytes, names: ["Workbook", "Book"]) else { throw Failure.unreadable }
        return try BIFF.firstSheet(workbook)
    }

    /// 数字写成文字：整数不带小数点，其余去掉浮点误差（0.1 + 0.2 那种）
    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Excel 的日期数字（从 1899-12-30 起的天数）
    static func excelDate(_ serial: Double, withTime: Bool) -> String {
        let totalSeconds = Int((serial * 86_400).rounded())
        var days = totalSeconds / 86_400
        let seconds = totalSeconds % 86_400
        // 从 1899-12-30 往后数天
        var year = 1899, month = 12, day = 30
        func daysIn(_ y: Int, _ m: Int) -> Int {
            switch m {
            case 2: (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
            }
        }
        while days > 0 {
            let left = daysIn(year, month) - day
            if days <= left {
                day += days
                days = 0
            } else {
                days -= left + 1
                day = 1
                month += 1
                if month > 12 {
                    month = 1
                    year += 1
                }
            }
        }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard withTime else { return date }
        return date + String(format: " %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

// MARK: - xlsx 的几个 XML

/// 只取元素的属性
private enum XMLScan {
    final class Collector: NSObject, XMLParserDelegate {
        let element: String
        var found: [[String: String]] = []
        init(element: String) { self.element = element }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == element || qualifiedName == element { found.append(attributes) }
        }
    }

    static func attributes(_ data: Data, element: String) -> [[String: String]] {
        let collector = Collector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.found
    }
}

private enum SharedStrings {
    final class Collector: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inText = false
        var inItem = false
        /// 注音（<rPh>）里的字不要
        var inPhonetic = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "si":
                inItem = true
                current = ""
            case "t" where inItem && !inPhonetic: inText = true
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si":
                strings.append(current)
                inItem = false
            case "t": inText = false
            case "rPh": inPhonetic = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }
    }

    static func parse(_ data: Data) -> [String] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.strings
    }
}

/// 第几个单元格样式是日期（true）、日期加时间（也是 true，`withTime` 另算）
private enum DateStyles {
    struct Style { var date: Bool; var time: Bool }

    final class Collector: NSObject, XMLParserDelegate {
        var formats: [Int: String] = [:]
        var styles: [Int] = []
        var inCellXfs = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "numFmt":
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { formats[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf" where inCellXfs: styles.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellXfs = false }
        }
    }

    static func parse(_ data: Data) -> [Int: Style] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        var result: [Int: Style] = [:]
        for (index, formatID) in collector.styles.enumerated() {
            if let style = style(formatID, code: collector.formats[formatID]) { result[index] = style }
        }
        return result
    }

    /// 内置的日期格式：14–17 日期，18–21 时间，22 日期加时间，45–47 时间
    static func style(_ id: Int, code: String?) -> Style? {
        switch id {
        case 14...17: return Style(date: true, time: false)
        case 18...21, 45...47: return Style(date: false, time: true)
        case 22: return Style(date: true, time: true)
        default: break
        }
        guard var code = code?.lowercased() else { return nil }
        // 去掉引号里的字和 [颜色] 这类
        code = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
        code = code.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        let date = code.contains("y") || code.contains("d")
        let time = code.contains("h") || code.contains("s")
        return date || time ? Style(date: date, time: time) : nil
    }
}

private enum SheetCells {
    final class Collector: NSObject, XMLParserDelegate {
        let shared: [String]
        let dateStyles: [Int: DateStyles.Style]
        var cells: [(row: Int, column: Int, text: String)] = []
        var reference = ""
        var type = ""
        var style = 0
        var value = ""
        var inValue = false
        var inInline = false
        var nextRow = 1
        var rowNumber = 1

        init(shared: [String], dateStyles: [Int: DateStyles.Style]) {
            self.shared = shared
            self.dateStyles = dateStyles
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                rowNumber = attributes["r"].flatMap(Int.init) ?? nextRow
                nextRow = rowNumber + 1
            case "c":
                reference = attributes["r"] ?? ""
                type = attributes["t"] ?? ""
                style = attributes["s"].flatMap(Int.init) ?? 0
                value = ""
            case "v": inValue = true
            case "is": inInline = true
            case "t" where inInline: inValue = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "is": inInline = false
            case "c":
                let column = Self.column(reference) ?? (cells.last.map { $0.row == rowNumber ? $0.column + 1 : 0 } ?? 0)
                cells.append((rowNumber, column, text()))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string }
        }

        private func text() -> String {
            switch type {
            case "s": return Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
            case "inlineStr", "str", "e": return value
            case "b": return value == "1" ? "TRUE" : "FALSE"
            default:
                guard let number = Double(value) else { return value }
                if let date = dateStyles[style], date.date {
                    return StatementReaders.excelDate(number, withTime: date.time && number != number.rounded())
                }
                return StatementReaders.numberText(number)
            }
        }

        /// 「AB12」的列：A 是 0
        static func column(_ reference: String) -> Int? {
            var column = 0
            var seen = false
            for scalar in reference.unicodeScalars {
                guard ("A"..."Z").contains(scalar) else { break }
                column = column * 26 + Int(scalar.value - 64)
                seen = true
            }
            return seen ? column - 1 : nil
        }
    }

    static func parse(_ data: Data, shared: [String], dateStyles: [Int: DateStyles.Style]) throws -> [[String]] {
        let collector = Collector(shared: shared, dateStyles: dateStyles)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw StatementReaders.Failure.unreadable }
        guard let lastRow = collector.cells.map(\.row).max() else { return [] }
        let width = (collector.cells.map(\.column).max() ?? 0) + 1
        guard width <= 200, lastRow <= 200_000 else { throw StatementReaders.Failure.unreadable }
        var grid = [[String]](repeating: [String](repeating: "", count: width), count: lastRow)
        for cell in collector.cells where cell.row >= 1 {
            grid[cell.row - 1][cell.column] = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grid.filter { $0.contains { !$0.isEmpty } }
    }
}

// MARK: - xls：复合文档里的 Workbook 流

/// OLE 复合文档（.xls 外面那层）：按 FAT 链取出一个流
private enum CompoundFile {
    static func stream(_ bytes: [UInt8], names: [String]) -> [UInt8]? {
        guard bytes.count >= 512, bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        func le16(_ i: Int) -> Int { i + 1 < bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : 0 }
        func le32(_ i: Int) -> Int { le16(i) | le16(i + 2) << 16 }
        let sectorSize = 1 << le16(30)
        let miniSectorSize = 1 << le16(32)
        guard sectorSize == 512 || sectorSize == 4096, miniSectorSize == 64 else { return nil }
        let directoryStart = le32(48)
        let miniCutoff = le32(56)
        let miniFATStart = le32(60)
        let difatStart = le32(68)
        let difatCount = le32(72)
        func offset(_ sector: Int) -> Int { (sector + 1) * sectorSize }

        // FAT 扇区：头里 109 个，其余在 DIFAT 链里
        var fatSectors: [Int] = []
        for i in 0..<109 {
            let sector = le32(76 + i * 4)
            if sector >= 0, sector < 0xFFFF_FFFA { fatSectors.append(sector) }
        }
        var difat = difatStart
        var guardCount = 0
        while difat >= 0, difat < 0xFFFF_FFFA, guardCount < difatCount + 1 {
            let base = offset(difat)
            guard base + sectorSize <= bytes.count else { return nil }
            for i in 0..<(sectorSize / 4 - 1) {
                let sector = le32(base + i * 4)
                if sector < 0xFFFF_FFFA { fatSectors.append(sector) }
            }
            difat = le32(base + sectorSize - 4)
            guardCount += 1
        }
        var fat: [Int] = []
        for sector in fatSectors {
            let base = offset(sector)
            guard base + sectorSize <= bytes.count else { return nil }
            for i in 0..<(sectorSize / 4) { fat.append(le32(base + i * 4)) }
        }
        func chain(_ start: Int, in table: [Int]) -> [Int] {
            var sectors: [Int] = []
            var sector = start
            while sector >= 0, sector < table.count, sectors.count <= table.count {
                sectors.append(sector)
                sector = table[sector]
            }
            return sectors
        }
        func read(_ start: Int) -> [UInt8] {
            var out: [UInt8] = []
            for sector in chain(start, in: fat) {
                let base = offset(sector)
                guard base + sectorSize <= bytes.count else { break }
                out.append(contentsOf: bytes[base..<(base + sectorSize)])
            }
            return out
        }

        let directory = read(directoryStart)
        var entries: [(name: String, type: Int, start: Int, size: Int)] = []
        var position = 0
        while position + 128 <= directory.count {
            let nameLength = Int(directory[position + 64]) | Int(directory[position + 65]) << 8
            var units: [UInt16] = []
            if nameLength >= 2 {
                for i in stride(from: 0, to: min(nameLength - 2, 62), by: 2) {
                    units.append(UInt16(directory[position + i]) | UInt16(directory[position + i + 1]) << 8)
                }
            }
            let start = Int(directory[position + 116]) | Int(directory[position + 117]) << 8 | Int(directory[position + 118]) << 16 | Int(directory[position + 119]) << 24
            let size = Int(directory[position + 120]) | Int(directory[position + 121]) << 8 | Int(directory[position + 122]) << 16 | Int(directory[position + 123]) << 24
            entries.append((String(decoding: units, as: UTF16.self), Int(directory[position + 66]), start, size))
            position += 128
        }
        guard let root = entries.first(where: { $0.type == 5 }),
              let entry = entries.first(where: { names.contains($0.name) && $0.type == 2 }) else { return nil }
        if entry.size < miniCutoff {
            // 小于 4096 字节的流在迷你流里
            let miniStream = read(root.start)
            let miniFATBytes = read(miniFATStart)
            var miniFAT: [Int] = []
            for i in stride(from: 0, to: miniFATBytes.count - 3, by: 4) {
                miniFAT.append(Int(miniFATBytes[i]) | Int(miniFATBytes[i + 1]) << 8 | Int(miniFATBytes[i + 2]) << 16 | Int(miniFATBytes[i + 3]) << 24)
            }
            var out: [UInt8] = []
            for sector in chain(entry.start, in: miniFAT) {
                let base = sector * miniSectorSize
                guard base + miniSectorSize <= miniStream.count else { break }
                out.append(contentsOf: miniStream[base..<(base + miniSectorSize)])
            }
            return Array(out.prefix(entry.size))
        }
        return Array(read(entry.start).prefix(entry.size))
    }
}

/// BIFF8 的记录：只读第一个工作表里的文字和数字
private enum BIFF {
    static func firstSheet(_ stream: [UInt8]) throws -> [[String]] {
        func le16(_ i: Int) -> Int { Int(stream[i]) | Int(stream[i + 1]) << 8 }
        func le32(_ i: Int) -> Int { le16(i) | le16(i + 2) << 16 }

        // 先把记录切开；CONTINUE 接在前一条后面，但字符串表的续接要知道每段从哪开始
        var records: [(type: Int, body: [UInt8], continues: [[UInt8]], offset: Int)] = []
        var position = 0
        while position + 4 <= stream.count {
            let type = le16(position)
            let length = le16(position + 2)
            guard position + 4 + length <= stream.count else { break }
            let body = Array(stream[(position + 4)..<(position + 4 + length)])
            if type == 0x003C, !records.isEmpty {
                records[records.count - 1].continues.append(body)
            } else {
                records.append((type, body, [], position))
            }
            position += 4 + length
        }
        // 第一个工作表的位置（BOUNDSHEET），日期格式样式
        var sheetOffset: Int?
        var shared: [String] = []
        var formats: [Int: String] = [:]
        var xfFormats: [Int] = []
        for record in records {
            switch record.type {
            case 0x0085 where sheetOffset == nil && record.body.count >= 6:
                // 只要工作表（类型 0），不要图表、宏表
                if record.body[5] == 0 { sheetOffset = Int(record.body[0]) | Int(record.body[1]) << 8 | Int(record.body[2]) << 16 | Int(record.body[3]) << 24 }
            case 0x00FC:
                shared = sharedStrings(record.body, continues: record.continues)
            case 0x041E where record.body.count >= 5:
                let id = Int(record.body[0]) | Int(record.body[1]) << 8
                var reader = StringReader(segments: [Array(record.body[2...])])
                formats[id] = reader.string(lengthBytes: 2)
            case 0x00E0 where record.body.count >= 4:
                xfFormats.append(Int(record.body[2]) | Int(record.body[3]) << 8)
            default:
                break
            }
        }
        guard let sheetOffset, let start = records.firstIndex(where: { $0.offset == sheetOffset }) else { throw StatementReaders.Failure.empty }
        func isDate(_ xf: Int) -> (date: Bool, time: Bool)? {
            guard xf < xfFormats.count else { return nil }
            let id = xfFormats[xf]
            switch id {
            case 14...17: return (true, false)
            case 18...21, 45...47: return (false, true)
            case 22: return (true, true)
            default: break
            }
            guard var code = formats[id]?.lowercased() else { return nil }
            code = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
            code = code.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            let date = code.contains("y") || code.contains("d"), time = code.contains("h") || code.contains("s")
            return date || time ? (date, time) : nil
        }
        func number(_ value: Double, xf: Int) -> String {
            if let style = isDate(xf), style.date { return StatementReaders.excelDate(value, withTime: style.time && value != value.rounded()) }
            return StatementReaders.numberText(value)
        }
        var cells: [(row: Int, column: Int, text: String)] = []
        var pendingFormula: (row: Int, column: Int)?
        for record in records[(start + 1)...] {
            let body = record.body
            func u16(_ i: Int) -> Int { Int(body[i]) | Int(body[i + 1]) << 8 }
            switch record.type {
            case 0x000A: // EOF：工作表结束
                return grid(cells)
            case 0x00FD where body.count >= 10: // LABELSST
                let index = Int(body[6]) | Int(body[7]) << 8 | Int(body[8]) << 16 | Int(body[9]) << 24
                cells.append((u16(0), u16(2), index < shared.count ? shared[index] : ""))
            case 0x0204 where body.count >= 8: // LABEL
                var reader = StringReader(segments: [Array(body[6...])])
                cells.append((u16(0), u16(2), reader.string(lengthBytes: 2)))
            case 0x0203 where body.count >= 14: // NUMBER
                cells.append((u16(0), u16(2), number(double(body, 6), xf: u16(4))))
            case 0x027E where body.count >= 10: // RK
                cells.append((u16(0), u16(2), number(rk(body, 6), xf: u16(4))))
            case 0x00BD where body.count >= 6: // MULRK
                let row = u16(0)
                var column = u16(2)
                var i = 4
                while i + 6 <= body.count - 2 {
                    cells.append((row, column, number(rk(body, i + 2), xf: u16(i))))
                    column += 1
                    i += 6
                }
            case 0x0006 where body.count >= 20: // FORMULA：存的结果
                if body[12] == 0xFF, body[13] == 0xFF {
                    if body[6] == 0 { pendingFormula = (u16(0), u16(2)) } // 结果是文字，在后面的 STRING 里
                } else {
                    cells.append((u16(0), u16(2), number(double(body, 6), xf: u16(4))))
                }
            case 0x0207: // STRING
                if let target = pendingFormula {
                    var reader = StringReader(segments: [body] + record.continues)
                    cells.append((target.row, target.column, reader.string(lengthBytes: 2)))
                    pendingFormula = nil
                }
            default:
                break
            }
        }
        return grid(cells)
    }

    private static func grid(_ cells: [(row: Int, column: Int, text: String)]) -> [[String]] {
        guard let lastRow = cells.map(\.row).max(), let lastColumn = cells.map(\.column).max() else { return [] }
        var grid = [[String]](repeating: [String](repeating: "", count: lastColumn + 1), count: lastRow + 1)
        for cell in cells { grid[cell.row][cell.column] = cell.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return grid.filter { $0.contains { !$0.isEmpty } }
    }

    private static func double(_ body: [UInt8], _ i: Int) -> Double {
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(body[i + k]) << (8 * k) }
        return Double(bitPattern: bits)
    }

    private static func rk(_ body: [UInt8], _ i: Int) -> Double {
        let raw = UInt32(body[i]) | UInt32(body[i + 1]) << 8 | UInt32(body[i + 2]) << 16 | UInt32(body[i + 3]) << 24
        var value: Double
        if raw & 2 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        if raw & 1 != 0 { value /= 100 }
        return value
    }

    /// 字符串表：每个字符串可能被 CONTINUE 切开，切开处重新写一个「单字节 / 双字节」的标志
    private static func sharedStrings(_ body: [UInt8], continues: [[UInt8]]) -> [String] {
        guard body.count >= 8 else { return [] }
        let unique = Int(body[4]) | Int(body[5]) << 8 | Int(body[6]) << 16 | Int(body[7]) << 24
        var reader = StringReader(segments: [Array(body[8...])] + continues)
        var strings: [String] = []
        strings.reserveCapacity(min(unique, 100_000))
        while strings.count < unique, !reader.atEnd {
            strings.append(reader.string(lengthBytes: 2))
        }
        return strings
    }

    /// 读 BIFF8 的 Unicode 字符串：长度、标志（压缩的单字节 / UTF-16、富文本、远东注音），跨 CONTINUE 时字符部分重新读标志
    struct StringReader {
        var segments: [[UInt8]]
        var segment = 0
        var position = 0

        var atEnd: Bool { segment >= segments.count || (segment == segments.count - 1 && position >= segments[segment].count) }

        mutating func byte() -> UInt8 {
            while segment < segments.count, position >= segments[segment].count {
                segment += 1
                position = 0
            }
            guard segment < segments.count else { return 0 }
            defer { position += 1 }
            return segments[segment][position]
        }

        mutating func skip(_ count: Int) {
            for _ in 0..<count { _ = byte() }
        }

        mutating func string(lengthBytes: Int) -> String {
            var length = Int(byte())
            if lengthBytes == 2 { length |= Int(byte()) << 8 }
            let flags = byte()
            var wide = flags & 0x01 != 0
            let runs = flags & 0x08 != 0 ? Int(byte()) | Int(byte()) << 8 : 0
            let phonetic = flags & 0x04 != 0 ? Int(byte()) | Int(byte()) << 8 | Int(byte()) << 16 | Int(byte()) << 24 : 0
            var units: [UInt16] = []
            units.reserveCapacity(length)
            while units.count < length {
                // 这一段读完了还没读够：下一段开头一个字节是新的标志
                if segment < segments.count, position >= segments[segment].count, segment + 1 < segments.count {
                    segment += 1
                    position = 0
                    wide = byte() & 0x01 != 0
                }
                guard !atEnd else { break }
                if wide {
                    let low = UInt16(byte()), high = UInt16(byte())
                    units.append(low | high << 8)
                } else {
                    units.append(UInt16(byte()))
                }
            }
            skip(runs * 4 + phonetic)
            return String(decoding: units, as: UTF16.self)
        }
    }
}
