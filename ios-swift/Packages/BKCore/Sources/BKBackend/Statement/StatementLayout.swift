import Foundation
import BKModel

/// PDF、图片上的字排回表格（ADR 0029）：
/// 1. 同一页上下位置差不多的字是一行；
/// 2. 一行里有模板写的全部表头文字，就是表头。每一列从它的表头文字左边开始，到下一列的表头左边为止，字的中点落在哪一列就是哪一列
///    （数字靠右对齐、表头靠左对齐的恒生和两边都靠右的众安都对）；
/// 3. 有金额的那一行是一笔交易的「锚」。一笔交易占几行时，其他行按模板的 `table.rows` 归到锚上：
///    `top` 锚在第一行（中行、众安），`bottom` 锚在最后一行（恒生），`center` 归到上下最近的锚（招行、兴业的格子是上下居中的）；
/// 4. 期初、期末余额的行单独成一行，不归到交易里。
enum StatementLayout {
    struct Line {
        var fragments: [ScreenTextLine]
        var text: String { fragments.map(\.text).joined(separator: " ") }
        var midY: Double { fragments.map(\.midY).reduce(0, +) / Double(max(fragments.count, 1)) }
        var height: Double { fragments.map(\.height).max() ?? 0 }
    }

    /// 一页的字按行排好：上下中点相差不到半个字高、字差不多大的算同一行，每行从左到右。
    /// 字小得多的（页脚的表格编号）就算和交易在同一高度也另成一行
    static func lines(_ fragments: [ScreenTextLine]) -> [Line] {
        let sorted = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.midY < $1.midY }
        var lines: [Line] = []
        for fragment in sorted {
            // 最近几行里找一行高度、位置都对得上的（同一高度可能有大小不同的两行字）
            if let index = lines.indices.suffix(3).last(where: { index in
                let line = lines[index]
                let tolerance = max(min(fragment.height, line.height) * 0.5, 0.0005)
                return abs(fragment.midY - line.midY) <= tolerance && similarSize(fragment.height, line.height)
            }) {
                lines[index].fragments.append(fragment)
                continue
            }
            lines.append(Line(fragments: [fragment]))
        }
        return lines.map { Line(fragments: $0.fragments.sorted { $0.x < $1.x }) }.sorted { $0.midY < $1.midY }
    }

    /// 字的高度差不到三成
    static func similarSize(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return true }
        return min(a, b) / max(a, b) >= 0.7
    }

    /// 表头里一格文字在这一行的哪几段：相邻的几段连起来（去掉空白后）等于这格文字。返回最左边的位置和最右边的位置
    static func locate(_ label: String, in line: Line) -> (x0: Double, x1: Double)? {
        let target = StatementEngine.normalized(label)
        guard !target.isEmpty else { return nil }
        let parts = line.fragments.map { StatementEngine.normalized($0.text) }
        for start in parts.indices {
            var joined = ""
            for end in start..<parts.count {
                joined += parts[end]
                if joined == target { return (line.fragments[start].x, line.fragments[end].x + line.fragments[end].width) }
                if !target.hasPrefix(joined) { break }
            }
        }
        return nil
    }

    private struct Column {
        var label: String
        var x0: Double
    }

    private struct TableLine {
        var cells: [String: [String]]
        var midY: Double
        var height: Double
        var page: Int
        var kind: Kind
        var sectionCurrency: String?
        enum Kind { case anchor, text, balance }
    }

    static func rows(_ pages: [[ScreenTextLine]], _ template: StatementTemplate) -> [TableRow] {
        let header = template.table.header
        let labels = template.allColumnLabels
        let ignores = (template.table.ignore ?? []).compactMap { try? NSRegularExpression(pattern: $0) }
        let stops = (template.table.stop ?? []).map(StatementEngine.normalized).filter { !$0.isEmpty }
        let currencyRegex = template.table.sectionCurrency.flatMap { try? NSRegularExpression(pattern: $0) }
        let amountLabels = [template.columns.amount, template.columns.inflow, template.columns.outflow].compactMap { $0 }
        func ignored(_ text: String) -> Bool {
            ignores.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        }
        func isBalanceLine(_ text: String) -> Bool {
            [template.table.opening, template.table.closing].compactMap { $0 }.contains { StatementEngine.matches($0, text) }
        }

        var columns: [Column]?
        var currentCurrency: String?
        var tableLines: [TableLine] = []
        for (pageIndex, page) in pages.enumerated() {
            let pageLines = lines(page.filter { !ignored($0.text) }).filter { !ignored($0.text) }
            var inTable = false
            var skipLines = 0
            var sinceTable: [Line] = []
            for line in pageLines {
                // 表头：模板写的每一格都找得到
                let found = header.map { locate($0, in: line) }
                if found.allSatisfy({ $0 != nil }) {
                    var located: [Column] = []
                    for label in labels {
                        if let position = locate(label, in: line) { located.append(Column(label: label, x0: position.x0)) }
                    }
                    columns = located.sorted { $0.x0 < $1.x0 }
                    inTable = true
                    // 表头占几行（下面一行英文、一行「( DR=Debit )」这类）：后面几行不是交易
                    skipLines = (template.table.headerLines ?? 1) - 1
                    // 表头上面几行写的币种（众安的「CNY 人民币」）；这一页表头上面没写的，沿用上一个表头的
                    if let currencyRegex {
                        for above in sinceTable.suffix(3).reversed() {
                            let text = above.text
                            if let match = currencyRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                               let range = Range(match.range(withName: "currency"), in: text) {
                                currentCurrency = String(text[range])
                                break
                            }
                        }
                    }
                    sinceTable = []
                    continue
                }
                // 表头上面写币种的那几行：表格外的、上一个表格最后的都算（众安「USD 美元」紧接在人民币那段下面）
                sinceTable.append(line)
                guard inTable, let columns else { continue }
                if skipLines > 0 {
                    skipLines -= 1
                    continue
                }
                if stops.contains(where: { StatementEngine.normalized(line.text).contains($0) }) {
                    inTable = false
                    sinceTable = []
                    continue
                }
                // 每段字按中点放进列里：从这一列表头的左边（留一点余量）到下一列表头的左边
                var cells: [String: [String]] = [:]
                let slack = line.height * 0.3
                for fragment in line.fragments {
                    let center = fragment.x + fragment.width / 2
                    let column = columns.last(where: { $0.x0 - slack <= center }) ?? columns[0]
                    cells[column.label, default: []].append(fragment.text)
                }
                // 金额那一格整格是一个数才是交易（说明文字里的「60 days」不算）
                let hasAmount = amountLabels.contains { label in
                    guard let texts = cells[label], !texts.isEmpty else { return false }
                    return StatementEngine.parseAmount(texts.joined(separator: " "), exponent: 2) != nil
                }
                let kind: TableLine.Kind = isBalanceLine(line.text) ? .balance : hasAmount ? .anchor : .text
                tableLines.append(TableLine(cells: cells, midY: line.midY, height: line.height, page: pageIndex, kind: kind, sectionCurrency: currentCurrency))
            }
        }
        // 表格里的字一样大：比大多数行小得多（页脚的表格编号「IPSSTM0004 09」）或大得多（标题）的不是表格里的
        let heights = tableLines.map(\.height).sorted()
        if !heights.isEmpty {
            let typical = heights[heights.count / 2]
            tableLines.removeAll { !similarSize($0.height, typical) }
        }
        return assemble(tableLines, align: template.table.rows ?? .top)
    }

    /// 几行字合成一笔：按锚的位置分组
    private static func assemble(_ lines: [TableLine], align: StatementTemplate.RowAlign) -> [TableRow] {
        var groups: [[TableLine]] = []
        // 同一笔的几行挨得很近：同一页，上下相差不超过两行高。页脚、页码、表格下面的说明离得远，不会粘到交易上
        func adjacent(_ upper: TableLine, _ lower: TableLine) -> Bool {
            upper.page == lower.page && lower.midY - upper.midY <= max(upper.height, lower.height) * 2 && similarSize(upper.height, lower.height)
        }
        switch align {
        case .top:
            for line in lines {
                switch line.kind {
                case .anchor, .balance:
                    groups.append([line])
                case .text:
                    // 锚下面的行接在这一笔后面；期初余额下面的说明不要
                    if let group = groups.last, let first = group.first, first.kind == .anchor, let last = group.last, adjacent(last, line) {
                        groups[groups.count - 1].append(line)
                    }
                }
            }
        case .bottom:
            var pending: [TableLine] = []
            for line in lines {
                switch line.kind {
                case .text: pending.append(line)
                case .anchor:
                    // 从锚往上数，一行挨着一行的才是这一笔的
                    var taken: [TableLine] = []
                    var lower = line
                    for upper in pending.reversed() {
                        guard adjacent(upper, lower) else { break }
                        taken.insert(upper, at: 0)
                        lower = upper
                    }
                    groups.append(taken + [line])
                    pending = []
                case .balance:
                    groups.append([line])
                    pending = []
                }
            }
        case .center:
            // 先定好锚，每行文字归到同一页上下最近的锚
            var anchorGroup: [Int: Int] = [:]
            for (index, line) in lines.enumerated() where line.kind != .text {
                anchorGroup[index] = groups.count
                groups.append([line])
            }
            let anchors = anchorGroup.keys.sorted()
            for (index, line) in lines.enumerated() where line.kind == .text {
                let candidates = anchors.filter { lines[$0].page == line.page && lines[$0].kind == .anchor }
                guard let nearest = candidates.min(by: { abs(lines[$0].midY - line.midY) < abs(lines[$1].midY - line.midY) }) else { continue }
                // 离得太远的不算（表格下面的说明文字）
                guard abs(lines[nearest].midY - line.midY) <= max(lines[nearest].height, line.height) * 3, let group = anchorGroup[nearest] else { continue }
                groups[group].append(line)
            }
            for index in groups.indices { groups[index].sort { ($0.page, $0.midY) < ($1.page, $1.midY) } }
        }
        return groups.map { group in
            var cells: [String: String] = [:]
            for line in group {
                for (label, texts) in line.cells {
                    let text = texts.joined(separator: " ")
                    cells[label] = cells[label].map { join($0, text) } ?? text
                }
            }
            let anchor = group.first { $0.kind != .text } ?? group[0]
            return TableRow(cells: cells, place: "第 " + String(anchor.page + 1) + " 页", sectionCurrency: anchor.sectionCurrency)
        }
    }

    /// 一格里换行的字接起来：中文接中文不加空格（「无卡快捷支」「付业务」），其余加一个空格
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first else { return a + b }
        if last.value > 0x2E80, first.value > 0x2E80 { return a + b }
        return a + " " + b
    }
}
