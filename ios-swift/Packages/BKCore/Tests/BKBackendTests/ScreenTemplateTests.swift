import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 截图模板（ADR 0028）。页面是编的：App、商户、卡号、单号都不是真的。
/// 文字照 `ScreenLayout.text` 的样子写：一行里各段用两个空格隔开
final class ScreenTemplateTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: hour, minute: minute, second: second))!
    }

    /// 通用读法认不出的页面：没有「支付成功」「付款方式」这些字
    let walletPage = """
    9:41
    示例钱包
    交易结果
    消费成功
    -23.50
    商户  示例小馆
    扣款账户  示例银行借记卡(0427)
    交易时间  2026-10-24 12:30
    订单编号  12345678901234
    完成
    """

    let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [
        .amount: .init(row: 4, column: 0),
        .counterparty: .init(row: 5, column: 1),
        .cardTail: .init(row: 6, column: 1),
    ]

    func makeTemplate(_ text: String, picks: [ScreenTemplateField.Role: ScreenTemplates.Cell], kind: TransactionKind = .purchase,
                      direction: FlowDirection = .outflow, accountID: String? = nil) throws -> ScreenTemplate {
        let built = try ScreenTemplates.build(text: text, picks: picks).get()
        return ScreenTemplate(
            id: UUID().uuidString, name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: kind, direction: direction,
            accountID: accountID, createdAt: now
        )
    }

    func testBuildKeepsFixedWordsAndNoNumbers() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        XCTAssertEqual(template.anchors, ["示例钱包", "交易结果", "消费成功", "商户", "扣款账户", "交易时间", "订单编号", "完成"])
        XCTAssertFalse(template.anchors.joined().contains { $0.isNumber }, "不保存截图上的数字")
        // 「消费成功」换成退款页就变了：有别的记号时不拿它找金额
        XCTAssertEqual(template.field(.amount), ScreenTemplateField(role: .amount, anchor: "交易结果", place: .below))
        XCTAssertEqual(template.field(.counterparty), ScreenTemplateField(role: .counterparty, anchor: "商户", place: .right))
        XCTAssertEqual(template.field(.cardTail), ScreenTemplateField(role: .cardTail, anchor: "扣款账户", place: .right))
    }

    func testMatchesTheSamePageWithOtherValuesAndAnAd() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        // 对勾认成了「•」，多了一条广告，卡号和标签认成了一段，时间、单号换了
        let other = """
        10:02
        示例钱包
        交易结果
        • 消费成功
        -99.00
        领 8.88 元红包  立即领取
        商户  另一家店
        扣款账户 示例银行借记卡(1111)
        交易时间  2026-10-25 08:01
        订单编号  99999999999999
        完成
        """
        let hit = try XCTUnwrap(ScreenTemplates.match(template, text: other))
        XCTAssertEqual(hit.amount.digits, "99.00")
        XCTAssertEqual(hit.counterparty, "另一家店")
        XCTAssertEqual(hit.cardTail, "1111")
    }

    func testDoesNotMatchAnotherPage() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        let other = "9:41\n示例商城\n订单详情\n¥12.00\n收货地址  示例路\n完成"
        XCTAssertNil(ScreenTemplates.match(template, text: other))
    }

    func testBuildNeedsAnAmountAndEnoughWords() {
        XCTAssertEqual(ScreenTemplates.build(text: walletPage, picks: [:]).failure, .missingAmount)
        XCTAssertEqual(ScreenTemplates.build(text: walletPage, picks: [.amount: .init(row: 1, column: 0)]).failure, .invalidAmount)
        XCTAssertEqual(ScreenTemplates.build(text: "完成\n12.00", picks: [.amount: .init(row: 1, column: 0)]).failure, .tooGeneric)
    }

    func testScreenTemplateRecordsAPageTheParserCannotRead() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let before = try await backend.ingestScreenshot(text: walletPage, capturedAt: at(12, 31))
        XCTAssertEqual(before.outcome, .filtered, "没有模板时认不出")

        _ = try await backend.saveScreenTemplate(try makeTemplate(walletPage, picks: picks))
        let result = try await backend.ingestScreenshot(text: walletPage, capturedAt: at(12, 31))
        XCTAssertEqual(result.recordedCount, 1)
        let rows = try await backend.records(accountID: card.id)
        let record = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(record.amountMinor, 2350)
        XCTAssertEqual(record.direction, .outflow)
        XCTAssertEqual(record.counterparty, "示例小馆")
    }

    /// 记到选的账户（余额宝），截图上的卡是另一边：先算收入，卡上那笔来了合成转帐
    func testFixedAccountWithTheOtherCardPairsIntoATransfer() async throws {
        let backend = try makeBackend()
        let yuebao = try await backend.addAccount(.pocket(name: "余额宝", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let page = "示例理财\n存入成功\n¥5.00\n转出卡  示例银行借记卡(0427)\n完成"
        let template = try makeTemplate(
            page, picks: [.amount: .init(row: 2, column: 0), .cardTail: .init(row: 3, column: 1)],
            kind: .transferIn, direction: .inflow, accountID: yuebao.id
        )
        _ = try await backend.saveScreenTemplate(template)
        _ = try await backend.ingestScreenshot(text: page, capturedAt: at(13, 1))
        let sms = "您账户0427于10月24日13:00在【支付宝-余额宝】发生快捷支付扣款，人民币5.00"
        _ = try await backend.ingest(IngestRequest(text: sms, source: .auto, receivedAt: at(13, 0, 30)))
        let intoRows = try await backend.records(accountID: yuebao.id)
        let outRows = try await backend.records(accountID: card.id)
        let into = try XCTUnwrap(intoRows.first?.record)
        let out = try XCTUnwrap(outRows.first?.record)
        XCTAssertEqual(into.kind, .transferIn)
        XCTAssertNotNil(into.transferGroupID)
        XCTAssertEqual(into.transferGroupID, out.transferGroupID)
    }

    func testSavingATemplateRereadsOpenScreenshotPending() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        // 像付款页（「付款方式」），看不出是付出去还是收进来：进待处理
        let page = "示例钱包\n¥8.00\n付款方式  示例银行借记卡(0427)\n完成"
        let first = try await backend.ingestScreenshot(text: page, capturedAt: at(14, 0))
        XCTAssertEqual(first.pendingCount, 1)
        let ingestID = try XCTUnwrap(first.ingestID)
        let pendingBefore = try await backend.hasOpenPending(ingestID: ingestID)
        XCTAssertTrue(pendingBefore)

        let template = try makeTemplate(page, picks: [.amount: .init(row: 1, column: 0), .cardTail: .init(row: 2, column: 1)])
        let count = try await backend.saveScreenTemplate(template)
        XCTAssertEqual(count, 1)
        let pendingAfter = try await backend.hasOpenPending(ingestID: ingestID)
        XCTAssertFalse(pendingAfter)
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.first?.record.amountMinor, 800)
    }

    // MARK: 小图标拆开

    /// 一段字在截图上每一列有没有字：`blobs` 是一团一团的字（从第几列到第几列、上下边），其余的列空着
    func ink(width: Int, _ blobs: [(ClosedRange<Int>, ClosedRange<Int>)]) -> [ClosedRange<Int>?] {
        (0..<width).map { x in blobs.first { $0.0.contains(x) }?.1 }
    }

    func testSmallIconAtTheEndBecomesItsOwnSegment() {
        // 「+ ¥0.63 ⓘ」认成「+￥0.630」：「+」、「¥0.63」（40 像素高）、隔开 14 像素的 ⓘ（18 像素高）
        let line = ScreenTextLine(text: "+￥0.630", x: 0.3, y: 0.2, width: 0.3, height: 0.04)
        let columns = ink(width: 300, [(0...20, 15...35), (40...230, 5...44), (245...262, 16...33)])
        let parts = ScreenLayout.splitIcons(line, ink: columns)
        XCTAssertEqual(parts.map(\.text), ["+￥0.63", "0"])
        XCTAssertEqual(ScreenLayout.text(parts), "+￥0.63  0", "拆开的还在同一行")
        XCTAssertEqual(parts[1].x, 0.3 + 0.3 * 245 / 300, accuracy: 0.0001)
    }

    func testIconTwoThirdsAsTallAsTheDigitsIsSplit() {
        // 真机截图量的：「+」18 像素高、「¥」「3.55」32 像素高，隔开 14 像素的 ⓘ 21 像素高
        let line = ScreenTextLine(text: "+ ¥ 3.550", x: 0.3, y: 0.2, width: 0.35, height: 0.04)
        let columns = ink(width: 190, [(8...26, 7...24), (41...66, 1...30), (76...151, 0...31), (165...185, 4...24)])
        XCTAssertEqual(ScreenLayout.splitIcons(line, ink: columns).map(\.text), ["+ ¥ 3.55", "0"])
        // 差不多一样高的（80%）不拆
        let tall = ink(width: 190, [(8...26, 7...24), (41...66, 1...30), (76...151, 0...31), (165...185, 3...28)])
        XCTAssertEqual(ScreenLayout.splitIcons(line, ink: tall), [line])
    }

    func testSameHeightWordsPunctuationAndSignsStayTogether() {
        let words = ScreenTextLine(text: "付款方式 招商", x: 0.1, y: 0.5, width: 0.4, height: 0.03)
        let wordInk = ink(width: 200, [(0...110, 0...29), (130...190, 0...29)])
        XCTAssertEqual(ScreenLayout.splitIcons(words, ink: wordInk), [words], "一样高的字中间空一格不拆")

        let done = ScreenTextLine(text: "完成了。", x: 0.1, y: 0.5, width: 0.2, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(done, ink: ink(width: 120, [(0...90, 0...29), (100...106, 22...29)])), [done], "小的标点不拆")

        let sign = ScreenTextLine(text: "+12.00", x: 0.1, y: 0.5, width: 0.2, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(sign, ink: ink(width: 120, [(0...10, 10...20), (25...110, 0...29)])), [sign], "正负号不拆")

        let wide = ScreenTextLine(text: "收益 abc", x: 0.1, y: 0.5, width: 0.3, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(wide, ink: ink(width: 200, [(0...60, 0...29), (80...150, 10...25)])).count, 1, "矮一截但很宽的（一串小字）不拆")
    }

    func testLayoutKeepsSegmentsApart() {
        let lines = [
            ScreenTextLine(text: "付款方式", x: 0.05, y: 0.5, width: 0.2, height: 0.02),
            ScreenTextLine(text: "示例银行  借记卡(0427)", x: 0.5, y: 0.5, width: 0.45, height: 0.02),
            ScreenTextLine(text: "¥8.00", x: 0.4, y: 0.3, width: 0.2, height: 0.04),
        ]
        XCTAssertEqual(ScreenLayout.text(lines), "¥8.00\n付款方式  示例银行 借记卡(0427)", "一段里的空白缩成一个，段和段之间两个空格")
        XCTAssertEqual(ScreenTemplates.page(ScreenLayout.text(lines)).map(\.count), [1, 2])
    }

    // MARK: 版面骨架

    /// 按页面文字排出截图上的段：一行一行往下，一行里各段从左往右
    func lines(_ page: String) -> [ScreenTextLine] {
        ScreenTemplates.page(page).enumerated().flatMap { r, row in
            row.enumerated().map { c, text in
                ScreenTextLine(text: text, x: 0.05 + Double(c) * 0.45, y: 0.02 + Double(r) * 0.06, width: 0.4, height: 0.03)
            }
        }
    }

    func testSkeletonHidesNumbersAndRebuildsTheSameTemplate() throws {
        let original = lines(walletPage)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 1179.0 / 2556)
        let text = ScreenLayout.text(layout.lines)
        XCTAssertEqual(text, """
        0:00
        示例钱包
        交易结果
        消费成功
        -100.00
        商户  对方
        扣款账户  示例银行借记卡(1234)
        交易时间  0000-00-00 00:00
        订单编号  00000000000000
        完成
        """)
        XCTAssertEqual(layout.aspect, 0.4613)
        XCTAssertEqual(layout.lines.count, original.count)

        let template = ScreenTemplate(
            id: "t", name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: .purchase, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        XCTAssertEqual(ScreenTemplates.picks(for: template, in: text), picks, "在骨架上找回原来点的几段")
        let rebuilt = try ScreenTemplates.build(text: text, picks: picks).get()
        XCTAssertEqual(rebuilt.anchors, built.anchors)
        XCTAssertEqual(rebuilt.fields, built.fields)
        let hit = try XCTUnwrap(ScreenTemplates.match(template, text: text))
        XCTAssertEqual(hit.amount.digits, "100.00")
        XCTAssertEqual(hit.cardTail, "1234")
        XCTAssertEqual(hit.counterparty, "对方")
    }

    func testSkeletonWhenLabelAndValueAreOneSegment() throws {
        let page = """
        示例钱包
        转账成功
        ¥0.01
        收款方 示例小馆
        付款方式 示例银行借记卡(0427)
        完成
        """
        let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [
            .amount: .init(row: 2, column: 0), .counterparty: .init(row: 3, column: 0), .cardTail: .init(row: 4, column: 0),
        ]
        let original = lines(page)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 0.5)
        let text = ScreenLayout.text(layout.lines)
        XCTAssertEqual(ScreenTemplates.page(text)[2], ["¥100.00"])
        // 标签只在点到的这一段里，不是固定的字：整段就是对方
        XCTAssertEqual(ScreenTemplates.page(text)[3], ["对方"])
        XCTAssertEqual(ScreenTemplates.page(text)[4], ["付款方式 示例银行借记卡(1234)"])
        let template = ScreenTemplate(
            id: "t", name: "示例", anchors: built.anchors, fields: built.fields, kind: .transferOut, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        XCTAssertEqual(ScreenTemplates.picks(for: template, in: text), picks)
    }

    /// 金额旁边的「ⓘ」认成了一位数字，紧跟在金额后面（「+￥0.630」）：多的这一位不算
    func testIconNextToTheAmountReadAsADigit() throws {
        let page = """
        0:30
        交易详情
        示例汇率补贴
        +￥0.630
        余额￥0.63
        交易卡号  示例卡 0000********3442
        交易类型  境外消费退款
        """
        let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [.amount: .init(row: 3, column: 0)]
        let built = try ScreenTemplates.build(text: page, picks: picks).get()
        XCTAssertEqual(built.fields.first?.anchor, "示例汇率补贴")
        let template = ScreenTemplate(
            id: "t", name: "示例", anchors: built.anchors, fields: built.fields, kind: .refund, direction: .inflow, accountID: nil, createdAt: now
        )
        let other = page.replacingOccurrences(of: "+￥0.630", with: "+￥25.000").replacingOccurrences(of: "余额￥0.63", with: "余额￥25.63")
        XCTAssertEqual(ScreenTemplates.match(template, text: other)?.amount.digits, "25.00")

        XCTAssertNil(ScreenTemplates.amount(in: "6.8235"), "没有 ¥ 的多位小数（汇率）不算")
        XCTAssertNil(ScreenTemplates.amount(in: "+1.0958%"))

        let layout = ScreenTemplates.skeleton(lines(page), picks: picks, fields: built.fields, aspect: 0.5)
        XCTAssertEqual(ScreenTemplates.page(ScreenLayout.text(layout.lines))[3], ["+¥100.00"])
    }

    func testSavedTemplateKeepsItsLayout() async throws {
        let backend = try makeBackend()
        let original = lines(walletPage)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 0.5)
        var template = ScreenTemplate(
            id: "t", name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: .purchase, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        _ = try await backend.saveScreenTemplate(template)
        template.name = "改过的名称"
        _ = try await backend.saveScreenTemplate(template)
        let saved = try await backend.screenTemplates()
        XCTAssertEqual(saved.count, 1, "按原来的标识改，不多出一个")
        XCTAssertEqual(saved.first?.name, "改过的名称")
        XCTAssertEqual(saved.first?.layout, layout)
    }

    // MARK: 类型「自动」

    /// 银行 App 的交易详情：收入、支出是同一种页面，只有标题、金额的正负号和几行字不一样。名字、卡号、金额都是编的
    func bankDetail(_ title: String, _ big: String, time: String, amount: String, who: String?, memo: String, balance: String) -> String {
        var rows = [
            "12:00  5G  79", "详情", title, big, "您尾号为0427的储蓄账户最新交易提醒:",
            "交易币种:  人民币", "交易时间:  \(time)", "交易类型:  \(title)", "交易金额:  \(amount)",
        ]
        if let who { rows.append("交易对象:  \(who)") }
        rows += [
            "交易摘要:  \(memo)", "可用余额:  \(balance)", "赚到钱再放心花!", "活钱管理就用示例宝1号",
            "理财非存款,产品有风险,投资须谨慎(示例银行代销)  广告", "账户查询  明细查询  信用卡申请  稳健投资",
        ]
        return rows.joined(separator: "\n")
    }

    var incomeA: String { bankDetail("收入", "¥ +1,234.50", time: "2026/10/24 09:15:12", amount: "1234.50", who: "示例甲", memo: "汇兑(附言:电子汇入)", balance: "1234.50") }
    var incomeB: String { bankDetail("收入", "¥ +56.78", time: "2026/10/24 09:20:02", amount: "56.78", who: "示例乙", memo: "支付机构提现", balance: "2006.34") }
    var expense: String { bankDetail("支出", "¥ -1,924.50", time: "2026/10/24 09:21:15", amount: "1924.50", who: nil, memo: "实物贵金属购买(配送)", balance: "81.84") }

    /// 点大字的金额和对方，卡号不点
    let bankPicks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [.amount: .init(row: 3, column: 0), .counterparty: .init(row: 9, column: 1)]

    func bankTemplate(automatic: Bool, picks: [ScreenTemplateField.Role: ScreenTemplates.Cell]? = nil) throws -> ScreenTemplate {
        let built = try ScreenTemplates.build(text: incomeA, picks: picks ?? bankPicks).get()
        return ScreenTemplate(
            id: UUID().uuidString, name: "示例银行", anchors: built.anchors, fields: built.fields, kind: .income, direction: .inflow,
            accountID: nil, createdAt: now, automatic: automatic
        )
    }

    func testAmountIsNotFoundByTheIncomeWord() throws {
        let template = try bankTemplate(automatic: true)
        XCTAssertNotEqual(template.field(.amount)?.anchor, "收入", "「收入」换成支出页就没了，不拿它找金额")
    }

    func testAutomaticTemplateRecordsIncomeAndExpenseFromTheSamePage() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        _ = try await backend.addAccount(.pocket(name: "微信", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "wechatpay"))
        _ = try await backend.saveScreenTemplate(try bankTemplate(automatic: true))

        let income = try await backend.ingestScreenshot(text: incomeB, capturedAt: at(12, 0))
        XCTAssertEqual(income.recordedCount, 1)
        let out = try await backend.ingestScreenshot(text: expense, capturedAt: at(12, 1))
        XCTAssertEqual(out.recordedCount, 1, "收入页做的模板也认得出支出页")

        let rows = try await backend.records(accountID: card.id).map(\.record)
        XCTAssertEqual(rows.count, 2, "没点卡号也按页面上的尾号记到这张卡，不记到微信")
        let inflow = try XCTUnwrap(rows.first { $0.direction == .inflow })
        XCTAssertEqual(inflow.amountMinor, 5678)
        XCTAssertEqual(inflow.kind, .income)
        XCTAssertEqual(inflow.counterparty, "示例乙")
        let outflow = try XCTUnwrap(rows.first { $0.direction == .outflow })
        XCTAssertEqual(outflow.amountMinor, 192_450)
        XCTAssertEqual(outflow.kind, .purchase)
    }

    func testFixedTemplateLeavesTheOppositePageAlone() throws {
        let template = try bankTemplate(automatic: false)
        XCTAssertEqual(ScreenTemplates.match(template, text: incomeB)?.amount.digits, "56.78")
        XCTAssertNil(ScreenTemplates.match(template, text: expense), "锁定收入的模板不把支出页记成收入")
    }

    func testAutomaticDirectionFromTheSignTheWordsOrNothing() throws {
        // 点的是「交易金额: 56.78」，没有正负号：看上面大字的「¥ +56.78」
        let rowPicks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [.amount: .init(row: 8, column: 1)]
        let template = try bankTemplate(automatic: true, picks: rowPicks)
        XCTAssertEqual(ScreenTemplates.match(template, text: incomeB)?.direction, .inflow)
        XCTAssertEqual(ScreenTemplates.match(template, text: expense)?.direction, .outflow)
        // 大字没有正负号：看「交易类型: 支出」
        let unsigned = expense.replacingOccurrences(of: "¥ -1,924.50", with: "¥ 1,924.50")
        XCTAssertEqual(ScreenTemplates.match(template, text: unsigned)?.direction, .outflow)
        // 什么都没写：看不出
        let page = ScreenTemplates.page(walletPage.replacingOccurrences(of: "-23.50", with: "23.50").replacingOccurrences(of: "消费成功", with: "交易完成"))
        XCTAssertNil(ScreenTemplates.direction(on: page, amountCell: .init(row: 4, column: 0), digits: "23.50"))
    }

    func testAutomaticTemplateAsksWhenThePageDoesNotSay() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let page = walletPage.replacingOccurrences(of: "-23.50", with: "23.50").replacingOccurrences(of: "消费成功", with: "交易完成")
        let built = try ScreenTemplates.build(text: page, picks: picks).get()
        _ = try await backend.saveScreenTemplate(ScreenTemplate(
            id: "t", name: "示例", anchors: built.anchors, fields: built.fields, kind: .purchase, direction: .outflow,
            accountID: nil, createdAt: now, automatic: true
        ))
        let result = try await backend.ingestScreenshot(text: page, capturedAt: at(12, 31))
        XCTAssertEqual(result.pendingCount, 1)
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .uncertainKind, "看不出收入还是支出：让用户选")
        XCTAssertEqual(pending.first?.candidateAccountIDs, [card.id])
    }

    func testAutomaticFlagIsSaved() async throws {
        let backend = try makeBackend()
        _ = try await backend.saveScreenTemplate(try bankTemplate(automatic: true))
        let saved = try await backend.screenTemplates()
        XCTAssertEqual(saved.first?.automatic, true)
    }

    /// 两个人各转来一样多的钱，前后不到一分钟：截图上的对方不一样，是两笔，不并成一笔
    func testSameAmountFromTwoPeopleIsTwoRecords() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        _ = try await backend.saveScreenTemplate(try bankTemplate(automatic: true))
        let first = bankDetail("收入", "¥ +50.00", time: "2026/10/24 09:15:12", amount: "50.00", who: "示例甲", memo: "转账", balance: "50.00")
        let second = bankDetail("收入", "¥ +50.00", time: "2026/10/24 09:15:58", amount: "50.00", who: "示例乙", memo: "转账", balance: "100.00")
        _ = try await backend.ingestScreenshot(text: first, capturedAt: at(12, 0))
        let result = try await backend.ingestScreenshot(text: second, capturedAt: at(12, 0, 30))
        XCTAssertEqual(result.recordedCount, 1)
        XCTAssertEqual(result.pendingCount, 0)
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(Set(rows.compactMap(\.record.counterparty)), ["示例甲", "示例乙"])

        // 同一笔截了两次：照样并成一笔
        let again = try await backend.ingestScreenshot(text: second, capturedAt: at(12, 2))
        XCTAssertEqual(again.mergedCount, 1)
        XCTAssertTrue(IngestEngine.differentParties("示例甲", "示例乙"))
        XCTAssertFalse(IngestEngine.differentParties("示*甲", "示例甲"))
        XCTAssertFalse(IngestEngine.differentParties(nil, "示例乙"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
