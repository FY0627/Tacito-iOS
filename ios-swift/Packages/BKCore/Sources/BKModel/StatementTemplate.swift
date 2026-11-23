import Foundation

/// 账单模板（ADR 0029）：一家银行或钱包导出的账单怎么读。App 里没有内置任何一家的读法，全部靠模板；
/// 模板是一个 JSON 文件，由开发者用 skill（`.claude/skills/statement-template`）照着样本账单写好、用同一套代码试读通过后发给用户，
/// 用户在「导入账单」里和账单一起选进来。
///
/// 格式是严格的：多一个键、少一个必填的键、类型不对、正则写错都不收（`StatementTemplate.decode`），
/// 免得写错的模板悄悄读错账。完整的说明在 skill 的 `FORMAT.md`，改这里时同步改那里。
public struct StatementTemplate: Hashable, Sendable, Codable, Identifiable {
    public static let formatName = "tacito-statement-template"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    /// 小写字母、数字、`-`，2–64 个字符。再导入同一个 `id` 的模板时换掉旧的
    public var id: String
    public var name: String
    public var issuer: Issuer
    public var detect: Detect
    public var statement: Statement?
    public var table: Table
    public var columns: Columns
    public var values: Values
    public var rules: [Rule]?
    public var checks: Checks?

    public enum IssuerType: String, Sendable, Codable, CaseIterable { case bank, wallet }

    public struct Issuer: Hashable, Sendable, Codable {
        public var type: IssuerType
        /// 银行或钱包的名称：账户的银行名称里有它（或它里有账户的银行名称）就可能是这家的卡
        public var name: String
        /// 钱包（`WalletDirectory` 的标识，例如 `alipay`、`wechatpay`）
        public var wallet: String?
    }

    public enum FileType: String, Sendable, Codable, CaseIterable { case csv, xlsx, xls, pdf, image }

    public struct Detect: Hashable, Sendable, Codable {
        public var fileTypes: [FileType]
        /// 文件里都要有的字（比较时去掉空白，英文不分大小写）
        public var contains: [String]
        public var notContains: [String]?
    }

    public struct Statement: Hashable, Sendable, Codable {
        /// 表格前面的文字里找账号 / 卡号的正则，命名分组 `number`
        public var accountNumber: String?
        /// 没有币种列、也没有分段币种时的币种
        public var currency: String?
        /// 账单日期：表格里的日期没写年份时用它推年份
        public var date: DatePattern?
    }

    public struct DatePattern: Hashable, Sendable, Codable {
        /// 命名分组 `date`
        public var pattern: String
        public var format: String
    }

    public enum RowAlign: String, Sendable, Codable, CaseIterable { case top, center, bottom }

    public struct Table: Hashable, Sendable, Codable {
        /// 表头：这几格都在同一行，就是表头。PDF 每页的表头都要找到
        public var header: [String]
        /// PDF、图片：一笔交易占几行时，金额那一行在这笔的哪里（`top` 第一行，`center` 中间，`bottom` 最后一行）
        public var rows: RowAlign?
        /// 一行里有这些字：表格到这里结束（到下一个表头再接着读）
        public var stop: [String]?
        /// 整行（表格）或一段字（PDF）符合这些正则的不要
        public var ignore: [String]?
        /// 期初余额那一行（只有余额）：符合这个正则的行，余额是这一段的起点，不是交易
        public var opening: String?
        /// 期末余额那一行
        public var closing: String?
        /// PDF：表头上面几行里写的这一段的币种，命名分组 `currency`
        public var sectionCurrency: String?
        /// PDF：表头占几行（默认 1）。下面跟着英文表头、「( DR=Debit )」这类说明的，后面几行不是交易
        public var headerLines: Int?
    }

    /// 每一列用表头上的哪一格。金额要么 `amount`（可以配 `direction`），要么 `inflow` + `outflow` 两列
    public struct Columns: Hashable, Sendable, Codable {
        public var date: String
        public var time: String?
        public var amount: String?
        public var inflow: String?
        public var outflow: String?
        public var direction: String?
        public var balance: String?
        public var currency: String?
        public var counterparty: [String]?
        public var description: [String]?
        public var status: String?
        public var type: String?
        public var reference: String?
        public var paidWith: String?
    }

    public struct Values: Hashable, Sendable, Codable {
        /// 日期的写法，按顺序试：`yyyy` `yy` `MM` `M` `dd` `d` `MMM`（英文月份缩写） `HH` `H` `mm` `ss`，其他字照原样
        public var dateFormats: [String]
        public var timeFormats: [String]?
        /// 方向列写这些字是收入 / 支出 / 不计收支（整格相同才算）
        public var inflowWords: [String]?
        public var outflowWords: [String]?
        public var neutralWords: [String]?
        /// 币种列、分段币种里的中文名称换成代码（常见的不用写）
        public var currencyNames: [String: String]?
        /// 外币交易：在对方和摘要里找原币金额的正则，命名分组 `currency`、`amount`
        public var originalAmount: String?
    }

    public enum Field: String, Sendable, Codable, CaseIterable {
        case type, status, description, counterparty, paidWith, direction, reference
    }

    public struct Condition: Hashable, Sendable, Codable {
        public var field: Field
        /// 整格（去掉首尾空白）等于其中一个
        public var equals: [String]?
        /// 符合正则（不用整格）
        public var matches: String?
    }

    /// 符合规则的行怎么记：
    /// `skip` 不是钱的进出（交易关闭、失败），不记也不算余额；
    /// `internal` 同一个账户里面挪钱（招行朝朝宝、余额宝），算余额但不记；
    /// 其余是记成什么：支出、收入、退款、转帐、利息、手续费
    public enum Action: String, Sendable, Codable, CaseIterable {
        case skip, `internal`, expense, income, refund, transfer, interest, fee
    }

    public struct Rule: Hashable, Sendable, Codable {
        /// 都符合才算
        public var when: [Condition]
        public var then: Action
        /// 方向列写的是「不计收支」这类，由规则定方向
        public var direction: FlowDirection?
    }

    public struct Checks: Hashable, Sendable, Codable {
        /// 有余额列时默认核对余额；写 false 不核对（只有余额列不是每笔交易后的余额时才这样写）
        public var balance: Bool?
        public var totals: Totals?
    }

    /// 账单上写的合计：命名分组 `count`（笔数）、`amount`（金额）
    public struct Totals: Hashable, Sendable, Codable {
        public var count: String?
        public var inflow: String?
        public var outflow: String?
        public var neutral: String?
    }
}

// MARK: - 严格读取

public struct StatementTemplateError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 出错的位置，例如 `columns.amount`
    public var path: String
    public var message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { path.isEmpty ? message : "\(path)：\(message)" }
}

extension StatementTemplate {
    /// 一个文件里可以是一个模板，也可以是几个模板的数组。有一处不对整个文件都不收
    public static func decode(_ data: Data) throws -> [StatementTemplate] {
        guard let text = String(data: data, encoding: .utf8) else { throw StatementTemplateError("", "不是 UTF-8 的文字") }
        let root = try JSONValue.parse(text)
        let items: [(JSONValue, String)]
        if case .array(let array) = root {
            guard !array.isEmpty else { throw StatementTemplateError("", "数组是空的") }
            items = array.enumerated().map { ($0.element, "[\($0.offset)]") }
        } else {
            items = [(root, "")]
        }
        var templates: [StatementTemplate] = []
        for (item, prefix) in items {
            try Shape.template.check(item, path: prefix)
            let template: StatementTemplate
            do {
                template = try JSONDecoder().decode(StatementTemplate.self, from: Data(item.serialized().utf8))
            } catch {
                throw StatementTemplateError(prefix, "读不了：\(error)")
            }
            try template.validate(path: prefix)
            guard !templates.contains(where: { $0.id == template.id }) else {
                throw StatementTemplateError(prefix.isEmpty ? "id" : prefix + ".id", "同一个文件里有两个模板都是 \(template.id)")
            }
            templates.append(template)
        }
        return templates
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// 键和类型以外的检查：必填的组合、正则、日期写法
    func validate(path prefix: String) throws {
        func fail(_ key: String, _ message: String) -> StatementTemplateError {
            StatementTemplateError(prefix.isEmpty ? key : prefix + "." + key, message)
        }
        guard format == Self.formatName else { throw fail("format", "要写 \(Self.formatName)") }
        guard version == Self.currentVersion else { throw fail("version", "这个 App 只认第 \(Self.currentVersion) 版") }
        guard id.count >= 2, id.count <= 64, id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            throw fail("id", "只能用小写字母、数字和 -，2 到 64 个字")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("name", "不能是空的") }
        guard !issuer.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("issuer.name", "不能是空的") }
        let wallets = WalletDirectory.all.map(\.id)
        if issuer.type == .wallet, !wallets.contains(issuer.wallet ?? "") {
            throw fail("issuer.wallet", "钱包要写是哪个钱包：\(wallets.joined(separator: "、"))")
        }
        if issuer.type == .bank, issuer.wallet != nil { throw fail("issuer.wallet", "银行不写钱包") }
        guard !detect.fileTypes.isEmpty else { throw fail("detect.fileTypes", "至少写一种") }
        guard detect.contains.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw fail("detect.contains", "至少写一段账单上一定有的字")
        }
        guard !table.header.isEmpty else { throw fail("table.header", "至少写一格") }
        let pdfLike = detect.fileTypes.contains(.pdf) || detect.fileTypes.contains(.image)
        if table.rows != nil, !pdfLike { throw fail("table.rows", "只有 PDF、图片用得上") }
        if table.sectionCurrency != nil, !pdfLike { throw fail("table.sectionCurrency", "只有 PDF、图片用得上") }
        if let lines = table.headerLines {
            guard pdfLike else { throw fail("table.headerLines", "只有 PDF、图片用得上") }
            guard (1...6).contains(lines) else { throw fail("table.headerLines", "要在 1 到 6 之间") }
        }

        let hasAmount = columns.amount != nil
        let hasSplit = columns.inflow != nil || columns.outflow != nil
        if hasAmount == hasSplit { throw fail("columns", "金额要么写 amount，要么写 inflow 和 outflow") }
        if hasSplit, columns.inflow == nil || columns.outflow == nil { throw fail("columns", "inflow 和 outflow 要一起写") }
        if columns.direction != nil, !hasAmount { throw fail("columns.direction", "只能和 amount 一起用") }
        if columns.direction != nil, (values.inflowWords ?? []).isEmpty || (values.outflowWords ?? []).isEmpty {
            throw fail("values", "有方向列时要写 inflowWords 和 outflowWords")
        }
        if columns.direction == nil, values.inflowWords != nil || values.outflowWords != nil || values.neutralWords != nil {
            throw fail("values", "没有方向列时不写 inflowWords、outflowWords、neutralWords")
        }
        if columns.time == nil, values.timeFormats != nil { throw fail("values.timeFormats", "没有时间列") }
        if columns.time != nil, (values.timeFormats ?? []).isEmpty { throw fail("values.timeFormats", "有时间列时要写") }
        if columns.currency == nil, table.sectionCurrency == nil, statement?.currency == nil {
            throw fail("statement.currency", "没有币种列、也没有分段币种时要写账单的币种")
        }
        if let code = statement?.currency, !Self.isCurrencyCode(code) { throw fail("statement.currency", "要写 3 个大写字母的币种代码") }
        for (name, code) in values.currencyNames ?? [:] where !Self.isCurrencyCode(code) {
            throw fail("values.currencyNames.\(name)", "要写 3 个大写字母的币种代码")
        }
        if checks?.balance == true, columns.balance == nil { throw fail("checks.balance", "没有余额列") }
        if table.opening != nil || table.closing != nil, columns.balance == nil { throw fail("table", "期初、期末余额要有余额列") }

        if values.dateFormats.isEmpty { throw fail("values.dateFormats", "至少写一种") }
        for (index, format) in values.dateFormats.enumerated() {
            guard StatementDateFormat(format)?.hasDate == true else { throw fail("values.dateFormats[\(index)]", "看不懂这个写法，或者没有月、日") }
        }
        for (index, format) in (values.timeFormats ?? []).enumerated() {
            guard StatementDateFormat(format)?.hasTime == true else { throw fail("values.timeFormats[\(index)]", "看不懂这个写法，或者没有时、分") }
        }
        if let date = statement?.date, StatementDateFormat(date.format)?.hasYear != true {
            throw fail("statement.date.format", "账单日期要有年份")
        }

        var patterns: [(String, String, [String])] = []
        if let p = statement?.accountNumber { patterns.append(("statement.accountNumber", p, ["number"])) }
        if let p = statement?.date?.pattern { patterns.append(("statement.date.pattern", p, ["date"])) }
        for (i, p) in (table.ignore ?? []).enumerated() { patterns.append(("table.ignore[\(i)]", p, [])) }
        if let p = table.opening { patterns.append(("table.opening", p, [])) }
        if let p = table.closing { patterns.append(("table.closing", p, [])) }
        if let p = table.sectionCurrency { patterns.append(("table.sectionCurrency", p, ["currency"])) }
        if let p = values.originalAmount { patterns.append(("values.originalAmount", p, ["currency", "amount"])) }
        if let totals = checks?.totals {
            if totals.count == nil, totals.inflow == nil, totals.outflow == nil, totals.neutral == nil {
                throw fail("checks.totals", "至少写一项")
            }
            if let p = totals.count { patterns.append(("checks.totals.count", p, ["count"])) }
            for (key, p) in [("inflow", totals.inflow), ("outflow", totals.outflow), ("neutral", totals.neutral)] {
                guard let p else { continue }
                patterns.append(("checks.totals.\(key)", p, ["amount"]))
            }
        }
        for (i, rule) in (rules ?? []).enumerated() {
            if rule.when.isEmpty { throw fail("rules[\(i)].when", "至少写一个条件") }
            for (j, condition) in rule.when.enumerated() {
                if (condition.equals == nil) == (condition.matches == nil) {
                    throw fail("rules[\(i)].when[\(j)]", "equals 和 matches 写一个")
                }
                if let p = condition.matches { patterns.append(("rules[\(i)].when[\(j)].matches", p, [])) }
                if column(for: condition.field) == nil {
                    throw fail("rules[\(i)].when[\(j)].field", "columns 里没有 \(condition.field.rawValue)")
                }
            }
            if rule.direction != nil, rule.then == .skip || rule.then == .internal {
                throw fail("rules[\(i)].direction", "不记的行不用写方向")
            }
        }
        for (key, pattern, groups) in patterns {
            let full = prefix.isEmpty ? key : prefix + "." + key
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw StatementTemplateError(full, "正则写错了") }
            for group in groups where !Self.hasNamedGroup(pattern, group) {
                // 合计里收入、支出这几项可以只写笔数
                if key.hasPrefix("checks.totals."), group == "amount", Self.hasNamedGroup(pattern, "count") { continue }
                throw StatementTemplateError(full, "要有命名分组 (?<\(group)>…)")
            }
        }
    }

    /// 规则里的字段读哪一列（`direction` 读方向列）
    public func column(for field: Field) -> [String]? {
        switch field {
        case .type: columns.type.map { [$0] }
        case .status: columns.status.map { [$0] }
        case .description: columns.description
        case .counterparty: columns.counterparty
        case .paidWith: columns.paidWith.map { [$0] }
        case .direction: columns.direction.map { [$0] }
        case .reference: columns.reference.map { [$0] }
        }
    }

    static func isCurrencyCode(_ text: String) -> Bool {
        text.count == 3 && text.allSatisfy { ("A"..."Z").contains($0) }
    }

    static func hasNamedGroup(_ pattern: String, _ name: String) -> Bool {
        pattern.contains("(?<\(name)>")
    }
}

/// 每一层 JSON 允许哪些键、什么类型
private indirect enum Shape: Sendable {
    case string, int, bool, stringArray
    case stringMap
    case enumeration([String])
    case object([String: (Shape, Bool)])
    case array(Shape)

    static let datePattern = Shape.object(["pattern": (.string, true), "format": (.string, true)])

    static let template = Shape.object([
        "format": (.string, true),
        "version": (.int, true),
        "id": (.string, true),
        "name": (.string, true),
        "issuer": (.object([
            "type": (.enumeration(StatementTemplate.IssuerType.allCases.map(\.rawValue)), true),
            "name": (.string, true),
            "wallet": (.string, false),
        ]), true),
        "detect": (.object([
            "fileTypes": (.array(.enumeration(StatementTemplate.FileType.allCases.map(\.rawValue))), true),
            "contains": (.stringArray, true),
            "notContains": (.stringArray, false),
        ]), true),
        "statement": (.object([
            "accountNumber": (.string, false),
            "currency": (.string, false),
            "date": (datePattern, false),
        ]), false),
        "table": (.object([
            "header": (.stringArray, true),
            "rows": (.enumeration(StatementTemplate.RowAlign.allCases.map(\.rawValue)), false),
            "stop": (.stringArray, false),
            "ignore": (.stringArray, false),
            "opening": (.string, false),
            "closing": (.string, false),
            "sectionCurrency": (.string, false),
            "headerLines": (.int, false),
        ]), true),
        "columns": (.object([
            "date": (.string, true),
            "time": (.string, false),
            "amount": (.string, false),
            "inflow": (.string, false),
            "outflow": (.string, false),
            "direction": (.string, false),
            "balance": (.string, false),
            "currency": (.string, false),
            "counterparty": (.stringArray, false),
            "description": (.stringArray, false),
            "status": (.string, false),
            "type": (.string, false),
            "reference": (.string, false),
            "paidWith": (.string, false),
        ]), true),
        "values": (.object([
            "dateFormats": (.stringArray, true),
            "timeFormats": (.stringArray, false),
            "inflowWords": (.stringArray, false),
            "outflowWords": (.stringArray, false),
            "neutralWords": (.stringArray, false),
            "currencyNames": (.stringMap, false),
            "originalAmount": (.string, false),
        ]), true),
        "rules": (.array(.object([
            "when": (.array(.object([
                "field": (.enumeration(StatementTemplate.Field.allCases.map(\.rawValue)), true),
                "equals": (.stringArray, false),
                "matches": (.string, false),
            ])), true),
            "then": (.enumeration(StatementTemplate.Action.allCases.map(\.rawValue)), true),
            "direction": (.enumeration(FlowDirection.allCases.map(\.rawValue)), false),
        ])), false),
        "checks": (.object([
            "balance": (.bool, false),
            "totals": (.object([
                "count": (.string, false),
                "inflow": (.string, false),
                "outflow": (.string, false),
                "neutral": (.string, false),
            ]), false),
        ]), false),
    ])

    func check(_ value: JSONValue, path: String) throws {
        func fail(_ message: String) -> StatementTemplateError { StatementTemplateError(path, message) }
        switch (self, value) {
        case (.string, .string), (.bool, .bool):
            return
        case (.int, .number(let number)) where number == number.rounded():
            return
        case (.stringArray, .array(let array)) where array.allSatisfy(\.isString):
            return
        case (.stringMap, .object(let map)) where map.values.allSatisfy(\.isString):
            return
        case (.enumeration(let allowed), .string(let text)) where allowed.contains(text):
            return
        case (.array(let element), .array(let array)):
            for (index, item) in array.enumerated() { try element.check(item, path: "\(path)[\(index)]") }
        case (.object(let fields), .object(let object)):
            func child(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
            for key in object.keys.sorted() where fields[key] == nil {
                throw StatementTemplateError(child(key), "没有这个键")
            }
            for (key, (shape, required)) in fields.sorted(by: { $0.key < $1.key }) {
                guard let item = object[key], item != .null else {
                    if required { throw StatementTemplateError(child(key), "必填") }
                    continue
                }
                try shape.check(item, path: child(key))
            }
        case (.string, _): throw fail("要是文字")
        case (.int, _): throw fail("要是整数")
        case (.bool, _): throw fail("要是 true 或 false")
        case (.stringArray, _): throw fail("要是文字的数组")
        case (.stringMap, _): throw fail("要是文字对文字")
        case (.enumeration(let allowed), _): throw fail("只能是 \(allowed.joined(separator: "、"))")
        case (.array, _): throw fail("要是数组")
        case (.object, _): throw fail("要是对象 { }")
        }
    }
}

/// 自己读 JSON：分得清 true 和 1（系统的 JSONSerialization 在 Apple 平台上分不清），模板的类型才能查严
enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var isString: Bool { if case .string = self { true } else { false } }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        // 有的编辑器存的 UTF-8 开头带 BOM
        if parser.scalars.first == "\u{FEFF}" { parser.index = 1 }
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.scalars.count else { throw parser.error("JSON 后面还有多余的字") }
        return value
    }

    /// 再写回 JSON（交给 JSONDecoder 读成模板）
    func serialized() -> String {
        switch self {
        case .string(let text): return Self.quote(text)
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { Self.quote($0) + ":" + (fields[$0] ?? .null).serialized() }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + String(scalar.value >> 4, radix: 16) + String(scalar.value & 0xF, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        func error(_ message: String) -> StatementTemplateError {
            let line = scalars[..<min(index, scalars.count)].filter { $0 == "\n" }.count + 1
            return StatementTemplateError("", "第 \(line) 行：\(message)")
        }

        mutating func skipSpace() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "\n" || scalars[index] == "\r" || scalars[index] == "\t" {
                index += 1
            }
        }

        mutating func expect(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw error("看不懂这里") }
                index += 1
            }
        }

        mutating func value() throws -> JSONValue {
            guard index < scalars.count else { throw error("JSON 不完整") }
            switch scalars[index] {
            case "{":
                index += 1
                var fields: [String: JSONValue] = [:]
                skipSpace()
                if index < scalars.count, scalars[index] == "}" {
                    index += 1
                    return .object(fields)
                }
                while true {
                    skipSpace()
                    guard index < scalars.count, scalars[index] == "\"" else { throw error("这里要一个用双引号括起来的键") }
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    guard fields[key] == nil else { throw error("键 \(key) 写了两次") }
                    fields[key] = try value()
                    skipSpace()
                    guard index < scalars.count else { throw error("JSON 不完整") }
                    if scalars[index] == "," {
                        index += 1
                        continue
                    }
                    if scalars[index] == "}" {
                        index += 1
                        return .object(fields)
                    }
                    throw error("这里少了逗号或 }")
                }
            case "[":
                index += 1
                var items: [JSONValue] = []
                skipSpace()
                if index < scalars.count, scalars[index] == "]" {
                    index += 1
                    return .array(items)
                }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard index < scalars.count else { throw error("JSON 不完整") }
                    if scalars[index] == "," {
                        index += 1
                        continue
                    }
                    if scalars[index] == "]" {
                        index += 1
                        return .array(items)
                    }
                    throw error("这里少了逗号或 ]")
                }
            case "\"":
                return .string(try string())
            case "t":
                try expect("true")
                return .bool(true)
            case "f":
                try expect("false")
                return .bool(false)
            case "n":
                try expect("null")
                return .null
            default:
                let start = index
                while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[start..<index])
                let text = String(view)
                guard !text.isEmpty, let number = Double(text) else { throw error("看不懂这里") }
                return .number(number)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(out)
                case "\\":
                    guard index < scalars.count else { throw error("文字没写完") }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            try expect("\\u")
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("\\u 写错了") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let decoded = Unicode.Scalar(code) else { throw error("\\u 写错了") }
                        out.append(decoded)
                    default:
                        throw error("文字里的 \\ 后面不能跟 \(escaped)")
                    }
                default:
                    guard scalar.value >= 0x20 else { throw error("文字里有换行，要写成 \\n") }
                    out.append(scalar)
                }
            }
            throw error("文字没写完（少了双引号）")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw error("\\u 后面要 4 位十六进制") }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[index..<index + 4])
            guard let code = UInt32(String(view), radix: 16) else { throw error("\\u 后面要 4 位十六进制") }
            index += 4
            return code
        }
    }
}

/// 日期、时间的写法（`yyyy-MM-dd`、`d MMM`、`HH:mm:ss`）换成正则，从一格文字里取出年月日时分秒
public struct StatementDateFormat: Hashable, Sendable {
    enum Token: Hashable, Sendable { case year4, year2, month, monthName, day, hour, minute, second }

    let regex: String
    let tokens: [Token]

    public var hasYear: Bool { tokens.contains(.year4) || tokens.contains(.year2) }
    public var hasDate: Bool { (tokens.contains(.month) || tokens.contains(.monthName)) && tokens.contains(.day) }
    public var hasTime: Bool { tokens.contains(.hour) && tokens.contains(.minute) }

    public init?(_ format: String) {
        var regex = ""
        var tokens: [Token] = []
        var rest = Substring(format)
        let table: [(String, Token, String)] = [
            ("yyyy", .year4, "(\\d{4})"), ("yy", .year2, "(\\d{2})"),
            ("MMM", .monthName, "([A-Za-z]{3})"), ("MM", .month, "(\\d{2})"), ("M", .month, "(\\d{1,2})"),
            ("dd", .day, "(\\d{2})"), ("d", .day, "(\\d{1,2})"),
            ("HH", .hour, "(\\d{2})"), ("H", .hour, "(\\d{1,2})"),
            ("mm", .minute, "(\\d{2})"), ("ss", .second, "(\\d{2})"),
        ]
        while !rest.isEmpty {
            if let (literal, token, pattern) = table.first(where: { rest.hasPrefix($0.0) }) {
                guard !tokens.contains(token) else { return nil }
                tokens.append(token)
                regex += pattern
                rest = rest.dropFirst(literal.count)
            } else if let first = rest.first {
                if first.isLetter, first.isASCII { return nil }
                regex += first.isWhitespace ? "\\s*" : NSRegularExpression.escapedPattern(for: String(first))
                rest = rest.dropFirst()
            }
        }
        guard !tokens.isEmpty else { return nil }
        self.regex = regex
        self.tokens = tokens
    }

    public struct Parts: Hashable, Sendable {
        public var year: Int?
        public var month: Int?
        public var day: Int?
        public var hour: Int?
        public var minute: Int?
        public var second: Int?
    }

    /// 在一格文字里找第一个符合的地方（前后可以有别的字）
    public func parse(_ text: String) -> Parts? {
        guard let expression = try? NSRegularExpression(pattern: "(?<![0-9])" + regex + "(?![0-9])") else { return nil }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let parts = parts(match, in: text) { return parts }
        }
        return nil
    }

    private func parts(_ match: NSTextCheckingResult, in text: String) -> Parts? {
        var parts = Parts()
        for (index, token) in tokens.enumerated() {
            guard let range = Range(match.range(at: index + 1), in: text) else { return nil }
            let value = String(text[range])
            switch token {
            case .year4: parts.year = Int(value)
            case .year2: parts.year = Int(value).map { 2000 + $0 }
            case .month: parts.month = Int(value)
            case .monthName:
                guard let month = Self.monthNames.firstIndex(of: value.lowercased()) else { return nil }
                parts.month = month + 1
            case .day: parts.day = Int(value)
            case .hour: parts.hour = Int(value)
            case .minute: parts.minute = Int(value)
            case .second: parts.second = Int(value)
            }
        }
        if let month = parts.month, !(1...12).contains(month) { return nil }
        if let day = parts.day, !(1...31).contains(day) { return nil }
        if let hour = parts.hour, !(0...23).contains(hour) { return nil }
        if let minute = parts.minute, !(0...59).contains(minute) { return nil }
        if let second = parts.second, !(0...59).contains(second) { return nil }
        return parts
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
}
