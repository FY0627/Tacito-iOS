import Foundation
import BKModel
import BKDatabase

// 导入账单（ADR 0029）：几份账单一起读，去掉账单之间重复的同一笔，再和账本里已有的流水对，没记的补上。

/// 一份账单文件：用哪个模板认出来的，记到哪个账户
public struct StatementFile: Identifiable, Hashable, Sendable {
    /// App 给的编号（同一次导入里不重复）
    public var id: String
    public var name: String
    /// nil：没有哪个模板认得出
    public var reading: StatementReading?
    /// 这份账单是哪个账户的：按账单上的卡号、银行、钱包自动认，认不出或有几个时由用户选
    public var accountID: String?
    /// 可能的账户（同一家银行的卡、同一个钱包），给用户选
    public var candidateIDs: [String]

    public init(id: String, name: String, reading: StatementReading?, accountID: String?, candidateIDs: [String]) {
        self.id = id
        self.name = name
        self.reading = reading
        self.accountID = accountID
        self.candidateIDs = candidateIDs
    }

    /// 能拿来对账：认出来了、核对没有对不上、选好了账户
    public var isReady: Bool { (reading?.isUsable ?? false) && accountID != nil }
}

/// 对账后的一笔
public struct StatementEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case expense, income, refund, transfer, interest, fee }

    public enum Status: Hashable, Sendable {
        /// 账本里已经有：那一笔的编号
        case recorded(String)
        /// 账本里没有
        case missing
        /// 用尾号 `cardTail` 的卡付的，这张卡还没添加
        case noAccount
    }

    public var id: String
    public var accountID: String?
    public var date: WallClock
    /// 记账的币种、金额（账户扣的）
    public var amountMinor: Int64
    public var currency: CurrencyCode
    public var direction: FlowDirection
    public var kind: Kind
    public var counterparty: String
    public var summary: String
    /// 外币交易的原币金额
    public var original: Money?
    /// 在哪几份账单里（「支付宝账单.csv 第 12 笔」），去重合并的有几处
    public var sources: [String]
    public var status: Status
    /// 转帐的另一边（也是一笔 `StatementEntry`）
    public var peerID: String?
    public var cardTail: String?
    /// 补记时写进来源：第一份账单的文件名、模板名称
    var fileName: String
    var templateName: String
}

public struct StatementPreview: Hashable, Sendable {
    public var entries: [StatementEntry]
    /// 不记的：交易关闭、同一个账户里挪钱（朝朝宝、余额宝）
    public var skippedCount: Int
    /// 账单上没写是收还是支、模板也没定的（不导入）
    public var unclearCount: Int
    /// 账本里有、账单上没有的（账单覆盖的日期、账户里）
    public var extraRecords: [RecordRow]

    public var missing: [StatementEntry] { entries.filter { $0.status == .missing } }
    public var recorded: [StatementEntry] { entries.filter { if case .recorded = $0.status { true } else { false } } }
    public var noAccount: [StatementEntry] { entries.filter { $0.status == .noAccount } }
}

public struct StatementImportSummary: Hashable, Sendable {
    /// 这次导入的编号：撤销时用
    public var batchID: String
    public var records: Int
}

// MARK: - 账户

enum StatementAccounts {
    /// 账单是哪个账户的：记住的 → 账单上的卡号 / 账号 → 这家银行（这个钱包）只有一个账户
    static func resolve(_ reading: StatementReading, accounts: [Account], remembered: String?) -> (accountID: String?, candidates: [String]) {
        let active = accounts.filter { !$0.deleted && !$0.archived }
        let candidates: [Account]
        switch reading.issuer.type {
        case .wallet:
            let profile = WalletDirectory.profile(id: reading.issuer.wallet)
            candidates = active.filter { account in
                guard account.cardType == .wallet else { return false }
                if let id = account.bankID { return id == reading.issuer.wallet }
                let name = account.name.lowercased()
                return profile?.accountNames.contains { name.contains($0) } ?? false
            }
        case .bank:
            candidates = active.filter { $0.isCard && sameBank($0.bankName, reading.issuer.name) }
        }
        let ids = candidates.map(\.id)
        if let remembered, active.contains(where: { $0.id == remembered }) { return (remembered, ids.contains(remembered) ? ids : [remembered] + ids) }
        if let number = reading.accountNumber {
            let byNumber = active.filter { $0.isCard && matches(number: number, $0) }
            if byNumber.count == 1 { return (byNumber[0].id, ids.contains(byNumber[0].id) ? ids : [byNumber[0].id] + ids) }
        }
        return (candidates.count == 1 ? candidates[0].id : nil, ids)
    }

    /// 「招商银行」和「招行」「中国招商银行」这类：一个包含另一个，或去掉「中国」「银行」后一样
    static func sameBank(_ a: String, _ b: String) -> Bool {
        func core(_ s: String) -> String {
            StatementEngine.normalized(s).replacingOccurrences(of: "中国", with: "").replacingOccurrences(of: "银行", with: "")
                .replacingOccurrences(of: "銀行", with: "").replacingOccurrences(of: "bank", with: "")
        }
        let x = StatementEngine.normalized(a), y = StatementEngine.normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x) || (!core(a).isEmpty && core(a) == core(b))
    }

    /// 账单上的号码（可能打码）是不是这个账户：完整卡号、账号逐位比（打码位当任意数字），都没填时比后四位
    static func matches(number: String, _ account: Account) -> Bool {
        let pattern = Array(Account.numberPattern(number))
        guard pattern.count >= 4 else { return false }
        func same(_ full: String) -> Bool {
            let target = Array(Account.numberPattern(full))
            guard target.count == pattern.count else { return false }
            return zip(pattern, target).allSatisfy { $0 == "X" || $1 == "X" || $0 == $1 }
        }
        if let card = account.cardNumber, same(card) { return true }
        if let identifier = account.accountNumber, same(identifier) { return true }
        if account.cardNumber == nil, account.accountNumber == nil {
            let tail = String(pattern.suffix(4))
            return tail.allSatisfy(\.isNumber) && tail == account.last4 && pattern.count >= 12
        }
        return false
    }

    /// 「某某银行储蓄卡(0001)」「MASTERCARD(0002)」里的尾号
    static func cardTail(_ text: String) -> String? {
        StatementEngine.firstMatch("\\((?<tail>\\d{4})\\)", in: text, group: "tail")
    }

    /// 尾号是这个的卡；几张时用写着的银行名称挑
    static func card(tail: String, hint: String, accounts: [Account]) -> Account? {
        let cards = accounts.filter { $0.isCard && !$0.deleted && $0.last4 == tail }
        if cards.count <= 1 { return cards.first }
        let named = cards.filter { StatementEngine.normalized(hint).contains(StatementEngine.normalized($0.bankName)) }
        return named.count == 1 ? named[0] : nil
    }

    /// 对方写的是自己的另一张卡：对方信息里的卡号（12–19 位，打码的也行）对得上自己的卡。
    /// 支付宝用户号（2088 开头）不算卡号
    static func ownAccount(in text: String, excluding: String?, accounts: [Account]) -> Account? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9][0-9*Xx-]{6,}[0-9]") else { return nil }
        var found: [Account] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let run = String(text[range])
            let pattern = Account.numberPattern(run)
            guard (8...30).contains(pattern.count), !pattern.hasPrefix("2088") else { continue }
            for account in accounts where account.isCard && !account.deleted && account.id != excluding {
                let hit: Bool
                if account.cardNumber != nil || account.accountNumber != nil {
                    hit = matches(number: run, account)
                } else {
                    // 只有后四位：要像一个完整的卡号（15–19 位、没打码）
                    hit = (15...19).contains(pattern.count) && pattern.allSatisfy(\.isNumber) && pattern.hasSuffix(account.last4)
                }
                if hit, !found.contains(where: { $0.id == account.id }) { found.append(account) }
            }
        }
        return found.count == 1 ? found[0] : nil
    }
}

// MARK: - 去重、对账

struct StatementReconciler {
    let accounts: [Account]
    let calendar: Calendar

    /// 账单里的一笔，记到某个账户上的样子。转帐会多出一笔「另一边」（`synthetic`）
    private struct Leg {
        var entry: StatementEntry
        var fileID: String
        var isWallet: Bool
        var synthetic: Bool
    }

    func preview(files: [StatementFile], records: [LedgerRecord]) -> (entries: [StatementEntry], skipped: Int, unclear: Int, matched: Set<String>) {
        var legs: [Leg] = []
        var skipped = 0, unclear = 0
        for file in files where file.isReady {
            guard let reading = file.reading else { continue }
            let isWallet = reading.issuer.type == .wallet
            for row in reading.rows {
                if row.action == .skip || row.action == .internal {
                    skipped += 1
                    continue
                }
                guard let direction = row.direction else {
                    unclear += 1
                    continue
                }
                var kind = Self.kind(row.action, direction)
                var account = file.accountID
                var counter: Account?
                var missingTail: String?
                let tail = StatementAccounts.cardTail(row.paidWith) ?? (kind == .transfer ? StatementAccounts.cardTail(row.counterparty) : nil)
                if let tail {
                    let hint = row.paidWith + " " + row.counterparty
                    if let card = StatementAccounts.card(tail: tail, hint: hint, accounts: accounts) {
                        // 转帐：卡是另一边；其余：钱从这张卡出（用卡付的）
                        if kind == .transfer { counter = card } else if isWallet { account = card.id }
                    } else if kind != .transfer, isWallet {
                        account = nil
                        missingTail = tail
                    }
                }
                if counter == nil, account != nil, let own = StatementAccounts.ownAccount(in: row.counterparty, excluding: account, accounts: accounts) {
                    counter = own
                    kind = .transfer
                }
                let id = "\(file.id)#\(row.number)"
                var entry = StatementEntry(
                    id: id, accountID: account, date: row.date, amountMinor: row.amountMinor, currency: row.currency, direction: direction,
                    kind: kind, counterparty: row.counterparty.isEmpty ? row.description : row.counterparty, summary: row.summary,
                    original: row.original, sources: ["\(file.name) 第 \(row.number) 笔"], status: account == nil ? .noAccount : .missing,
                    peerID: nil, cardTail: missingTail, fileName: file.name, templateName: reading.templateName
                )
                if let counter {
                    let peerID = id + "~"
                    entry.peerID = peerID
                    // 另一边：方向相反，金额一样（换汇的两边金额不同，账单上看不到另一边，按同一币种）
                    let peer = StatementEntry(
                        id: peerID, accountID: counter.id, date: row.date, amountMinor: row.amountMinor, currency: row.currency,
                        direction: direction.opposite, kind: .transfer, counterparty: entry.counterparty, summary: row.summary, original: nil,
                        sources: [], status: .missing, peerID: id, cardTail: nil, fileName: file.name, templateName: reading.templateName
                    )
                    legs.append(Leg(entry: peer, fileID: file.id, isWallet: false, synthetic: true))
                }
                legs.append(Leg(entry: entry, fileID: file.id, isWallet: isWallet, synthetic: false))
            }
        }

        // 账单之间重复的同一笔合成一笔：同账户、同方向、同币种金额，日期前后 3 天内，每份账单最多一笔。
        // 钱包账单写得最全（商户、时间），先放；另一边（推出来的）最后放
        legs.sort { rank($0) < rank($1) }
        // 两份钱包账单里的不会是同一笔（支付宝、微信各付了一笔同样的钱，银行账单上是两笔）：一笔里最多一份钱包账单
        var clusters: [(entry: StatementEntry, files: Set<String>, hasWallet: Bool)] = []
        var clusterOf: [String: Int] = [:]
        for leg in legs {
            let isWalletLeg = leg.isWallet && !leg.synthetic
            guard let account = leg.entry.accountID else {
                clusterOf[leg.entry.id] = clusters.count
                clusters.append((leg.entry, [leg.fileID], isWalletLeg))
                continue
            }
            let day = Self.day(leg.entry.date)
            let candidates = clusters.indices.filter { index in
                let c = clusters[index].entry
                return c.accountID == account && c.direction == leg.entry.direction && c.currency == leg.entry.currency
                    && c.amountMinor == leg.entry.amountMinor && !clusters[index].files.contains(leg.fileID)
                    && !(isWalletLeg && clusters[index].hasWallet) && abs(Self.day(c.date) - day) <= 3
            }
            // 日期最近的；一样近的，对方写的字（「*明」「***ex」）和钱包账单上的对方重合得多的
            let best = candidates.min { a, b in
                let da = abs(Self.day(clusters[a].entry.date) - day), db = abs(Self.day(clusters[b].entry.date) - day)
                if da != db { return da < db }
                return Self.overlap(clusters[a].entry.counterparty, leg.entry.counterparty) > Self.overlap(clusters[b].entry.counterparty, leg.entry.counterparty)
            }
            if let best {
                clusters[best].entry = merged(clusters[best].entry, leg)
                clusters[best].files.insert(leg.fileID)
                clusters[best].hasWallet = clusters[best].hasWallet || isWalletLeg
                clusterOf[leg.entry.id] = best
            } else {
                clusterOf[leg.entry.id] = clusters.count
                clusters.append((leg.entry, [leg.fileID], isWalletLeg))
            }
        }
        let merged = clusters.map(\.entry)
        var entries = merged
        // 另一边的编号换成合并后的那一笔
        for index in entries.indices {
            guard let peer = merged[index].peerID, let target = clusterOf[peer], target != index else {
                entries[index].peerID = nil
                continue
            }
            entries[index].peerID = merged[target].id
            entries[target].peerID = merged[index].id
        }
        pairLooseTransfers(&entries)
        // 只是推出来的另一边（这个账户的账单没导入，或者没写这一笔）：写明从哪份账单推出来
        let sourcesByID = Dictionary(entries.map { ($0.id, $0.sources) }, uniquingKeysWith: { a, _ in a })
        for index in entries.indices where entries[index].sources.isEmpty {
            let from = entries[index].peerID.flatMap { sourcesByID[$0]?.first } ?? entries[index].fileName
            entries[index].sources = ["\(from) 的另一边"]
        }

        // 和账本里的对：同账户、同方向，金额一样（或外币的原币一样、实扣一样），日期前后 3 天内，一笔只对一笔，日期最近的先对
        var used: Set<String> = []
        let order = entries.indices.sorted { Self.day(entries[$0].date) < Self.day(entries[$1].date) }
        for index in order {
            let entry = entries[index]
            guard let account = entry.accountID else { continue }
            let day = Self.day(entry.date)
            let match = records.filter { record in
                record.accountID == account && record.direction == entry.direction && !used.contains(record.id)
                    && Self.sameMoney(record, entry) && abs(recordDay(record) - day) <= 3
            }.min { abs(recordDay($0) - day) < abs(recordDay($1) - day) }
            if let match {
                used.insert(match.id)
                entries[index].status = .recorded(match.id)
            }
        }
        entries.sort { (Self.day($0.date), $0.date.hour ?? 0, $0.date.minute ?? 0, $0.id) < (Self.day($1.date), $1.date.hour ?? 0, $1.date.minute ?? 0, $1.id) }
        return (entries, skipped, unclear, used)
    }

    private func rank(_ leg: Leg) -> Int { leg.synthetic ? 2 : leg.isWallet ? 0 : 1 }

    /// 合并：钱包写的商户、时间更全，留着；交易性质按「转帐 > 退款 > 利息 > 手续费 > 收支」
    private func merged(_ base: StatementEntry, _ leg: Leg) -> StatementEntry {
        var result = base
        result.sources += leg.entry.sources
        if result.date.hour == nil, leg.entry.date.hour != nil { result.date = leg.entry.date }
        if result.counterparty.isEmpty { result.counterparty = leg.entry.counterparty }
        if result.summary.isEmpty { result.summary = leg.entry.summary }
        if result.original == nil { result.original = leg.entry.original }
        let priority: [StatementEntry.Kind] = [.transfer, .refund, .interest, .fee, .expense, .income]
        if let a = priority.firstIndex(of: result.kind), let b = priority.firstIndex(of: leg.entry.kind), b < a { result.kind = leg.entry.kind }
        if result.peerID == nil { result.peerID = leg.entry.peerID }
        return result
    }

    /// 转帐只有一边知道对方是谁时（支付宝「提现」没写到哪张卡）：另一个账户上方向相反、金额一样、前后 2 天内的就是它。
    /// 另一边要么也是转帐，要么一边是钱包、一边是卡（提现到卡上，银行账单写的是「网联收款」）。
    /// 只有一笔对得上才配；同一天同样金额的几笔（提现两次 55 元）对上同样多的几笔时按顺序配
    private func pairLooseTransfers(_ entries: inout [StatementEntry]) {
        let isCard = Dictionary(accounts.map { ($0.id, $0.isCard) }, uniquingKeysWith: { a, _ in a })
        let loose = entries.indices.filter { entries[$0].kind == .transfer && entries[$0].peerID == nil && entries[$0].accountID != nil }
        let groups = Dictionary(grouping: loose) { index -> String in
            let e = entries[index]
            return "\(e.accountID ?? "")|\(e.direction.rawValue)|\(e.currency.rawValue)|\(e.amountMinor)|\(Self.day(e.date))"
        }
        for key in groups.keys.sorted() {
            let members = (groups[key] ?? []).filter { entries[$0].peerID == nil }.sorted { entries[$0].id < entries[$1].id }
            guard let first = members.first else { continue }
            let entry = entries[first]
            let day = Self.day(entry.date)
            let candidates = entries.indices.filter { other in
                let o = entries[other]
                guard other != first, o.peerID == nil, let account = o.accountID, account != entry.accountID,
                      o.direction == entry.direction.opposite, o.currency == entry.currency, o.amountMinor == entry.amountMinor,
                      abs(Self.day(o.date) - day) <= 2, !members.contains(other) else { return false }
                return o.kind == .transfer || isCard[account] != isCard[entry.accountID ?? ""]
            }.sorted { (Self.day(entries[$0].date), entries[$0].id) < (Self.day(entries[$1].date), entries[$1].id) }
            guard !candidates.isEmpty else { continue }
            if members.count == 1, candidates.count != 1 { continue }
            if members.count > 1 {
                // 几笔配几笔：对上的要是同一个账户、同一天的
                guard candidates.count == members.count,
                      Set(candidates.map { "\(entries[$0].accountID ?? "")|\(Self.day(entries[$0].date))" }).count == 1 else { continue }
            }
            for (member, other) in zip(members, candidates) {
                entries[member].peerID = entries[other].id
                entries[other].peerID = entries[member].id
                entries[other].kind = .transfer
            }
        }
    }

    /// 两段文字里共同的字（字母、汉字；不算打码的 * 和数字）有几个
    static func overlap(_ a: String, _ b: String) -> Int {
        func letters(_ s: String) -> Set<Character> { Set(s.lowercased().filter { $0.isLetter }) }
        return letters(a).intersection(letters(b)).count
    }

    static func kind(_ action: StatementTemplate.Action?, _ direction: FlowDirection) -> StatementEntry.Kind {
        switch action {
        case .expense?: .expense
        case .income?: .income
        case .refund?: .refund
        case .transfer?: .transfer
        case .interest?: .interest
        case .fee?: .fee
        case .skip?, .internal?, nil: direction == .outflow ? .expense : .income
        }
    }

    static func sameMoney(_ record: LedgerRecord, _ entry: StatementEntry) -> Bool {
        if record.currency == entry.currency, record.amountMinor == entry.amountMinor { return true }
        if record.chargeCurrency == entry.currency, record.settlementMinor == entry.amountMinor { return true }
        if let original = entry.original, record.currency == original.currency, record.amountMinor == original.minorUnits { return true }
        return false
    }

    /// 从公元元年数的第几天（只用来算差几天）
    static func day(_ w: WallClock) -> Int {
        dayNumber(w.year ?? 2000, w.month ?? 1, w.day ?? 1)
    }

    static func dayNumber(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe
    }

    func recordDay(_ record: LedgerRecord) -> Int {
        if let t = record.transactionTime, let y = t.year, let m = t.month, let d = t.day, !t.yearInferred { return Self.dayNumber(y, m, d) }
        let c = calendar.dateComponents([.year, .month, .day], from: record.effectiveAt)
        return Self.dayNumber(c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    /// 账单上的日期（有时间用时间，没有用中午）
    func date(_ w: WallClock) -> Date {
        calendar.date(from: DateComponents(year: w.year, month: w.month, day: w.day, hour: w.hour ?? 12, minute: w.minute ?? 0, second: w.second ?? 0)) ?? Date()
    }
}

// MARK: - LedgerBackend

extension LedgerBackend {
    static let statementAccountKey = "statement.account|"
    static let statementLastBatchKey = "statement.last_batch"

    // MARK: 模板

    public func statementTemplates() async throws -> [StatementTemplate] {
        try await database.read { db in try StatementTemplateDAO.all(db) }
    }

    /// 装上一个模板文件里的模板（同一个编号的换掉旧的）。格式不对抛 `StatementTemplateError`，一个也不装
    @discardableResult
    public func installStatementTemplates(_ data: Data) async throws -> [StatementTemplate] {
        let templates = try StatementTemplate.decode(data)
        let now = clock()
        try await database.write { db in
            for template in templates { try StatementTemplateDAO.save(db, template, now: now) }
        }
        return templates
    }

    public func deleteStatementTemplate(id: String) async throws {
        try await database.write { db in _ = try StatementTemplateDAO.delete(db, id: id) }
    }

    // MARK: 读账单

    /// 用装好的模板认账单、读出每一笔，再认是哪个账户的。认不出的 `reading` 是 nil
    public func readStatement(_ document: StatementDocument, id: String) async throws -> StatementFile {
        let now = clock()
        let calendar = calendar
        return try await database.read { db in
            let templates = try StatementTemplateDAO.all(db)
            guard let template = templates.reversed().first(where: { StatementEngine.matches($0, document) }) else {
                return StatementFile(id: id, name: document.name, reading: nil, accountID: nil, candidateIDs: [])
            }
            let reading = StatementEngine.read(document, with: template, now: now, calendar: calendar)
            let accounts = try AccountDAO.all(db, includeArchived: true)
            let remembered = try SettingsDAO.get(db, Self.statementAccountKey(reading))
            let (account, candidates) = StatementAccounts.resolve(reading, accounts: accounts, remembered: remembered)
            return StatementFile(id: id, name: document.name, reading: reading, accountID: account, candidateIDs: candidates)
        }
    }

    static func statementAccountKey(_ reading: StatementReading) -> String {
        statementAccountKey + reading.templateID + "|" + Account.numberPattern(reading.accountNumber ?? "")
    }

    // MARK: 对账

    /// 几份账单一起对账：账单之间重复的合成一笔，再和账本里的流水对
    public func previewStatementImport(_ files: [StatementFile]) async throws -> StatementPreview {
        let calendar = calendar
        return try await database.read { db in
            let accounts = try AccountDAO.all(db, includeArchived: true, includeDeleted: true)
            let ready = files.filter(\.isReady)
            let days = ready.flatMap { $0.reading?.rows ?? [] }.map(\.date)
            guard let first = days.min(by: { StatementReconciler.day($0) < StatementReconciler.day($1) }),
                  let last = days.max(by: { StatementReconciler.day($0) < StatementReconciler.day($1) }) else {
                return StatementPreview(entries: [], skippedCount: 0, unclearCount: 0, extraRecords: [])
            }
            let reconciler = StatementReconciler(accounts: accounts, calendar: calendar)
            let from = reconciler.date(first).addingTimeInterval(-6 * 86_400)
            let to = reconciler.date(last).addingTimeInterval(6 * 86_400)
            let rows = try RecordDAO.postedRows(db, from: from, to: to, limit: 1_000_000)
            let records = rows.map(\.record)
            let result = reconciler.preview(files: ready, records: records)

            // 账本里有、账单上没有：每份账单覆盖的账户、币种和日期里，没对上的流水
            var extras: [RecordRow] = []
            for file in ready {
                guard let reading = file.reading, let account = file.accountID, !reading.rows.isEmpty else { continue }
                let fileDays = reading.rows.map { StatementReconciler.day($0.date) }
                let currencies = Set(reading.rows.map(\.currency))
                guard let low = fileDays.min(), let high = fileDays.max() else { continue }
                for row in rows where row.record.accountID == account && !result.matched.contains(row.record.id)
                    && currencies.contains(row.record.chargeCurrency ?? row.record.currency) && !extras.contains(where: { $0.record.id == row.record.id }) {
                    let day = reconciler.recordDay(row.record)
                    if day >= low, day <= high { extras.append(row) }
                }
            }
            extras.sort { $0.record.effectiveAt > $1.record.effectiveAt }
            return StatementPreview(
                entries: result.entries, skippedCount: result.skipped, unclearCount: result.unclear,
                extraRecords: try Self.decorate(extras, db: db, calendar: calendar)
            )
        }
    }

    /// 记住这份账单是哪个账户的（下次同一个号码的账单直接认）
    public func rememberStatementAccount(_ file: StatementFile) async throws {
        guard let reading = file.reading, let account = file.accountID else { return }
        try await database.write { db in try SettingsDAO.set(db, Self.statementAccountKey(reading), account) }
    }

    // MARK: 补记、撤销

    /// 把选中的、账本里没有的补记上。转帐两边都补时配成一对。整个在一个事务里
    public func importStatementEntries(_ preview: StatementPreview, selected: Set<String>) async throws -> StatementImportSummary {
        let now = clock()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            let batchID = newID()
            let accounts = Dictionary(try AccountDAO.all(db, includeArchived: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let byID = Dictionary(preview.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let reconciler = StatementReconciler(accounts: Array(accounts.values), calendar: calendar)
            var inserted: [String: LedgerRecord] = [:]
            var count = 0
            for entry in preview.entries where selected.contains(entry.id) && entry.status == .missing {
                guard let accountID = entry.accountID, let account = accounts[accountID] else { continue }
                let ingestID = newID()
                let date = reconciler.date(entry.date)
                let text = ([entry.summary] + entry.sources).joined(separator: "\n")
                try IngestDAO.insertStatement(
                    db, id: ingestID, batchID: batchID, templateName: entry.templateName, fileName: entry.fileName, text: text,
                    receivedAt: date, processedAt: now
                )
                let kind: TransactionKind
                switch entry.kind {
                case .expense: kind = entry.direction == .outflow ? .purchase : .refund
                case .income: kind = entry.direction == .inflow ? .income : .other
                case .refund: kind = entry.direction == .inflow ? .refund : .reversal
                case .interest: kind = entry.direction == .inflow ? .interestIncome : .interestCharge
                case .fee: kind = .fee
                case .transfer:
                    let peerAccount = entry.peerID.flatMap { byID[$0]?.accountID }.flatMap { accounts[$0] }
                    let repayment = account.cardType == .credit || peerAccount?.cardType == .credit
                    kind = repayment ? .repayment : entry.direction == .outflow ? .transferOut : .transferIn
                }
                var time = entry.date
                time.yearInferred = false
                var record = LedgerRecord(
                    id: newID(), accountID: accountID, amountMinor: entry.original?.minorUnits ?? entry.amountMinor,
                    currency: entry.original?.currency ?? entry.currency, direction: entry.direction, kind: kind, status: .posted,
                    counterparty: entry.counterparty.isEmpty ? nil : String(entry.counterparty.prefix(200)),
                    transactionTime: time, receivedAt: date, processedAt: now, source: .statement, ingestID: ingestID, partIndex: 0,
                    bankReference: nil, balanceAfterMinor: nil, includedFeeMinor: nil, note: "", transferGroupID: nil, relatedRecordID: nil, categoryID: nil
                )
                if entry.original != nil { record.setCharge(entry.currency, actualMinor: entry.amountMinor, account: account) }
                // 转帐另一边这次也补：配成一对
                if let peer = entry.peerID, let other = inserted[peer] {
                    let group = other.transferGroupID ?? newID()
                    record.transferGroupID = group
                    if other.transferGroupID == nil {
                        var updated = other
                        updated.transferGroupID = group
                        try RecordDAO.update(db, updated)
                        inserted[peer] = updated
                    }
                }
                guard try RecordDAO.insertIfAbsent(db, record, dedupeKey: "s|" + ingestID, now: now) else { continue }
                try RecordDAO.addEvidence(db, recordID: record.id, ingestID: ingestID, source: .statement, at: now)
                inserted[entry.id] = record
                count += 1
            }
            for record in inserted.values where record.transferGroupID == nil {
                try Categorizer(db: db, calendar: calendar).categorize(recordID: record.id)
            }
            try SettingsDAO.set(db, Self.statementLastBatchKey, batchID)
            return StatementImportSummary(batchID: batchID, records: count)
        }
    }

    /// 上次导入账单补记的（还没撤销的）编号
    public func lastStatementImport() async throws -> String? {
        try await database.read { db in
            guard let batch = try SettingsDAO.get(db, Self.statementLastBatchKey), !batch.isEmpty else { return nil }
            return try IngestDAO.statementRecordIDs(db, batchID: batch).isEmpty ? nil : batch
        }
    }

    /// 撤销一次导入账单：删掉那次补记的流水。返回删了几笔
    @discardableResult
    public func undoStatementImport(batchID: String) async throws -> Int {
        try await database.write { db in
            let ids = try IngestDAO.statementRecordIDs(db, batchID: batchID)
            for id in ids { try RecordDAO.delete(db, id: id) }
            try db.run("DELETE FROM ingests WHERE source = ? AND message_id = ?", [SourceKind.statement.rawValue, batchID])
            if try SettingsDAO.get(db, Self.statementLastBatchKey) == batchID { try SettingsDAO.set(db, Self.statementLastBatchKey, "") }
            return ids.count
        }
    }
}
