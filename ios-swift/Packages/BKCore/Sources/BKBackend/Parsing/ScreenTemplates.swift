import Foundation
import BKModel

/// 截图模板（ADR 0028）：用户点出截图上哪段是金额、卡号、对方，做成模板；之后同样的页面按模板认。纯函数，不访问数据库。
///
/// 截图的文字是 `ScreenLayout.text` 排好的：一行一行，一行里各段用两个空格隔开，所以「第几行第几段」和编辑页上点的框对得上。
/// - 做模板：没点到、不含数字的段是页面上固定的字（`anchors`）；点到的每样东西找一段固定的字挨着它
///   （同一行左边、上面、下面），找法要在这张截图上找回点到的那一段才算数；
/// - 认截图：固定的字大部分都在（挨着字段的那几段必须在），再按找法读出金额、卡号、对方。
public enum ScreenTemplates {
    /// 第几行第几段（从 0 数）
    public struct Cell: Hashable, Sendable {
        public var row: Int
        public var column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public enum BuildError: Error, Equatable, Sendable {
        case missingAmount
        case invalidAmount
        case invalidCardTail
        case emptyCounterparty
        /// 固定的字太少，会认错别的截图
        case tooGeneric
        /// 点到的这样东西旁边没有能当记号的字
        case unreachable(ScreenTemplateField.Role)

        public var message: String {
            switch self {
            case .missingAmount: "还没点金额"
            case .invalidAmount: "点到的金额里没有像 12.00 这样的数"
            case .invalidCardTail: "点到的卡号里没有 4 位数字"
            case .emptyCounterparty: "点到的对方没有字"
            case .tooGeneric: "这张截图上固定的字太少，做成模板会认错别的截图"
            case .unreachable(.amount): "金额旁边找不到固定的字，换一段试试"
            case .unreachable(.cardTail): "卡号旁边找不到固定的字，换一段试试"
            case .unreachable(.counterparty): "对方旁边找不到固定的字，换一段试试"
            }
        }
    }

    /// 用模板从一张截图里认出的内容
    public struct Hit: Sendable, Hashable {
        public var amount: AmountText
        public var cardTail: String?
        public var counterparty: String?
        public var snippet: String
        /// 截图上写的是收进来还是付出去（`direction(on:amountCell:digits:)`）；看不出、两种都写了是 nil
        public var direction: FlowDirection?
    }

    /// 固定的字合起来至少要有这么多个字（汉字、字母）
    static let minimumLetters = 6
    /// 认截图时固定的字至少要在这么多（广告每次不一样，不要求全在）
    static let presentShare = 0.6

    private static let edges = Rx(#"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$"#)
    /// 「¥12.00」「-12.00」「+1,234.00」「12.00元」：要有两位小数；后面跟着数字、百分号的不算（收益率）
    private static let amountPattern = Rx(#"(?<![0-9.,])(?:[-+]\s*)?(?:[¥Y]\s*)?(?:[-+]\s*)?((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![0-9%])"#, caseInsensitive: false)
    /// 整段只是一个带 ¥ 的金额、后面紧跟着多一位数字：金额旁边的小图标（ⓘ）认成了数字（「+￥0.630」）。
    /// 人民币只有两位小数，多的这一位不算。要有 ¥，免得把汇率（6.8235）这类当成金额
    private static let iconTailAmount = Rx(#"^[-+]?\s*[¥Y]\s*[-+]?\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\d$"#, caseInsensitive: false)
    private static let tailPattern = Rx(#"\((\d{4})\)|尾号\s*(\d{4})|(?<![0-9])(\d{4})(?![0-9])"#)
    /// 整段只写着收进来、付出去的字（「收入」「支出」「转入成功」）。同一种页面收入、支出各一种写法，
    /// 不拿它当找金额的记号，也不算进「固定的字大部分都在」
    private static let inflowWord = Rx(#"^(?:收入|入账|存入|转入|收款|到账|已到账|已收款|退款)(?:成功)?$"#)
    private static let outflowWord = Rx(#"^(?:支出|出账|转出|付款|消费|扣款|支付|已支付)(?:成功)?$"#)
    /// 金额前面的正负号（OCR 会把负号认成破折号、减号）
    private static let signedAmount = Rx(#"^[^0-9+\-−–—]*([+\-−–—])\s*[¥Y]?\s*\d"#, caseInsensitive: false)

    // MARK: 排成行、段

    /// 截图的文字拆成行和段
    public static func page(_ text: String) -> [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
            row.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    /// 比较用的写法：整理全角、繁体，去掉两头的符号（对勾认成的「•」「♥」、箭头「>」），去掉空白，不分大小写
    static func key(_ text: String) -> String {
        edges.replace(TextNormalizer.normalize(text), with: "").filter { !$0.isWhitespace }.lowercased()
    }

    /// 能当固定的字：没有数字，至少两个字
    static func isAnchor(_ text: String) -> Bool {
        let k = key(text)
        guard !k.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return false }
        return k.filter(\.isLetter).count >= 2
    }

    /// 整段（或者「交易类型: 收入」冒号后面）写的是收进来还是付出去
    static func directionWord(_ text: String) -> FlowDirection? {
        let k = key(text)
        if inflowWord.test(k) { return .inflow }
        if outflowWord.test(k) { return .outflow }
        return nil
    }

    // MARK: 收入还是支出

    /// 截图上写的是收进来还是付出去：
    /// 1. 点到的金额前面写了「+」「-」；
    /// 2. 页面上另有一段带正负号、数一样的金额（点的是「交易金额: 56.78」，上面大字是「¥ +56.78」）；
    /// 3. 整段写着「收入」「支出」这类字（标题、「交易类型: 收入」）。
    /// 看不出、两种都写了是 nil
    static func direction(on page: [[String]], amountCell: Cell, digits: String) -> FlowDirection? {
        func sign(_ text: String) -> FlowDirection? {
            let ns = NSString(string: TextNormalizer.normalize(text))
            guard let match = signedAmount.first(ns), let symbol = match.group(1, in: ns) else { return nil }
            return symbol == "+" ? .inflow : .outflow
        }
        if let own = sign(page[amountCell.row][amountCell.column]) { return own }
        let plain = digits.replacingOccurrences(of: ",", with: "")
        let signs = Set(page.joined().compactMap { text -> FlowDirection? in
            guard amount(in: text)?.replacingOccurrences(of: ",", with: "") == plain else { return nil }
            return sign(text)
        })
        if signs.count == 1 { return signs.first }
        let words = Set(page.joined().compactMap { text -> FlowDirection? in
            if let found = directionWord(text) { return found }
            guard let colon = text.lastIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
            return directionWord(String(text[text.index(after: colon)...]))
        })
        return words.count == 1 ? words.first : nil
    }

    // MARK: 读一段

    static func amount(in text: String) -> String? {
        amountMatch(in: text).map { $0.text.substring(with: $0.digits) }
    }

    /// 金额在整理过的写法里的位置：`digits` 是数字，`whole` 从数字开头到这次匹配结束（图标认成的那一位也算在里面）
    private static func amountMatch(in text: String) -> (text: NSString, digits: NSRange, whole: NSRange)? {
        let ns = NSString(string: TextNormalizer.normalize(text))
        guard let m = amountPattern.first(ns) ?? iconTailAmount.first(ns) else { return nil }
        let digits = m.range(at: 1)
        guard digits.location != NSNotFound else { return nil }
        return (ns, digits, NSRange(location: digits.location, length: NSMaxRange(m.range) - digits.location))
    }

    static func tail(in text: String) -> String? {
        let ns = NSString(string: TextNormalizer.normalize(text))
        guard let m = tailPattern.matches(ns).last else { return nil }
        return m.group(1, in: ns) ?? m.group(2, in: ns) ?? m.group(3, in: ns)
    }

    static func name(in text: String) -> String? {
        let trimmed = edges.replace(TextNormalizer.normalize(text), with: "").trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: \.isLetter), amount(in: trimmed) == nil else { return nil }
        return trimmed
    }

    static func value(_ role: ScreenTemplateField.Role, in text: String) -> String? {
        switch role {
        case .amount: amount(in: text)
        case .cardTail: tail(in: text)
        case .counterparty: name(in: text)
        }
    }

    // MARK: 按找法找

    /// 一段固定的字在哪：先找整段就是它的；再找它开头、后面空一格接着别的（「付款方式 招商银行储蓄卡(1234)」认成了一段），
    /// 这时后面那部分（`rest`）也算在它右边
    private static func find(_ anchor: String, in page: [[String]]) -> (cell: Cell, rest: String?)? {
        for (r, row) in page.enumerated() {
            for (c, text) in row.enumerated() where key(text) == anchor {
                return (Cell(row: r, column: c), nil)
            }
        }
        for (r, row) in page.enumerated() {
            for (c, text) in row.enumerated() {
                guard let space = text.firstIndex(where: \.isWhitespace), key(String(text[..<space])) == anchor else { continue }
                return (Cell(row: r, column: c), String(text[space...]))
            }
        }
        return nil
    }

    /// 按找法找到的那一段和读出的内容。往上下找时跳过固定的字（`anchors`）
    static func locate(_ field: ScreenTemplateField, in page: [[String]], anchors: Set<String>) -> (cell: Cell, value: String)? {
        guard let found = find(field.anchor, in: page) else { return nil }
        let start = found.cell
        func check(_ r: Int, _ c: Int) -> (cell: Cell, value: String)? {
            let text = page[r][c]
            guard !anchors.contains(key(text)), let value = value(field.role, in: text) else { return nil }
            return (Cell(row: r, column: c), value)
        }
        switch field.place {
        case .right:
            if let rest = found.rest, let value = value(field.role, in: rest) { return (start, value) }
            for c in page[start.row].indices where c > start.column {
                if let hit = check(start.row, c) { return hit }
            }
        case .below:
            for r in page.indices where r > start.row {
                for c in page[r].indices {
                    if let hit = check(r, c) { return hit }
                }
            }
        case .above:
            for r in stride(from: start.row - 1, through: 0, by: -1) {
                for c in page[r].indices {
                    if let hit = check(r, c) { return hit }
                }
            }
        }
        return nil
    }

    // MARK: 做模板

    /// 用一张截图和点到的几段做模板：固定的字和每样东西的找法。点到的金额必选
    public static func build(text: String, picks: [ScreenTemplateField.Role: Cell]) -> Result<(anchors: [String], fields: [ScreenTemplateField]), BuildError> {
        let page = page(text)
        func cellText(_ cell: Cell) -> String? {
            guard page.indices.contains(cell.row), page[cell.row].indices.contains(cell.column) else { return nil }
            return page[cell.row][cell.column]
        }
        guard let amountCell = picks[.amount] else { return .failure(.missingAmount) }
        guard let text = cellText(amountCell), amount(in: text) != nil else { return .failure(.invalidAmount) }
        if let cell = picks[.cardTail] {
            guard let text = cellText(cell), tail(in: text) != nil else { return .failure(.invalidCardTail) }
        }
        if let cell = picks[.counterparty] {
            guard let text = cellText(cell), name(in: text) != nil else { return .failure(.emptyCounterparty) }
        }

        let picked = Set(picks.values)
        var anchors: [String] = []
        var positions: [(key: String, cell: Cell)] = []
        for (r, row) in page.enumerated() {
            for (c, text) in row.enumerated() where !picked.contains(Cell(row: r, column: c)) && isAnchor(text) {
                let k = key(text)
                guard !anchors.contains(k) else { continue }
                anchors.append(k)
                positions.append((k, Cell(row: r, column: c)))
            }
        }
        guard anchors.joined().filter(\.isLetter).count >= minimumLetters else { return .failure(.tooGeneric) }

        let anchorSet = Set(anchors)
        var fields: [ScreenTemplateField] = []
        for role in ScreenTemplateField.Role.allCases {
            guard let target = picks[role] else { continue }
            // 同一行左边最近的；上面最近的一行（同一行里从右往左）；下面最近的一行
            let left = positions.filter { $0.cell.row == target.row && $0.cell.column < target.column }
                .sorted { $0.cell.column > $1.cell.column }.map { ScreenTemplateField(role: role, anchor: $0.key, place: .right) }
            let above = positions.filter { $0.cell.row < target.row }
                .sorted { ($0.cell.row, $0.cell.column) > ($1.cell.row, $1.cell.column) }.map { ScreenTemplateField(role: role, anchor: $0.key, place: .below) }
            let below = positions.filter { $0.cell.row > target.row }
                .sorted { ($0.cell.row, $0.cell.column) < ($1.cell.row, $1.cell.column) }.map { ScreenTemplateField(role: role, anchor: $0.key, place: .above) }
            // 「收入」「支出」这类字换一种页面就变了，有别的记号时不用它（银行 App 的交易详情：金额在「收入」下面，也在「交易币种」上面）
            let candidates = left + above + below
            let ordered = candidates.filter { directionWord($0.anchor) == nil } + candidates.filter { directionWord($0.anchor) != nil }
            guard let field = ordered.first(where: { locate($0, in: page, anchors: anchorSet)?.cell == target }) else {
                return .failure(.unreachable(role))
            }
            fields.append(field)
        }
        return .success((anchors, fields))
    }

    // MARK: 版面骨架（编辑用）

    /// 示例值：和通知模板还原的示例一样（`MessageTemplates.sample`）
    static let sampleAmount = "100.00"
    static let sampleTail = "1234"
    static let sampleCounterparty = "对方"

    /// 做好的模板另存的版面骨架：每段字和位置照原样，点到的金额、卡号、对方换成示例，其他数字都换成 0。
    /// 行、段和原来一样多，固定的字不变，所以用同样的找法在骨架上能找回点到的那几段（`picks(for:in:)`）
    public static func skeleton(
        _ lines: [ScreenTextLine], picks: [ScreenTemplateField.Role: Cell], fields: [ScreenTemplateField], aspect: Double
    ) -> ScreenTemplateLayout {
        let grid = ScreenLayout.grid(lines)
        let page = grid.map { $0.map { ScreenLayout.segment($0.text) } }
        var out: [ScreenTextLine] = []
        for (r, row) in grid.enumerated() {
            for (c, line) in row.enumerated() {
                let cell = Cell(row: r, column: c)
                var text = zeroed(page[r][c])
                if picks[.amount] == cell, let found = amountMatch(in: text) {
                    text = found.text.replacingCharacters(in: found.whole, with: sampleAmount)
                }
                if picks[.cardTail] == cell { text = replacing(tailPattern, group: nil, in: text, with: sampleTail) }
                if picks[.counterparty] == cell {
                    // 标签和对方认成一段的（「收款方 示例小馆」）：留着标签，只换后面
                    let field = fields.first { $0.role == .counterparty }
                    if let field, field.place == .right, let space = text.firstIndex(where: \.isWhitespace), key(String(text[..<space])) == field.anchor {
                        text = String(text[..<space]) + " " + sampleCounterparty
                    } else {
                        text = sampleCounterparty
                    }
                }
                out.append(ScreenTextLine(text: text, x: rounded(line.x), y: rounded(line.y), width: rounded(line.width), height: rounded(line.height)))
            }
        }
        return ScreenTemplateLayout(aspect: rounded(aspect), lines: out)
    }

    /// 在骨架（或者同样的截图）上按模板的找法找回点到的那几段
    public static func picks(for template: ScreenTemplate, in text: String) -> [ScreenTemplateField.Role: Cell] {
        let page = page(text)
        let anchors = Set(template.anchors)
        var picks: [ScreenTemplateField.Role: Cell] = [:]
        for field in template.fields {
            if let found = locate(field, in: page, anchors: anchors) { picks[field.role] = found.cell }
        }
        return picks
    }

    /// 数字都换成 0（全角的也算），别的字不动
    static func zeroed(_ text: String) -> String {
        String(text.map { $0.isNumber && $0.wholeNumberValue != nil ? "0" : $0 })
    }

    /// 换掉最后一个匹配（卡号）或第一个匹配（金额）的数字部分。认不出时原样返回
    private static func replacing(_ rx: Rx, group: Int?, in text: String, with sample: String) -> String {
        let ns = NSString(string: TextNormalizer.normalizeWidth(text))
        let match = group == nil ? rx.matches(ns).last : rx.first(ns)
        guard let match else { return text }
        let indices = group.map { [$0] } ?? Array(1..<match.numberOfRanges)
        guard let range = indices.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound && $0.length > 0 }) else { return text }
        return ns.replacingCharacters(in: range, with: sample)
    }

    /// 位置留 4 位小数就够画：骨架存得小一点
    private static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    // MARK: 认截图

    /// 用模板认一张截图的文字。页面对不上、读不出金额时返回 nil
    public static func match(_ template: ScreenTemplate, text: String) -> Hit? {
        guard let amountField = template.field(.amount), !template.anchors.isEmpty else { return nil }
        let page = page(text)
        var keys = Set<String>()
        for text in page.joined() {
            keys.insert(key(text))
            if let space = text.firstIndex(where: \.isWhitespace) { keys.insert(key(String(text[..<space]))) }
        }
        // 找金额的那段字必须在；卡号、对方那几行可以没有（有的银行 App 支出页没有「交易对象」那一行），没有就不读
        guard keys.contains(amountField.anchor) else { return nil }
        // 「收入」「支出」这类字不算：收入页做的模板，支出页上少了「收入」也是同一种页面
        let fixed = template.anchors.filter { directionWord($0) == nil }
        let present = fixed.filter(keys.contains).count
        guard Double(present) >= (Double(fixed.count) * presentShare).rounded(.up) else { return nil }

        let anchors = Set(template.anchors)
        guard let found = locate(amountField, in: page, anchors: anchors) else { return nil }
        let digits = found.value
        let tail = template.field(.cardTail).flatMap { locate($0, in: page, anchors: anchors)?.value }
        let counterparty = template.field(.counterparty).flatMap { locate($0, in: page, anchors: anchors)?.value }
        let direction = direction(on: page, amountCell: found.cell, digits: digits)
        // 锁定了类型的模板：截图上明明写着反方向（收入页做的模板碰上支出页）不认，不把支出记成收入。
        // 选了记到哪个账户的不比：页面可能是另一边写的（余额宝「转入成功」记成卡的转出）
        if !template.automatic, template.accountID == nil, let direction, direction != template.direction { return nil }
        return Hit(
            amount: AmountText(digits: digits, currencyCandidates: [.cny], preferredCurrency: .cny),
            cardTail: tail, counterparty: counterparty,
            snippet: ([counterparty] + template.anchors.prefix(2).map(Optional.some) + [digits]).compactMap { $0 }.joined(separator: " "),
            direction: direction
        )
    }

    /// 第一个认得出这张截图的模板（新做的在前）
    public static func firstHit(_ templates: [ScreenTemplate], text: String) -> (template: ScreenTemplate, hit: Hit)? {
        for template in templates {
            if let hit = match(template, text: text) { return (template, hit) }
        }
        return nil
    }

    /// 模板认出的一笔：性质、方向是做模板时选的；时间、单号、哪个 App 用截图的通用读法找。
    /// 选了记到哪个账户时，截图上的卡号是转帐的另一边：转帐先算这个账户的收入（支出），
    /// 卡上那笔银行通知来了再合成转帐（`IngestEngine.pairWithCard`，和余额宝转入一样）
    /// 类型选「自动」的：截图上写了收进来是收入、付出去是支出；看不出时进待处理，让用户选「记为支出」「记为收入」
    public static func draft(_ hit: Hit, template: ScreenTemplate, parsed: ParsedMessage) -> EventDraft {
        let otherSide = template.accountID != nil && hit.cardTail != nil
        let direction: FlowDirection? = template.automatic ? hit.direction : template.direction
        var kind: TransactionKind
        if template.automatic {
            kind = switch direction {
            case .inflow: .income
            case .outflow: .purchase
            case nil: .other
            }
        } else {
            kind = template.kind
            if otherSide, kind == .transferIn || kind == .transferOut { kind = template.direction == .inflow ? .income : .purchase }
        }
        return EventDraft(
            amount: hit.amount, direction: direction, kind: kind, status: .posted, counterparty: hit.counterparty,
            cardTail: template.accountID == nil ? hit.cardTail : nil, counterpartyTail: otherSide ? hit.cardTail : nil,
            transactionTime: parsed.firstTime, bankReference: parsed.onlyReference, balanceAfter: nil, includedFee: nil, isSplitFee: false,
            partIndex: 0, bankHint: nil, walletHint: template.accountID == nil && hit.cardTail == nil ? parsed.walletHint : nil,
            evidenceSnippet: hit.snippet
        )
    }
}
