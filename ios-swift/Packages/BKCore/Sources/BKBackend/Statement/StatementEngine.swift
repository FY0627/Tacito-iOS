import Foundation
import BKModel

/// 一份账单的内容：表格文件读成一格一格（`StatementReaders`），PDF、图片是每页的一段段字和位置
/// （`ScreenTextLine`，按页面大小归一到 0…1，原点在左上角；不是横着写的字——比如斜着的水印——App 读的时候就不要了）
public enum StatementContent: Hashable, Sendable, Codable {
    case grid([[String]])
    case pages([[ScreenTextLine]])
}

public struct StatementDocument: Hashable, Sendable {
    public var name: String
    public var kind: StatementTemplate.FileType
    public var content: StatementContent

    public init(name: String, kind: StatementTemplate.FileType, content: StatementContent) {
        self.name = name
        self.kind = kind
        self.content = content
    }

    /// 全部文字（认模板、找账号用）：一行一行
    public var text: String {
        switch content {
        case .grid(let rows): rows.map { $0.filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n")
        case .pages(let pages): pages.map { StatementLayout.lines($0).map(\.text).joined(separator: "\n") }.joined(separator: "\n")
        }
    }
}

/// 账单里读出的一笔
public struct StatementRow: Hashable, Sendable {
    /// 第几笔（从 1 数，按账单上的顺序）
    public var number: Int
    /// 第几段（期初余额分开的几段，例如恒生的港币、人民币）
    public var section: Int
    public var date: WallClock
    public var amountMinor: Int64
    public var currency: CurrencyCode
    /// nil：方向列写的是「不计收支」这类，规则也没定方向
    public var direction: FlowDirection?
    /// 规则定的记法；nil 按方向记成支出、收入
    public var action: StatementTemplate.Action?
    public var balanceMinor: Int64?
    public var counterparty: String
    public var description: String
    public var type: String
    public var status: String
    public var reference: String
    public var paidWith: String
    /// 外币交易的原币金额（`values.originalAmount`）
    public var original: Money?

    /// 给人看的一句：日期、摘要、对方
    public var summary: String {
        [type, description, counterparty].filter { !$0.isEmpty }.reduce(into: [String]()) { list, item in
            if !list.contains(item) { list.append(item) }
        }.joined(separator: " · ")
    }
}

public enum StatementVerification: Hashable, Sendable {
    /// 核对过的几项（「余额 50 笔」「笔数 130」）
    case passed([String])
    /// 对不上：哪里
    case failed(String)
    /// 账单上没有能核对的数字
    case unavailable
}

/// 用一个模板读一份账单的结果
public struct StatementReading: Hashable, Sendable {
    public var templateID: String
    public var templateName: String
    public var issuer: StatementTemplate.Issuer
    /// 账单上写的账号 / 卡号（打码的照原样）
    public var accountNumber: String?
    public var rows: [StatementRow]
    public var verification: StatementVerification
    /// 读不出的行（有金额但日期、币种读不出）；有一条整份账单都不导入
    public var problems: [String]

    public var isUsable: Bool {
        if case .failed = verification { return false }
        return problems.isEmpty && !rows.isEmpty
    }
}

public enum StatementEngine {
    /// 这个模板认不认这份账单
    public static func matches(_ template: StatementTemplate, _ document: StatementDocument) -> Bool {
        guard template.detect.fileTypes.contains(document.kind) else { return false }
        let text = normalized(document.text)
        return template.detect.contains.allSatisfy { text.contains(normalized($0)) }
            && !(template.detect.notContains ?? []).contains { !normalized($0).isEmpty && text.contains(normalized($0)) }
    }

    /// 按模板读出每一笔，再核对余额、合计。`now` 用来推没写年份的日期（账单上也没写账单日期时）
    public static func read(_ document: StatementDocument, with template: StatementTemplate, now: Date = Date(), calendar: Calendar = .current) -> StatementReading {
        var reading = StatementReading(
            templateID: template.id, templateName: template.name, issuer: template.issuer, accountNumber: nil,
            rows: [], verification: .unavailable, problems: []
        )
        let fullText = document.text
        if let pattern = template.statement?.accountNumber {
            reading.accountNumber = firstMatch(pattern, in: fullText, group: "number")?.trimmingCharacters(in: .whitespaces)
        }
        // 没写年份的日期：按账单日期推，没有账单日期按现在
        var reference: (year: Int, month: Int, day: Int)?
        if let date = template.statement?.date, let text = firstMatch(date.pattern, in: fullText, group: "date"),
           let parts = StatementDateFormat(date.format)?.parse(text), let year = parts.year, let month = parts.month, let day = parts.day {
            reference = (year, month, day)
        }
        if reference == nil {
            let c = calendar.dateComponents([.year, .month, .day], from: now)
            reference = (c.year ?? 2026, c.month ?? 1, c.day ?? 1)
        }

        let tableRows: [TableRow]
        switch document.content {
        case .grid(let grid): tableRows = gridRows(grid, template)
        case .pages(let pages): tableRows = StatementLayout.rows(pages, template)
        }
        if tableRows.isEmpty {
            reading.problems.append("找不到表头（\(template.table.header.joined(separator: "、"))）")
            reading.verification = .failed("找不到表头")
            return reading
        }

        let builder = RowBuilder(template: template, reference: reference!)
        var section = 0
        var openings: [Int: String] = [:]
        var closings: [Int: String] = [:]
        var lastDate: WallClock?
        var lastCurrency: [Int: CurrencyCode] = [:]
        var rawDirections: [FlowDirection?] = []
        let hasOpening = template.table.opening != nil
        for row in tableRows {
            let text = row.cells.values.joined(separator: " ")
            if let pattern = template.table.opening, matches(pattern, text) {
                if !reading.rows.isEmpty || openings[section] != nil { section += 1 }
                if let balance = row.cell(template.columns.balance) { openings[section] = balance }
                // 期初余额那一行写的币种是这一段的（恒生外币户口只在「B/F BALANCE」那行写 CNY）
                lastCurrency[section] = row.cell(template.columns.currency).flatMap { currency($0, names: template.values.currencyNames ?? [:]) }
                continue
            }
            if let pattern = template.table.closing, matches(pattern, text) {
                if let balance = row.cell(template.columns.balance) { closings[section] = balance }
                continue
            }
            switch builder.build(row, number: reading.rows.count + 1, section: hasOpening ? section : 0, lastDate: lastDate, lastCurrency: lastCurrency[section]) {
            case .notARow:
                continue
            case .problem(let message):
                reading.problems.append(message)
            case .row(let built, let rawDirection):
                reading.rows.append(built)
                rawDirections.append(rawDirection)
                lastDate = built.date
                lastCurrency[section] = built.currency
            }
        }
        if reading.rows.isEmpty, reading.problems.isEmpty { reading.problems.append("表头下面没有读出交易") }
        reading.verification = verify(reading.rows, rawDirections: rawDirections, openings: openings, closings: closings, template: template, text: fullText, problems: reading.problems)
        return reading
    }

    // MARK: 核对

    static func verify(
        _ rows: [StatementRow], rawDirections: [FlowDirection?], openings: [Int: String], closings: [Int: String],
        template: StatementTemplate, text: String, problems: [String]
    ) -> StatementVerification {
        guard problems.isEmpty else { return .failed(problems[0]) }
        var passed: [String] = []
        // 余额：每一段、每个币种分开，顺着或倒着（新的在前）接得上都行
        if template.columns.balance != nil, template.checks?.balance != false {
            var compared = 0
            let groups = Dictionary(grouping: rows.filter { $0.action != .skip }, by: { "\($0.section)|\($0.currency.rawValue)" })
            for key in groups.keys.sorted() {
                guard let group = groups[key], let first = group.first else { continue }
                let exponent = first.currency.minorUnitExponent
                let opening = openings[first.section].flatMap { parseAmount($0, exponent: exponent) }
                let closing = closings[first.section].flatMap { parseAmount($0, exponent: exponent) }
                if openings[first.section] != nil, opening == nil { return .failed("第 \(first.section + 1) 段的期初余额读不出") }
                let forward = chain(group, opening: opening, closing: closing)
                switch forward {
                case .success(let count):
                    compared += count
                case .failure(let line) where opening == nil && closing == nil:
                    if case .success(let count) = chain(group.reversed(), opening: nil, closing: nil) {
                        compared += count
                    } else {
                        return .failed("第 \(line) 笔后的余额对不上")
                    }
                case .failure(let line):
                    return .failed("第 \(line) 笔后的余额对不上")
                }
            }
            if compared > 0 { passed.append("余额 \(compared) 笔") }
        }
        // 账单上写的笔数、合计（按账单原来的收、支，不管规则）
        if let totals = template.checks?.totals {
            if let pattern = totals.count {
                guard let stated = firstMatch(pattern, in: text, group: "count").flatMap({ Int($0.filter(\.isNumber)) }) else {
                    return .failed("账单上找不到总笔数")
                }
                guard stated == rows.count else { return .failed("账单上写 \(stated) 笔，读出 \(rows.count) 笔") }
                passed.append("笔数 \(stated)")
            }
            let parts: [(String?, FlowDirection?, String)] = [(totals.inflow, .inflow, "收入"), (totals.outflow, .outflow, "支出"), (totals.neutral, nil, "不计收支")]
            for (pattern, direction, label) in parts {
                guard let pattern else { continue }
                let picked = rows.indices.filter { rawDirections[$0] == direction }
                var checkedAny = false
                if let count = firstMatch(pattern, in: text, group: "count").flatMap({ Int($0.filter(\.isNumber)) }) {
                    guard count == picked.count else { return .failed("账单上写\(label) \(count) 笔，读出 \(picked.count) 笔") }
                    checkedAny = true
                }
                if hasGroup(pattern, "amount") {
                    // 合计按最小单位加：写合计的账单只有一个币种
                    let exponent = rows.first?.currency.minorUnitExponent ?? 2
                    guard let text = firstMatch(pattern, in: text, group: "amount"),
                          let stated = parseAmount(text, exponent: exponent) else { return .failed("账单上找不到\(label)合计") }
                    let sum = picked.reduce(Int64(0)) { $0 + rows[$1].amountMinor }
                    guard abs(stated) == sum else {
                        return .failed("账单上写\(label) \(text)，读出 \(MoneyFormat.plain(sum, exponent: exponent))")
                    }
                    checkedAny = true
                }
                if checkedAny { passed.append("\(label)合计") }
            }
        }
        return passed.isEmpty ? .unavailable : .passed(passed)
    }

    private enum ChainResult { case success(Int), failure(Int) }

    /// 从期初余额（没有就从第一笔的余额）往下加减，每笔写了余额的地方核对一次
    private static func chain<S: Sequence>(_ rows: S, opening: Int64?, closing: Int64?) -> ChainResult where S.Element == StatementRow {
        var running = opening
        var compared = 0
        var lastNumber = 0
        for row in rows {
            lastNumber = row.number
            let signed: Int64
            switch row.direction {
            case .inflow?: signed = row.amountMinor
            case .outflow?: signed = -row.amountMinor
            case nil: return .failure(row.number)
            }
            if let current = running { running = current + signed }
            if let balance = row.balanceMinor {
                if let current = running {
                    guard current == balance else { return .failure(row.number) }
                    compared += 1
                }
                running = balance
            }
        }
        if let closing, let current = running {
            guard current == closing else { return .failure(lastNumber) }
            compared += 1
        }
        return .success(compared)
    }

    // MARK: 表格文件：找表头

    static func gridRows(_ grid: [[String]], _ template: StatementTemplate) -> [TableRow] {
        let header = template.table.header.map(normalized)
        var columns: [String: Int]?
        var rows: [TableRow] = []
        let labels = template.allColumnLabels
        let ignores = (template.table.ignore ?? []).compactMap { try? NSRegularExpression(pattern: $0) }
        let stops = (template.table.stop ?? []).map(normalized).filter { !$0.isEmpty }
        var stopped = false
        for (index, row) in grid.enumerated() {
            let cells = row.map(normalized)
            if header.allSatisfy({ cells.contains($0) }) {
                var map: [String: Int] = [:]
                for label in labels {
                    if let i = cells.firstIndex(of: normalized(label)) { map[label] = i }
                }
                columns = map
                stopped = false
                continue
            }
            guard let columns, !stopped else { continue }
            let joined = row.joined(separator: " ")
            if stops.contains(where: { normalized(joined).contains($0) }) {
                stopped = true
                continue
            }
            if ignores.contains(where: { $0.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) != nil }) { continue }
            var values: [String: String] = [:]
            for (label, i) in columns where i < row.count { values[label] = row[i] }
            rows.append(TableRow(cells: values, place: "第 " + String(index + 1) + " 行"))
        }
        return rows
    }

    // MARK: 文字工具

    /// 比较用：去掉空白，英文小写
    static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{3000}" }.map(Character.init)).lowercased()
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func hasGroup(_ pattern: String, _ name: String) -> Bool { pattern.contains("(?<\(name)>") }

    static func firstMatch(_ pattern: String, in text: String, group: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(withName: group), in: text) else { return nil }
        return String(text[range])
    }

    /// 金额：去掉货币符号、千分位、空白；「-12.30」「(12.30)」「12.30-」「12.30 DR」是负数，「CR」是正数。读不出返回 nil
    static func parseAmount(_ raw: String, exponent: Int) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        let upper = text.uppercased()
        if upper.hasSuffix("DR") {
            negative = true
            text = String(text.dropLast(2))
        } else if upper.hasSuffix("CR") {
            text = String(text.dropLast(2))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative.toggle()
            text = String(text.dropFirst().dropLast())
        }
        for symbol in ["HK$", "US$", "RMB", "¥", "￥", "$", "€", "£", "元"] { text = text.replacingOccurrences(of: symbol, with: "") }
        text = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        if text.hasSuffix("-") {
            negative.toggle()
            text.removeLast()
        }
        if text.hasPrefix("+") { text.removeFirst() } else if text.hasPrefix("-") {
            negative.toggle()
            text.removeFirst()
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), text.filter({ $0 == "." }).count <= 1,
              text.first != ".", text.last != "." else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]) else { return nil }
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        // 比这个币种的小数位多：多出来的必须都是 0（Excel 存的浮点数已经在读的时候整理过）
        if fraction.count > exponent {
            guard fraction.dropFirst(exponent).allSatisfy({ $0 == "0" }) else { return nil }
            fraction = String(fraction.prefix(exponent))
        }
        while fraction.count < exponent { fraction += "0" }
        var scale: Int64 = 1
        for _ in 0..<exponent { scale *= 10 }
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: scale)
        guard !overflow, let minor = Int64(fraction.isEmpty ? "0" : fraction) else { return nil }
        let value = scaled + minor
        return negative ? -value : value
    }

    /// 币种：代码，或常见的中文名称
    static func currency(_ raw: String, names: [String: String]) -> CurrencyCode? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let code = names[text] { return CurrencyCode(code) }
        if let code = commonCurrencyNames[text] { return CurrencyCode(code) }
        let upper = text.uppercased()
        if upper.count == 3, upper.allSatisfy({ ("A"..."Z").contains($0) }) { return CurrencyCode(upper) }
        if upper == "RMB" { return CurrencyCode("CNY") }
        return nil
    }

    static let commonCurrencyNames: [String: String] = [
        "人民币": "CNY", "人民币元": "CNY", "人民幣": "CNY", "元": "CNY",
        "港币": "HKD", "港元": "HKD", "港幣": "HKD", "港币元": "HKD",
        "美元": "USD", "美金": "USD", "日元": "JPY", "日圓": "JPY", "欧元": "EUR", "歐元": "EUR", "英镑": "GBP", "英鎊": "GBP",
        "澳门元": "MOP", "澳門元": "MOP", "新台币": "TWD", "新台幣": "TWD", "新加坡元": "SGD", "澳大利亚元": "AUD", "澳元": "AUD",
        "加拿大元": "CAD", "加元": "CAD", "瑞士法郎": "CHF", "韩元": "KRW", "泰铢": "THB",
    ]
}

/// 表格的一行：表头每一格对应的文字
struct TableRow: Hashable {
    var cells: [String: String]
    /// 在文件里的位置：表格「第 12 行」，PDF「第 2 页」（给出错的提示用）
    var place: String
    /// PDF：表头上面写的这一段的币种
    var sectionCurrency: String?

    func cell(_ label: String?) -> String? {
        guard let label, let value = cells[label] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 几列连起来（对方、摘要）。只写了「/」「-」占位的格子不要
    func joined(_ labels: [String]?) -> String {
        (labels ?? []).compactMap { cell($0) }.filter { !$0.allSatisfy { $0 == "/" || $0 == "-" } }.joined(separator: " ")
    }
}

extension StatementTemplate {
    /// 表头和各列用到的全部表头文字
    var allColumnLabels: [String] {
        var labels = table.header
        let c = columns
        let single: [String?] = [c.date, c.time, c.amount, c.inflow, c.outflow, c.direction, c.balance, c.currency, c.status, c.type, c.reference, c.paidWith]
        for label in single.compactMap({ $0 }) + (c.counterparty ?? []) + (c.description ?? []) where !labels.contains(label) {
            labels.append(label)
        }
        return labels
    }
}

/// 一行表格 → 一笔
private struct RowBuilder {
    let template: StatementTemplate
    let reference: (year: Int, month: Int, day: Int)
    let dateFormats: [StatementDateFormat]
    let timeFormats: [StatementDateFormat]
    let rules: [(StatementTemplate.Rule, [NSRegularExpression?])]
    let originalRegex: NSRegularExpression?

    init(template: StatementTemplate, reference: (year: Int, month: Int, day: Int)) {
        self.template = template
        self.reference = reference
        dateFormats = template.values.dateFormats.compactMap(StatementDateFormat.init)
        timeFormats = (template.values.timeFormats ?? []).compactMap(StatementDateFormat.init)
        rules = (template.rules ?? []).map { rule in (rule, rule.when.map { $0.matches.flatMap { try? NSRegularExpression(pattern: $0) } }) }
        originalRegex = template.values.originalAmount.flatMap { try? NSRegularExpression(pattern: $0) }
    }

    enum Outcome {
        case notARow
        case problem(String)
        case row(StatementRow, rawDirection: FlowDirection?)
    }

    /// 金额（带正负号），币种未知时按 2 位小数读；`exponent` 后面按币种换算
    func amount(_ text: String, exponent: Int = 2) -> (signed: Int64, text: String)? {
        StatementEngine.parseAmount(text, exponent: exponent).map { ($0, text) }
    }

    func build(_ row: TableRow, number: Int, section: Int, lastDate: WallClock?, lastCurrency: CurrencyCode?) -> Outcome {
        let c = template.columns
        let at = row.place
        // 金额：没有金额的行不是交易（空行、小计、说明文字）
        var amountText: String?
        var direction: FlowDirection?
        var rawDirection: FlowDirection?
        if let label = c.amount {
            guard let text = row.cell(label) else { return .notARow }
            guard let value = amount(text) else {
                return row.cell(c.date) == nil ? .notARow : .problem("\(at)的金额「\(text)」读不出")
            }
            amountText = text
            if c.direction != nil {
                let word = row.cell(c.direction) ?? ""
                if (template.values.inflowWords ?? []).contains(word) {
                    rawDirection = .inflow
                } else if (template.values.outflowWords ?? []).contains(word) {
                    rawDirection = .outflow
                } else if (template.values.neutralWords ?? []).contains(word) {
                    rawDirection = nil
                } else {
                    return .problem("\(at)的收支「\(word)」不在 inflowWords、outflowWords、neutralWords 里")
                }
            } else {
                guard value.signed != 0 else { return .notARow }
                rawDirection = value.signed < 0 ? .outflow : .inflow
            }
        } else {
            let inText = row.cell(c.inflow), outText = row.cell(c.outflow)
            let inValue = inText.flatMap { amount($0) }, outValue = outText.flatMap { amount($0) }
            if let inText, inValue == nil { return .problem("\(at)的金额「\(inText)」读不出") }
            if let outText, outValue == nil { return .problem("\(at)的金额「\(outText)」读不出") }
            let inNonZero = (inValue?.signed ?? 0) != 0, outNonZero = (outValue?.signed ?? 0) != 0
            if inNonZero, outNonZero { return .problem("\(at)收入、支出两列都有金额") }
            if inNonZero {
                amountText = inText
                rawDirection = .inflow
            } else if outNonZero {
                amountText = outText
                rawDirection = .outflow
            } else {
                return .notARow
            }
        }
        direction = rawDirection

        // 日期：空的沿用上一笔（恒生一天几笔只在第一笔写日期）
        var date: WallClock
        if let text = row.cell(c.date) {
            guard let parts = dateFormats.lazy.compactMap({ $0.parse(text) }).first, let month = parts.month, let day = parts.day else {
                return .problem("\(at)的日期「\(text)」读不出")
            }
            var year = parts.year
            var inferred = false
            if year == nil {
                // 没写年份：比账单日期晚一个星期以上的是去年（跨年的账单：12 月的交易、1 月的账单日期）
                year = month * 31 + day > reference.month * 31 + reference.day + 7 ? reference.year - 1 : reference.year
                inferred = true
            }
            date = WallClock(year: year, month: month, day: day, hour: parts.hour, minute: parts.minute, second: parts.second, yearInferred: inferred)
        } else if let lastDate {
            date = WallClock(year: lastDate.year, month: lastDate.month, day: lastDate.day, hour: nil, minute: nil, yearInferred: lastDate.yearInferred)
        } else {
            return .problem("\(at)没有日期")
        }
        if let text = row.cell(c.time) {
            guard let parts = timeFormats.lazy.compactMap({ $0.parse(text) }).first else { return .problem("\(at)的时间「\(text)」读不出") }
            date.hour = parts.hour
            date.minute = parts.minute
            date.second = parts.second
        }

        // 币种：币种列（空的沿用这一段上一笔）→ 表头上面写的 → 账单的币种
        let names = template.values.currencyNames ?? [:]
        var currency: CurrencyCode?
        if let text = row.cell(c.currency) {
            guard let code = StatementEngine.currency(text, names: names) else { return .problem("\(at)的币种「\(text)」认不出") }
            currency = code
        }
        currency = currency ?? lastCurrency
        if currency == nil, let text = row.sectionCurrency {
            guard let code = StatementEngine.currency(text, names: names) else { return .problem("\(at)上面的币种「\(text)」认不出") }
            currency = code
        }
        currency = currency ?? template.statement?.currency.map { CurrencyCode($0) }
        guard let currency else { return .problem("\(at)不知道是什么币种") }
        let exponent = currency.minorUnitExponent
        guard let amountText, let minor = StatementEngine.parseAmount(amountText, exponent: exponent) else {
            return .problem("\(at)的金额按 \(currency.rawValue) 读不出")
        }
        var balance: Int64?
        if let text = row.cell(c.balance) {
            guard let value = StatementEngine.parseAmount(text, exponent: exponent) else { return .problem("\(at)的余额「\(text)」读不出") }
            balance = value
        }

        var built = StatementRow(
            number: number, section: section, date: date, amountMinor: abs(minor), currency: currency, direction: direction, action: nil,
            balanceMinor: balance, counterparty: row.joined(c.counterparty), description: row.joined(c.description),
            type: row.cell(c.type) ?? "", status: row.cell(c.status) ?? "", reference: row.cell(c.reference) ?? "",
            paidWith: row.cell(c.paidWith) ?? "", original: nil
        )
        // 规则：第一条都符合的
        for (rule, regexes) in rules {
            let hit = zip(rule.when, regexes).allSatisfy { condition, regex in
                let value = template.column(for: condition.field).map { row.joined($0) } ?? ""
                if let equals = condition.equals { return equals.contains(value) }
                guard let regex else { return false }
                return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
            guard hit else { continue }
            built.action = rule.then
            if let ruled = rule.direction { built.direction = ruled }
            break
        }
        // 外币：原币金额
        if let originalRegex {
            let text = [built.description, built.counterparty].joined(separator: " ")
            if let match = originalRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let codeRange = Range(match.range(withName: "currency"), in: text), let amountRange = Range(match.range(withName: "amount"), in: text),
               let code = StatementEngine.currency(String(text[codeRange]), names: names), code != currency,
               let value = StatementEngine.parseAmount(String(text[amountRange]), exponent: code.minorUnitExponent), value != 0 {
                built.original = Money(minorUnits: abs(value), currency: code)
            }
        }
        return .row(built, rawDirection: rawDirection)
    }
}
