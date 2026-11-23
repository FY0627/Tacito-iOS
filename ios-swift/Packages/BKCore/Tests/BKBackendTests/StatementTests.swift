import Foundation
import XCTest
@testable import BKBackend
import BKModel

/// 导入账单（ADR 0029）：模板格式、几种文件的读法、PDF 排回表格、核对余额和合计、几份账单一起对账、补记和撤销。
/// 账单、模板全是编的（银行、商户、卡号、金额都是假的），版式仿照常见的几种账单。
final class StatementTests: XCTestCase {
    // MARK: 模板格式

    /// 最小的模板：一个 CSV，金额带正负号
    static let minimalTemplate = """
    {
      "format": "tacito-statement-template", "version": 1, "id": "test-bank-csv", "name": "测试银行 流水",
      "issuer": { "type": "bank", "name": "测试银行" },
      "detect": { "fileTypes": ["csv"], "contains": ["测试银行交易流水"] },
      "statement": { "accountNumber": "账号：(?<number>[0-9*]+)", "currency": "CNY" },
      "table": { "header": ["日期", "金额", "余额"] },
      "columns": { "date": "日期", "amount": "金额", "balance": "余额", "counterparty": ["对方"], "type": "摘要" },
      "values": { "dateFormats": ["yyyy-MM-dd"] }
    }
    """

    func testMinimalTemplateDecodes() throws {
        let templates = try StatementTemplate.decode(Data(Self.minimalTemplate.utf8))
        XCTAssertEqual(templates.map(\.id), ["test-bank-csv"])
        // 写回 JSON 再读还是一样
        XCTAssertEqual(try StatementTemplate.decode(templates[0].encoded()), templates)
    }

    func testTemplateRejectsUnknownKeysAndWrongTypes() {
        func error(_ replace: String, with: String) -> String? {
            let text = Self.minimalTemplate.replacingOccurrences(of: replace, with: with)
            XCTAssertNotEqual(text, Self.minimalTemplate, "替换没生效：\(replace)")
            do {
                _ = try StatementTemplate.decode(Data(text.utf8))
                return nil
            } catch let error as StatementTemplateError {
                return error.path
            } catch {
                return "?"
            }
        }
        // 多写一个键、写错类型、true 和 1 分得清、正则写错、少了命名分组
        XCTAssertEqual(error("\"version\": 1,", with: "\"version\": 1, \"extra\": 2,"), "extra")
        XCTAssertEqual(error("\"version\": 1", with: "\"version\": \"1\""), "version")
        XCTAssertEqual(error("\"version\": 1", with: "\"version\": true"), "version")
        XCTAssertEqual(error("\"amount\": \"金额\",", with: ""), "columns")
        XCTAssertEqual(error("(?<number>[0-9*]+)", with: "([0-9*]+)"), "statement.accountNumber")
        XCTAssertEqual(error("\"yyyy-MM-dd\"", with: "\"yyyy-QQ\""), "values.dateFormats[0]")
        XCTAssertEqual(error("\"type\": \"bank\"", with: "\"type\": \"broker\""), "issuer.type")
        XCTAssertEqual(error("\"table\": { \"header\"", with: "\"table\": { \"rows\": \"top\", \"header\""), "table.rows")
        // JSON 本身写错
        XCTAssertThrowsError(try StatementTemplate.decode(Data("{ \"format\": ".utf8)))
    }

    func testDateFormats() throws {
        let short = try XCTUnwrap(StatementDateFormat("d MMM"))
        XCTAssertEqual(short.parse("15 Oct")?.month, 10)
        XCTAssertNil(short.parse("15 Foo"))
        let compact = try XCTUnwrap(StatementDateFormat("yyyyMMdd"))
        XCTAssertEqual(compact.parse("20260105")?.day, 5)
        let full = try XCTUnwrap(StatementDateFormat("yyyy-MM-dd HH:mm:ss"))
        let parts = try XCTUnwrap(full.parse("2026-11-05 21:30:01"))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2026, 11, 5, 21, 30, 1])
        XCTAssertNil(StatementDateFormat("yyyy-MM-dd yyyy"), "同一样写两次")
    }

    func testAmounts() {
        XCTAssertEqual(StatementEngine.parseAmount("-1,234.50", exponent: 2), -123_450)
        XCTAssertEqual(StatementEngine.parseAmount("¥12", exponent: 2), 1200)
        XCTAssertEqual(StatementEngine.parseAmount("(3.10)", exponent: 2), -310)
        XCTAssertEqual(StatementEngine.parseAmount("1,982.56 DR", exponent: 2), -198_256)
        XCTAssertEqual(StatementEngine.parseAmount("100", exponent: 0), 100)
        XCTAssertNil(StatementEngine.parseAmount("12.345", exponent: 2), "多出来的小数位不是 0")
        XCTAssertNil(StatementEngine.parseAmount("IPSSTM0004", exponent: 2))
        XCTAssertNil(StatementEngine.parseAmount("60 days", exponent: 2))
    }

    // MARK: 文件

    func testCSVReader() {
        let rows = StatementReaders.csv("\u{FEFF}a,\"b,c\",\"d \"\"e\"\"\"\r\n1, 2\t,3\n\n")
        XCTAssertEqual(rows, [["a", "b,c", "d \"e\""], ["1", "2", "3"]])
    }

    func testInflate() throws {
        let dynamic = try Inflate.decompress([UInt8](StatementFixtures.data(StatementFixtures.deflateDynamic)))
        XCTAssertEqual(Data(dynamic), StatementFixtures.data(StatementFixtures.deflateDynamicText))
        XCTAssertEqual(String(decoding: try Inflate.decompress([UInt8](StatementFixtures.data(StatementFixtures.deflateFixed))), as: UTF8.self), "abcabcabc hello")
        XCTAssertEqual(String(decoding: try Inflate.decompress([UInt8](StatementFixtures.data(StatementFixtures.deflateStored))), as: UTF8.self), "stored block")
        XCTAssertThrowsError(try Inflate.decompress([0xFF, 0xFF]))
    }

    func testXLSXReaderTurnsDateCellsIntoText() throws {
        let grid = try StatementReaders.xlsx(StatementFixtures.data(StatementFixtures.xlsx))
        XCTAssertEqual(grid.first?.first, "测试钱包账单明细")
        let header = try XCTUnwrap(grid.firstIndex { $0.first == "交易时间" })
        XCTAssertEqual(grid[header + 1][0], "2026-01-05 08:30:15")
        XCTAssertEqual(grid[header + 1][4], "12.5")
        XCTAssertEqual(grid[header + 2][4], "100")
        XCTAssertEqual(grid[header + 3][2], "测试银行(1234)")
    }

    func testXLSReader() throws {
        let grid = try StatementReaders.xls(StatementFixtures.data(StatementFixtures.xls))
        XCTAssertEqual(grid.first?.first, "测试银行活期账户交易明细")
        let header = try XCTUnwrap(grid.firstIndex { $0.first == "序号" })
        XCTAssertEqual(grid[header + 1], ["1", "消费", "人民币元", "20260105", "-12.50", "87.50", "Z******0001/测试早餐店"])
        XCTAssertEqual(grid[header + 2][4], "100")
        XCTAssertEqual(grid[header + 2][5], "187.5")
    }

    // MARK: 表格账单：核对余额、合计

    static let bankCSV = """
    测试银行交易流水
    账号：6200000000009999
    日期,摘要,金额,余额,对方
    2026-01-05,消费,-12.50,87.50,测试早餐店
    2026-01-06,转入,100.00,187.50,测试朋友
    ,消费,-7.50,180.00,测试午餐店
    2026-01-08,理财转入,-80.00,100.00,测试理财
    """

    private func bankTemplate(_ extra: String = "") throws -> StatementTemplate {
        let text = Self.minimalTemplate.replacingOccurrences(
            of: "\"values\": { \"dateFormats\": [\"yyyy-MM-dd\"] }",
            with: "\"values\": { \"dateFormats\": [\"yyyy-MM-dd\"] }, \"rules\": [{ \"when\": [{ \"field\": \"type\", \"matches\": \"^理财\" }], \"then\": \"internal\" }]\(extra)"
        )
        return try StatementTemplate.decode(Data(text.utf8))[0]
    }

    private func csvDocument(_ text: String, name: String = "测试.csv") -> StatementDocument {
        StatementDocument(name: name, kind: .csv, content: .grid(StatementReaders.csv(text)))
    }

    func testGridStatementChecksBalanceAndFillsDates() throws {
        let template = try bankTemplate()
        let document = csvDocument(Self.bankCSV)
        XCTAssertTrue(StatementEngine.matches(template, document))
        let reading = StatementEngine.read(document, with: template)
        XCTAssertEqual(reading.accountNumber, "6200000000009999")
        XCTAssertEqual(reading.verification, .passed(["余额 3 笔"]))
        XCTAssertEqual(reading.rows.map(\.amountMinor), [1250, 10000, 750, 8000])
        XCTAssertEqual(reading.rows.map(\.direction), [.outflow, .inflow, .outflow, .outflow])
        // 空的日期沿用上一笔；规则定的「账户里挪钱」
        XCTAssertEqual(reading.rows[2].date.day, 6)
        XCTAssertEqual(reading.rows[3].action, .internal)
        XCTAssertTrue(reading.isUsable)

        // 少读一笔、读错一笔：余额对不上，整份不能用
        let broken = Self.bankCSV.replacingOccurrences(of: "-7.50,180.00", with: "-7.05,180.00")
        let failed = StatementEngine.read(csvDocument(broken), with: template)
        XCTAssertEqual(failed.verification, .failed("第 3 笔后的余额对不上"))
        XCTAssertFalse(failed.isUsable)
    }

    func testGridStatementChecksStatedTotals() throws {
        let template = try bankTemplate(", \"checks\": { \"balance\": false, \"totals\": { \"count\": \"共(?<count>\\\\d+)笔\", \"outflow\": \"支出(?<amount>[0-9.]+)元\" } }")
        let text = "共4笔 支出100.00元\n" + Self.bankCSV
        XCTAssertEqual(StatementEngine.read(csvDocument(text), with: template).verification, .passed(["笔数 4", "支出合计"]))
        let wrong = "共5笔 支出100.00元\n" + Self.bankCSV
        XCTAssertEqual(StatementEngine.read(csvDocument(wrong), with: template).verification, .failed("账单上写 5 笔，读出 4 笔"))
    }

    func testUnreadableDateIsAProblem() throws {
        let text = Self.bankCSV.replacingOccurrences(of: "2026-01-08", with: "2026/01/08")
        let reading = StatementEngine.read(csvDocument(text), with: try bankTemplate())
        XCTAssertEqual(reading.problems, ["第 7 行的日期「2026/01/08」读不出"])
        XCTAssertFalse(reading.isUsable)
    }

    // MARK: PDF：字排回表格

    /// 一段字：位置按 600×800 的页面写，换成 0…1
    private func word(_ text: String, _ x: Double, _ y: Double, size: Double = 10) -> ScreenTextLine {
        ScreenTextLine(text: text, x: x / 600, y: y / 800, width: Double(text.count) * size * 0.55 / 600, height: size / 800)
    }

    /// 右对齐的数字：给右边的位置
    private func number(_ text: String, right: Double, _ y: Double, size: Double = 10) -> ScreenTextLine {
        let width = Double(text.count) * size * 0.55
        return ScreenTextLine(text: text, x: (right - width) / 600, y: y / 800, width: width / 600, height: size / 800)
    }

    private func pdfTemplate(_ table: String, columns: String, values: String = "\"dateFormats\": [\"d MMM\"]", statement: String = "\"currency\": \"HKD\"") throws -> StatementTemplate {
        let text = """
        {
          "format": "tacito-statement-template", "version": 1, "id": "test-pdf", "name": "测试 PDF",
          "issuer": { "type": "bank", "name": "测试银行" },
          "detect": { "fileTypes": ["pdf"], "contains": ["TEST BANK"] },
          "statement": { \(statement) },
          "table": { \(table) },
          "columns": { \(columns) },
          "values": { \(values) }
        }
        """
        return try StatementTemplate.decode(Data(text.utf8))[0]
    }

    /// 恒生那种：表头靠左、数字靠右，一天几笔只在第一笔写日期，金额在一笔的最后一行，期初、期末余额，页脚的小字
    func testBottomAlignedRowsWithLeftHeadersAndRightNumbers() throws {
        let template = try pdfTemplate(
            "\"header\": [\"Date\", \"Transaction Details\", \"Deposit\", \"Withdrawal\", \"Balance\"], \"headerLines\": 2, \"rows\": \"bottom\", \"opening\": \"B/F BALANCE\", \"closing\": \"C/F BALANCE\"",
            columns: "\"date\": \"Date\", \"inflow\": \"Deposit\", \"outflow\": \"Withdrawal\", \"balance\": \"Balance\", \"description\": [\"Transaction Details\"]",
            statement: "\"currency\": \"HKD\", \"date\": { \"pattern\": \"(?<date>\\\\d{1,2} [A-Z][a-z]{2} \\\\d{4})\", \"format\": \"d MMM yyyy\" }"
        )
        let page: [ScreenTextLine] = [
            word("TEST", 40, 20), word("BANK", 80, 20), word("Statement", 300, 20), word("Date", 360, 20), word("14", 400, 20), word("Jan", 420, 20), word("2027", 445, 20),
            word("Date", 40, 100), word("Transaction", 100, 100), word("Details", 165, 100),
            word("Deposit", 320, 100), word("Withdrawal", 400, 100), word("Balance", 490, 100),
            word("(", 490, 110), word("DR=Debit", 496, 110), word(")", 545, 110),
            word("20", 40, 130), word("Dec", 55, 130), word("B/F", 100, 130), word("BALANCE", 120, 130), number("100.00", right: 560, 130),
            word("22", 40, 145), word("Dec", 55, 145), word("FRIEND", 100, 145),
            word("REF001", 100, 155), number("10.00", right: 470, 155),
            word("CASH", 100, 165), word("REBATE", 130, 165),
            word("CREDIT", 100, 175), number("1.00", right: 390, 175), number("91.00", right: 560, 175),
            word("3", 40, 190), word("Jan", 55, 190), word("SHOP", 100, 190),
            word("CNY20.00", 100, 200), word("1.1RT", 160, 200), number("22.00", right: 470, 200), number("69.00", right: 560, 200),
            word("14", 40, 215), word("Jan", 55, 215), word("C/F", 100, 215), word("BALANCE", 120, 215), number("69.00", right: 560, 215),
            // 页脚：字小得多，和表格里的数字在同一列
            word("FORM0004", 430, 175, size: 5), word("09", 400, 175, size: 5),
        ]
        var withOriginal = template
        withOriginal.values.originalAmount = "(?<currency>[A-Z]{3})(?<amount>\\d+\\.\\d{2})\\s+[\\d.]+RT"
        let reading = StatementEngine.read(StatementDocument(name: "a.pdf", kind: .pdf, content: .pages([page])), with: withOriginal)
        XCTAssertEqual(reading.problems, [])
        XCTAssertEqual(reading.verification, .passed(["余额 3 笔"]))
        XCTAssertEqual(reading.rows.map(\.amountMinor), [1000, 100, 2200])
        XCTAssertEqual(reading.rows.map(\.direction), [.outflow, .inflow, .outflow])
        XCTAssertEqual(reading.rows[0].description, "FRIEND REF001")
        XCTAssertEqual(reading.rows[1].description, "CASH REBATE CREDIT")
        // 没写年份：12 月的是账单日期（1 月）的前一年
        XCTAssertEqual(reading.rows[1].date.year, 2026)
        XCTAssertEqual(reading.rows[1].date.day, 22)
        XCTAssertEqual(reading.rows[2].date.year, 2027)
        XCTAssertEqual(reading.rows[2].original, Money(minorUnits: 2000, currency: CurrencyCode("CNY")))
    }

    /// 招行、兴业那种：格子里的字上下居中，对方信息占好几行，表头下面跟着一行英文，表格下面有说明
    func testCenterAlignedRows() throws {
        let template = try pdfTemplate(
            "\"header\": [\"记账日期\", \"交易金额\", \"联机余额\", \"对手信息\"], \"headerLines\": 2, \"rows\": \"center\", \"stop\": [\"温馨提示\"]",
            columns: "\"date\": \"记账日期\", \"amount\": \"交易金额\", \"balance\": \"联机余额\", \"counterparty\": [\"对手信息\"]",
            values: "\"dateFormats\": [\"yyyy-MM-dd\"]", statement: "\"currency\": \"CNY\""
        )
        let page: [ScreenTextLine] = [
            word("TEST", 40, 20), word("BANK", 80, 20),
            word("记账日期", 40, 100), word("交易金额", 150, 100), word("联机余额", 250, 100), word("对手信息", 380, 100),
            word("Date", 40, 112), word("Amount", 150, 112), word("Balance", 250, 112), word("Counter", 380, 112),
            word("测试商店", 380, 128), word("2026-01-05", 40, 140), word("-12.50", 150, 140), word("87.50", 250, 140), word("线上消费", 380, 140), word("0001", 380, 152),
            word("测试朋友", 380, 170), word("2026-01-06", 40, 176), word("100.00", 150, 176), word("187.50", 250, 176), word("6200000000001111", 380, 182),
            word("温馨提示：", 40, 230), word("60", 160, 245), word("days", 175, 245),
        ]
        let reading = StatementEngine.read(StatementDocument(name: "b.pdf", kind: .pdf, content: .pages([page])), with: template)
        XCTAssertEqual(reading.problems, [])
        XCTAssertEqual(reading.verification, .passed(["余额 1 笔"]))
        // 换行的中文接起来不加空格
        XCTAssertEqual(reading.rows.map(\.counterparty), ["测试商店线上消费 0001", "测试朋友 6200000000001111"])
    }

    /// 众安那种：几段，每段一个币种写在表头上面；金额在一笔的第一行，下面是说明；页码离得远不算
    func testTopAlignedSectionsWithCurrencyAboveHeader() throws {
        let template = try pdfTemplate(
            "\"header\": [\"Date\", \"Details\", \"Deposit\", \"Withdrawal\", \"Balance\"], \"rows\": \"top\", \"opening\": \"Opening balance\", \"sectionCurrency\": \"^(?<currency>[A-Z]{3}) Savings\"",
            columns: "\"date\": \"Date\", \"inflow\": \"Deposit\", \"outflow\": \"Withdrawal\", \"balance\": \"Balance\", \"description\": [\"Details\"]",
            values: "\"dateFormats\": [\"d MMM yyyy\"]"
        )
        func header(_ y: Double) -> [ScreenTextLine] {
            [word("Date", 40, y), word("Details", 110, y), number("Deposit", right: 400, y), number("Withdrawal", right: 476, y), number("Balance", right: 551, y)]
        }
        let page: [ScreenTextLine] = [word("TEST", 40, 20), word("BANK", 80, 20), word("HKD", 40, 80), word("Savings", 70, 80)] + header(100) + [
            word("30", 40, 120), word("Sep", 55, 120), word("2026", 75, 120), word("Opening", 110, 120), word("balance", 150, 120), number("23.22", right: 551, 120),
            word("04", 40, 135), word("Oct", 55, 135), word("2026", 75, 135), word("TEST", 110, 135), word("SHOP", 140, 135), number("13.92", right: 476, 135), number("9.30", right: 551, 135),
            word("CNY", 110, 147), word("10.00", 135, 147),
            word("P.1", 500, 400), word("of", 520, 400), word("2", 535, 400),
            word("CNY", 40, 430), word("Savings", 70, 430),
        ] + header(450) + [
            word("30", 40, 470), word("Sep", 55, 470), word("2026", 75, 470), word("Opening", 110, 470), word("balance", 150, 470), number("0.00", right: 551, 470),
            word("18", 40, 485), word("Oct", 55, 485), word("2026", 75, 485), word("Inward", 110, 485), number("14.05", right: 400, 485), number("14.05", right: 551, 485),
        ]
        let reading = StatementEngine.read(StatementDocument(name: "c.pdf", kind: .pdf, content: .pages([page])), with: template)
        XCTAssertEqual(reading.problems, [])
        XCTAssertEqual(reading.verification, .passed(["余额 2 笔"]))
        XCTAssertEqual(reading.rows.map(\.currency.rawValue), ["HKD", "CNY"])
        XCTAssertEqual(reading.rows[0].description, "TEST SHOP CNY 10.00")
        XCTAssertEqual(reading.rows.map(\.section), [0, 1])
    }

    // MARK: 对账

    /// 钱包账单（CSV）：用卡付的、提现到卡上的
    static let walletTemplate = """
    {
      "format": "tacito-statement-template", "version": 1, "id": "test-wallet", "name": "测试钱包 账单",
      "issuer": { "type": "wallet", "name": "支付宝", "wallet": "alipay" },
      "detect": { "fileTypes": ["csv"], "contains": ["测试钱包账单"] },
      "statement": { "currency": "CNY" },
      "table": { "header": ["时间", "对方", "收/支", "金额", "付款方式", "状态"] },
      "columns": { "date": "时间", "amount": "金额", "direction": "收/支", "counterparty": ["对方"], "type": "类型", "paidWith": "付款方式", "status": "状态" },
      "values": { "dateFormats": ["yyyy-MM-dd HH:mm:ss"], "inflowWords": ["收入"], "outflowWords": ["支出"], "neutralWords": ["不计收支"] },
      "rules": [
        { "when": [{ "field": "status", "equals": ["交易关闭"] }], "then": "skip" },
        { "when": [{ "field": "type", "equals": ["提现"] }], "then": "transfer", "direction": "outflow" }
      ]
    }
    """

    static let walletCSV = """
    测试钱包账单
    时间,类型,对方,收/支,金额,付款方式,状态
    2026-01-05 08:30:00,消费,测试早餐店,支出,12.50,测试银行储蓄卡(9999),交易成功
    2026-01-05 09:00:00,消费,测试书店,支出,30.00,余额,交易成功
    2026-01-06 10:00:00,提现,本人,不计收支,50.00,余额,交易成功
    2026-01-07 11:00:00,消费,测试关掉的店,支出,8.00,,交易关闭
    """

    static let bankCSV2 = """
    测试银行交易流水
    账号：6200000000009999
    日期,摘要,金额,余额,对方
    2026-01-05,消费,-12.50,87.50,Z***01/测试早餐店
    2026-01-06,网联收款,50.00,137.50,本人
    2026-01-07,跨行转出,-37.50,100.00,6211111111118888/本人
    2026-01-08,消费,-20.00,80.00,测试超市
    """

    private struct Ledger {
        let backend: LedgerBackend
        let card: Account
        let other: Account
        let wallet: Account
    }

    private func ledger() async throws -> Ledger {
        let now = Date(timeIntervalSince1970: 1_799_000_000) // 2027 年
        let backend = try LedgerBackend.inMemory(clock: { now })
        let card = try await backend.addAccount(AccountDraft(name: "测试卡", bankID: nil, bankName: "测试银行", last4: "9999", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let other = try await backend.addAccount(AccountDraft(name: "另一张卡", bankID: nil, bankName: "别的银行", last4: "8888", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let wallet = try await backend.addAccount(.pocket(name: "支付宝", type: .wallet, currency: .cny, paletteID: "blue", walletID: "alipay"))
        try await backend.installStatementTemplates(Data(Self.minimalTemplate.utf8))
        try await backend.installStatementTemplates(Data(Self.walletTemplate.utf8))
        return Ledger(backend: backend, card: card, other: other, wallet: wallet)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testReconcileMergesDuplicatesPairsTransfersAndSkipsRecorded() async throws {
        let l = try await ledger()
        // 早餐（用卡付的）已经由短信记上了
        try await l.backend.addRecord(ManualEntry(type: .expense, accountID: l.card.id, amountMinor: 1250, currency: .cny, time: day(2026, 1, 5, 8)))
        let bank = try await l.backend.readStatement(csvDocument(Self.bankCSV2, name: "bank.csv"), id: "bank")
        let wallet = try await l.backend.readStatement(csvDocument(Self.walletCSV, name: "wallet.csv"), id: "wallet")
        XCTAssertEqual(bank.accountID, l.card.id, "账单上的卡号尾号对上这张卡")
        XCTAssertEqual(wallet.accountID, l.wallet.id)
        XCTAssertEqual(bank.reading?.verification, .passed(["余额 3 笔"]))

        let preview = try await l.backend.previewStatementImport([bank, wallet])
        XCTAssertEqual(preview.skippedCount, 1, "交易关闭的不记")
        // 早餐：钱包、银行两份账单里各一笔，合成一笔，账本里已经有
        let breakfast = try XCTUnwrap(preview.entries.first { $0.amountMinor == 1250 })
        XCTAssertEqual(breakfast.sources.count, 2)
        XCTAssertEqual(breakfast.accountID, l.card.id)
        XCTAssertEqual(breakfast.counterparty, "测试早餐店")
        guard case .recorded = breakfast.status else { return XCTFail("早餐已经记过了") }
        // 提现：钱包转出、银行「网联收款」配成一对转帐
        let out = try XCTUnwrap(preview.entries.first { $0.amountMinor == 5000 && $0.accountID == l.wallet.id })
        let inflow = try XCTUnwrap(preview.entries.first { $0.amountMinor == 5000 && $0.accountID == l.card.id })
        XCTAssertEqual(out.peerID, inflow.id)
        XCTAssertEqual(inflow.kind, .transfer)
        // 转到自己另一张卡（对方写了卡号）：另一边推出来
        let toOther = try XCTUnwrap(preview.entries.first { $0.amountMinor == 3750 && $0.accountID == l.other.id })
        XCTAssertEqual(toOther.direction, .inflow)
        XCTAssertEqual(toOther.sources, ["bank.csv 第 3 笔 的另一边"])
        XCTAssertEqual(preview.missing.count, 6) // 书店、提现两边、转帐两边、超市

        // 补记、再对一次都记过了、撤销
        let summary = try await l.backend.importStatementEntries(preview, selected: Set(preview.missing.map(\.id)))
        XCTAssertEqual(summary.records, 6)
        let again = try await l.backend.previewStatementImport([bank, wallet])
        XCTAssertEqual(again.missing.count, 0)
        let transfers = try await l.backend.records(filter: RecordFilter(), limit: 50).filter { $0.record.source == .statement && $0.record.transferGroupID != nil }
        XCTAssertEqual(transfers.count, 4, "两对转帐都配成对")
        let lastBatch = try await l.backend.lastStatementImport()
        XCTAssertEqual(lastBatch, summary.batchID)
        let removed = try await l.backend.undoStatementImport(batchID: summary.batchID)
        XCTAssertEqual(removed, 6)
        let afterUndo = try await l.backend.previewStatementImport([bank, wallet])
        XCTAssertEqual(afterUndo.missing.count, 6)
        let noBatch = try await l.backend.lastStatementImport()
        XCTAssertNil(noBatch)
    }

    func testTwoSamePaymentsInOneStatementStayTwo() async throws {
        let l = try await ledger()
        let csv = """
        测试银行交易流水
        账号：6200000000009999
        日期,摘要,金额,余额,对方
        2026-01-05,消费,-5.00,95.00,测试店
        2026-01-05,消费,-5.00,90.00,测试店
        """
        try await l.backend.addRecord(ManualEntry(type: .expense, accountID: l.card.id, amountMinor: 500, currency: .cny, time: day(2026, 1, 5)))
        let bank = try await l.backend.readStatement(csvDocument(csv), id: "bank")
        let preview = try await l.backend.previewStatementImport([bank])
        // 账本里只有一笔：另一笔是漏记，不会因为金额一样就当成同一笔
        XCTAssertEqual(preview.recorded.count, 1)
        XCTAssertEqual(preview.missing.count, 1)
    }

    func testUnknownStatementAndRememberedAccount() async throws {
        let l = try await ledger()
        let unknown = try await l.backend.readStatement(csvDocument("别的账单\n日期,金额\n2026-01-01,1.00"), id: "x")
        XCTAssertNil(unknown.reading)
        // 账单上的卡号对不上任何一张卡（两张同一家银行的卡）：用户选过一次，下次直接认
        let extra = try await l.backend.addAccount(AccountDraft(name: "测试卡二", bankID: nil, bankName: "测试银行", last4: "7777", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let csv = Self.bankCSV.replacingOccurrences(of: "6200000000009999", with: "6200000000005555")
        var file = try await l.backend.readStatement(csvDocument(csv), id: "a")
        XCTAssertNil(file.accountID)
        XCTAssertEqual(Set(file.candidateIDs), [l.card.id, extra.id])
        file.accountID = extra.id
        try await l.backend.rememberStatementAccount(file)
        let again = try await l.backend.readStatement(csvDocument(csv), id: "b")
        XCTAssertEqual(again.accountID, extra.id)
    }

    func testTemplatesReplaceByIDAndDelete() async throws {
        let l = try await ledger()
        let renamed = Self.minimalTemplate.replacingOccurrences(of: "测试银行 流水", with: "测试银行 新流水")
        try await l.backend.installStatementTemplates(Data(renamed.utf8))
        let names = try await l.backend.statementTemplates().map(\.name).sorted()
        XCTAssertEqual(names, ["测试钱包 账单", "测试银行 新流水"])
        try await l.backend.deleteStatementTemplate(id: "test-wallet")
        let left = try await l.backend.statementTemplates().map(\.id)
        XCTAssertEqual(left, ["test-bank-csv"])
    }
}
