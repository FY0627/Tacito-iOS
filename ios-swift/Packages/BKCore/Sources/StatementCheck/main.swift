import Foundation
import BKBackend
import BKModel

// 试读账单模板（ADR 0029）：和 App 用同一套代码。给 skill（.claude/skills/statement-template）和开发者用，App 不用它。
//
//   swift run StatementCheck <模板.json>                         只检查模板格式
//   swift run StatementCheck <模板.json> <账单> [<账单>…]        试读账单
//   swift run StatementCheck <模板文件夹> <账单>… --ledger 账户.json   几份账单一起对账（空账本），看账单之间去重、转帐配对
//
// 模板可以是一个文件，也可以是放模板的文件夹（读里面全部 .json）。
// 账单：.csv（UTF-8 或 GB18030）、.xlsx、.xls，或者 PDF / 图片用 skill 的 extract_pdf.py 读成的 .json（每页的字和位置）。
// 选项：--rows N 列出前 N 笔（默认全部），--now yyyy-MM-dd 推年份用的今天（默认今天）
// 有一份账单读不出、对不上，退出码就是 1。

struct Options {
    var template = ""
    var files: [String] = []
    var rows = Int.max
    var now = Date()
    var ledger: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--rows":
        guard let value = arguments.first.flatMap(Int.init) else { fail("--rows 后面要一个数字") }
        options.rows = value
        arguments.removeFirst()
    case "--ledger":
        guard let value = arguments.first else { fail("--ledger 后面写账户 JSON") }
        options.ledger = value
        arguments.removeFirst()
    case "--now":
        guard let value = arguments.first, let parts = StatementDateFormat("yyyy-MM-dd")?.parse(value),
              let date = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) else { fail("--now 后面写 yyyy-MM-dd") }
        options.now = date
        arguments.removeFirst()
    default:
        if options.template.isEmpty { options.template = argument } else { options.files.append(argument) }
    }
}
guard !options.template.isEmpty else { fail("用法：StatementCheck <模板.json> [<账单>…] [--rows N] [--now yyyy-MM-dd]") }

var templatePaths = [options.template]
var isDirectory: ObjCBool = false
if FileManager.default.fileExists(atPath: options.template, isDirectory: &isDirectory), isDirectory.boolValue {
    templatePaths = ((try? FileManager.default.contentsOfDirectory(atPath: options.template)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        .map { options.template + "/" + $0 }
}
var templates: [StatementTemplate] = []
var templateFiles: [Data] = []
for path in templatePaths {
    guard let data = FileManager.default.contents(atPath: path) else { fail("打不开模板 \(path)") }
    do {
        templates += try StatementTemplate.decode(data)
        templateFiles.append(data)
    } catch {
        print("\(path)：模板格式不对：\(error)")
        exit(1)
    }
}
for template in templates { print("模板 \(template.id)「\(template.name)」格式正确") }

/// 读账单文件
func document(_ path: String) throws -> StatementDocument {
    let url = URL(fileURLWithPath: path)
    guard let data = FileManager.default.contents(atPath: path) else { fail("打不开 \(path)") }
    let name = url.lastPathComponent
    switch url.pathExtension.lowercased() {
    case "csv", "txt":
        // Linux 上的 Foundation 不认 GB18030：交给系统的 iconv
        guard let text = StatementText.decode(data) ?? iconv(path) else { fail("\(name) 不是 UTF-8 或 GB18030 的文字：先用 iconv 转成 UTF-8") }
        return StatementDocument(name: name, kind: .csv, content: .grid(StatementReaders.csv(text)))
    case "xlsx":
        return StatementDocument(name: name, kind: .xlsx, content: .grid(try StatementReaders.xlsx(data)))
    case "xls":
        return StatementDocument(name: name, kind: .xls, content: .grid(try StatementReaders.xls(data)))
    case "json":
        struct Extracted: Decodable {
            var kind: StatementTemplate.FileType
            var name: String?
            var pages: [[ScreenTextLine]]
        }
        let extracted = try JSONDecoder().decode(Extracted.self, from: data)
        return StatementDocument(name: extracted.name ?? name, kind: extracted.kind, content: .pages(extracted.pages))
    default:
        fail("\(name)：只认 .csv .xlsx .xls，PDF 和图片先用 extract_pdf.py 读成 .json")
    }
}

func iconv(_ path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconv")
    process.arguments = ["-f", "GB18030", "-t", "UTF-8", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(data: output, encoding: .utf8) : nil
}

func pad(_ text: String, _ width: Int) -> String {
    // 中文算两个宽度，对齐好看一些
    let shown = text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    return shown >= width ? text : text + String(repeating: " ", count: width - shown)
}

func amountText(_ minor: Int64, _ currency: CurrencyCode) -> String {
    MoneyFormat.plain(minor, exponent: currency.minorUnitExponent)
}

if let ledger = options.ledger {
    exit(await reconcile(ledgerPath: ledger) ? 0 : 1)
}

var allUsable = true
for path in options.files {
    print("")
    let doc: StatementDocument
    do {
        doc = try document(path)
    } catch {
        print("\(path)：读不了（\(error)）")
        allUsable = false
        continue
    }
    let matching = templates.filter { StatementEngine.matches($0, doc) }
    guard let template = matching.first else {
        print("\(doc.name)：模板认不出这份账单（detect.fileTypes 要有 \(doc.kind.rawValue)，detect.contains 的字都要在文件里）")
        allUsable = false
        continue
    }
    let reading = StatementEngine.read(doc, with: template, now: options.now)
    print("\(doc.name)：用「\(template.name)」读")
    print("账号：\(reading.accountNumber ?? "（没找到）")")
    switch reading.verification {
    case .passed(let items): print("核对：通过（\(items.joined(separator: "，"))）")
    case .failed(let reason): print("核对：没通过——\(reason)")
    case .unavailable: print("核对：账单上没有能核对的余额或合计")
    }
    for problem in reading.problems { print("问题：\(problem)") }
    let counts = Dictionary(grouping: reading.rows, by: { $0.action?.rawValue ?? ($0.direction == .inflow ? "收入" : $0.direction == .outflow ? "支出" : "不计收支（没有规则）") })
    print("读出 \(reading.rows.count) 笔：" + counts.keys.sorted().map { "\($0) \(counts[$0]!.count)" }.joined(separator: "，"))
    for row in reading.rows.prefix(options.rows) {
        let date = String(format: "%04d-%02d-%02d", row.date.year ?? 0, row.date.month ?? 0, row.date.day ?? 0)
            + (row.date.hasTime ? String(format: " %02d:%02d", row.date.hour ?? 0, row.date.minute ?? 0) : "")
        let sign = row.direction == .inflow ? "+" : row.direction == .outflow ? "-" : "±"
        var line = pad("#\(row.number)", 5) + pad(date, 17) + pad(sign + amountText(row.amountMinor, row.currency) + " " + row.currency.rawValue, 18)
        line += pad(row.action?.rawValue ?? "-", 9)
        line += pad(row.balanceMinor.map { "余额 " + amountText($0, row.currency) } ?? "", 16)
        if let original = row.original { line += "原币 \(original.currency.rawValue) \(amountText(original.minorUnits, original.currency))  " }
        if !row.paidWith.isEmpty { line += "[\(row.paidWith)] " }
        line += String(row.summary.prefix(60))
        print(line)
    }
    if reading.rows.count > options.rows { print("……还有 \(reading.rows.count - options.rows) 笔") }
    if !reading.isUsable { allUsable = false }
    if case .unavailable = reading.verification { print("提醒：没法核对，App 里会标「没有核对」，导入前要用户自己看一遍") }
}
exit(allUsable ? 0 : 1)

// MARK: - 几份账单一起对账

/// 账户 JSON：[{"name", "bank", "last4", "type": "debit|credit|wallet", "currency", "extra": [...], "cardNumber", "accountNumber", "wallet"}]
struct LedgerAccount: Decodable {
    var name: String
    var bank: String?
    var last4: String?
    var type: String
    var currency: String
    var extra: [String]?
    var cardNumber: String?
    var accountNumber: String?
    var wallet: String?
}

@MainActor
func reconcile(ledgerPath: String) async -> Bool {
    do {
        guard let data = FileManager.default.contents(atPath: ledgerPath) else { fail("打不开 \(ledgerPath)") }
        let accounts = try JSONDecoder().decode([LedgerAccount].self, from: data)
        let now = options.now
        let backend = try LedgerBackend.inMemory(clock: { now })
        for item in accounts {
            let type = CardType(rawValue: item.type) ?? .debit
            let draft: AccountDraft = type == .wallet || type == .cash
                ? .pocket(name: item.name, type: type, currency: CurrencyCode(item.currency), paletteID: "blue", walletID: item.wallet)
                : AccountDraft(
                    name: item.name, bankID: nil, bankName: item.bank ?? item.name, last4: item.last4 ?? "0000", cardType: type,
                    currency: CurrencyCode(item.currency), paletteID: "blue", extraCurrencies: (item.extra ?? []).map { CurrencyCode($0) }
                )
            let account = try await backend.addAccount(draft)
            if item.cardNumber != nil { try await backend.updateCardInfo(accountID: account.id, name: account.name, cardNumber: item.cardNumber) }
            if item.accountNumber != nil { try await backend.updateAccountNumber(accountID: account.id, accountNumber: item.accountNumber) }
        }
        for data in templateFiles { try await backend.installStatementTemplates(data) }
        let names = Dictionary(try await backend.accounts().map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
        var files: [StatementFile] = []
        for (index, path) in options.files.enumerated() {
            let file = try await backend.readStatement(try document(path), id: "f\(index)")
            let check: String
            switch file.reading?.verification {
            case .passed(let items)?: check = "核对通过（\(items.joined(separator: "，"))）"
            case .failed(let reason)?: check = "核对没通过：\(reason)"
            case .unavailable?: check = "没法核对"
            case nil: check = "没有模板认得出"
            }
            print("\(file.name)：\(file.reading?.templateName ?? "-") → \(file.accountID.flatMap { names[$0] } ?? "（没认出账户）")，\(check)")
            files.append(file)
        }
        let preview = try await backend.previewStatementImport(files)
        let merged = preview.entries.filter { $0.sources.count > 1 }
        let transfers = preview.entries.filter { $0.kind == .transfer }
        print("")
        print("对账（空账本）：\(preview.entries.count) 笔，不记 \(preview.skippedCount) 笔，收支不明 \(preview.unclearCount) 笔")
        print("几份账单里重复、合成一笔的：\(merged.count) 笔；转帐 \(transfers.count) 笔（配成对的 \(transfers.filter { $0.peerID != nil }.count) 笔）")
        print("用没添加的卡付的：\(preview.noAccount.count) 笔")
        let kinds = Dictionary(grouping: preview.entries, by: { $0.kind.rawValue })
        print("按性质：" + kinds.keys.sorted().map { "\($0) \(kinds[$0]!.count)" }.joined(separator: "，"))
        for entry in preview.entries where entry.sources.count > 1 || entry.kind == .transfer || entry.status == .noAccount {
            let date = String(format: "%04d-%02d-%02d", entry.date.year ?? 0, entry.date.month ?? 0, entry.date.day ?? 0)
            let sign = entry.direction == .inflow ? "+" : "-"
            let account = entry.accountID.flatMap { names[$0] } ?? "尾号 \(entry.cardTail ?? "?") 的卡"
            let peer = entry.peerID.flatMap { id in preview.entries.first { $0.id == id } }.flatMap { $0.accountID }.flatMap { names[$0] }
            print("  \(date) \(sign)\(amountText(entry.amountMinor, entry.currency)) \(entry.currency.rawValue) \(entry.kind.rawValue) @\(account)"
                + (peer.map { " ⇄ \($0)" } ?? "") + "  [\(entry.sources.joined(separator: " + "))]")
        }
        return true
    } catch {
        print("对账失败：\(error)")
        return false
    }
}
