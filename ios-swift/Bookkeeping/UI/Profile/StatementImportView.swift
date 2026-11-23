import SwiftUI
import BKBackend
import BKModel

/// 导入账单（「我的 › 数据 › 导入账单」，ADR 0029）。只有这一个入口：账单（PDF、CSV、Excel、截图）和账单模板（.json）都在这里选，
/// 可以一次选好几份。模板先装上，账单用装好的模板读；上了锁的 PDF 在这里一起输密码。
/// 读出来先核对余额、合计，对不上的整份不用；再几份一起对账：账单之间重复的合成一笔，账本里已经有的不再记，
/// 剩下的「漏记」默认全选，点一下补记。补记完可以撤销这一次。
struct StatementImportView: View {
    @Environment(LedgerStore.self) private var store

    private struct Picked: Identifiable {
        enum State {
            case reading
            case locked(Data)
            case failed(String)
            case template([String])
            case unrecognized(StatementDocument)
            case statement(StatementFile, StatementDocument)
        }

        let id = UUID().uuidString
        let name: String
        var state: State
        var password = ""
    }

    @State private var picking = false
    @State private var items: [Picked] = []
    @State private var preview: StatementPreview?
    @State private var selected: Set<String> = []
    @State private var summary: StatementImportSummary?
    @State private var lastBatch: String?
    @State private var undone: Int?
    @State private var templateCount = 0
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Button { picking = true } label: {
                    Label(items.isEmpty ? "选择账单" : "再加几份", systemImage: "doc.badge.plus")
                }
                NavigationLink {
                    StatementTemplateListView()
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(templateCount)")
                    } label: {
                        Label("账单模板", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            if !items.isEmpty { filesSection }
            if hasLocked { passwordSection }
            if preview == nil, summary == nil, !readyFiles.isEmpty {
                Section {
                    Button { Task { await reconcile() } } label: {
                        Label("对账", systemImage: "checklist")
                    }
                }
            }
            if let preview, summary == nil { previewSections(preview) }
            if let summary {
                Section {
                    Label(L("补记了 \(summary.records) 笔"), systemImage: "checkmark.circle")
                    undoMenu(summary.batchID, count: summary.records)
                }
            } else if preview == nil, items.isEmpty, let lastBatch {
                Section { undoMenu(lastBatch, count: nil) }
            }
            if let undone {
                Section { Text(L("已经删掉上次补记的 \(undone) 笔。")) }
            }
            if busy { ProgressView() }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .disabled(busy)
        .navigationTitle("导入账单")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: StatementFileReader.contentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await load(urls) }
        }
        .task {
            templateCount = (try? await store.statementTemplates().count) ?? 0
            lastBatch = await store.lastStatementImport()
        }
    }

    // MARK: 文件

    private var hasLocked: Bool {
        items.contains { item in
            guard case .locked = item.state else { return false }
            return true
        }
    }

    private var readyFiles: [StatementFile] {
        items.compactMap { item -> StatementFile? in
            guard case .statement(let file, _) = item.state, file.isReady else { return nil }
            return file
        }
    }

    private var filesSection: some View {
        Section("账单") {
            ForEach($items) { $item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name).lineLimit(1)
                    switch item.state {
                    case .reading:
                        ProgressView()
                    case .locked:
                        Label("要密码", systemImage: "lock").font(.footnote).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(verbatim: message).font(.footnote).foregroundStyle(.red)
                    case .template(let names):
                        Label(L("装上了模板：\(names.joined(separator: "、"))"), systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary)
                    case .unrecognized:
                        Text("没有模板认得出").font(.footnote).foregroundStyle(.orange)
                    case .statement(let file, let document):
                        statementDetail(file, document: document, item: $item)
                    }
                }
            }
            .onDelete { offsets in
                items.remove(atOffsets: offsets)
                preview = nil
            }
        }
    }

    @ViewBuilder
    private func statementDetail(_ file: StatementFile, document: StatementDocument, item: Binding<Picked>) -> some View {
        if let reading = file.reading {
            Text(verbatim: reading.templateName).font(.footnote).foregroundStyle(.secondary)
            switch reading.verification {
            case .passed(let checks):
                Label(L("核对过：\(checks.joined(separator: "、"))"), systemImage: "checkmark.seal").font(.footnote).foregroundStyle(.green)
            case .failed(let reason):
                Label(L("对不上：\(reason)"), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            case .unavailable:
                Label("账单上没有能核对的数字", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
            }
            if reading.isUsable {
                Picker("记到", selection: Binding(
                    get: { file.accountID ?? "" },
                    set: { id in
                        var updated = file
                        updated.accountID = id.isEmpty ? nil : id
                        item.wrappedValue.state = .statement(updated, document)
                        preview = nil
                    }
                )) {
                    Text("请选择").tag("")
                    ForEach(accountChoices(file)) { account in
                        Text(verbatim: account.displayTitle).tag(account.id)
                    }
                }
                .font(.footnote)
            }
        }
    }

    /// 候选的账户在前，其余使用中的账户在后（银行卡对银行账单，钱包对钱包账单）
    private func accountChoices(_ file: StatementFile) -> [Account] {
        let wallet = file.reading?.issuer.type == .wallet
        let pool = store.accounts.filter { wallet ? $0.cardType == .wallet : $0.isCard }
        let first = file.candidateIDs.compactMap { id in store.account(id: id) }
        return first + pool.filter { account in !first.contains { $0.id == account.id } }
    }

    private var passwordSection: some View {
        Section("要密码的账单") {
            ForEach($items) { $item in
                if case .locked(let data) = item.state {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: item.name).lineLimit(1).font(.footnote)
                            SecureField("密码", text: $item.password)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button("解锁") { Task { await unlock(item.id, data: data) } }
                            .disabled(item.password.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: 对账结果

    @ViewBuilder
    private func previewSections(_ preview: StatementPreview) -> some View {
        let missing = preview.missing
        Section {
            if missing.isEmpty {
                Text("账单上的都记过了")
            }
            ForEach(missing) { entry in
                Button {
                    if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                        entryRow(entry)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text(L("漏记 \(missing.count) 笔"))
                Spacer()
                if !missing.isEmpty {
                    Button(selected.count == missing.count ? "全不选" : "全选") {
                        selected = selected.count == missing.count ? [] : Set(missing.map(\.id))
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }
        if !missing.isEmpty {
            Section {
                Button { Task { await commit(preview) } } label: {
                    Label(L("补记 \(selected.count) 笔"), systemImage: "plus.circle")
                }
                .disabled(selected.isEmpty)
            }
        }
        if !preview.noAccount.isEmpty {
            Section(L("用没添加的卡付的 \(preview.noAccount.count) 笔")) {
                ForEach(preview.noAccount) { entry in entryRow(entry) }
            }
        }
        Section {
            DisclosureGroup(L("已经记了 \(preview.recorded.count) 笔")) {
                ForEach(preview.recorded) { entry in entryRow(entry) }
            }
            if !preview.extraRecords.isEmpty {
                DisclosureGroup(L("账本里有、账单上没有 \(preview.extraRecords.count) 笔")) {
                    ForEach(preview.extraRecords) { row in RecordRowView(row: row) }
                }
            }
            if preview.skippedCount > 0 {
                LabeledContent("不记（交易关闭、账户里挪钱）", value: L("\(preview.skippedCount) 笔"))
            }
            if preview.unclearCount > 0 {
                LabeledContent("看不出收支的", value: L("\(preview.unclearCount) 笔"))
            }
        }
    }

    private func entryRow(_ entry: StatementEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.counterparty.isEmpty ? entry.summary : entry.counterparty).lineLimit(1)
                Text(verbatim: [dateText(entry.date), kindText(entry), accountText(entry)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(verbatim: MoneyFormat.signed(entry.amountMinor, currency: entry.currency, direction: entry.direction))
                .monospacedDigit()
                .foregroundStyle(entry.direction == .inflow ? Color.green : Color.primary)
        }
    }

    private func dateText(_ date: WallClock) -> String {
        guard let day = Calendar.current.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: date.hour, minute: date.minute)) else { return "" }
        return date.hasTime ? Fmt.dateTime(day) : Fmt.shortDate(day)
    }

    private func kindText(_ entry: StatementEntry) -> String {
        switch entry.kind {
        case .expense: L("支出")
        case .income: L("收入")
        case .refund: L("退款")
        case .transfer: L("转帐")
        case .interest: L("利息")
        case .fee: L("手续费")
        }
    }

    private func accountText(_ entry: StatementEntry) -> String {
        if let id = entry.accountID, let account = store.account(id: id) {
            if let peer = entry.peerID.flatMap({ id in preview?.entries.first { $0.id == id } }), let peerID = peer.accountID, let other = store.account(id: peerID) {
                return entry.direction == .outflow ? "\(account.displayTitle) → \(other.displayTitle)" : "\(other.displayTitle) → \(account.displayTitle)"
            }
            return account.displayTitle
        }
        return L("尾号 \(entry.cardTail ?? "") 的卡")
    }

    private func undoMenu(_ batchID: String, count: Int?) -> some View {
        Menu {
            Button(role: .destructive) { Task { await undo(batchID) } } label: {
                Label(count.map { L("删掉这次补记的 \($0) 笔") } ?? L("删掉上次补记的流水"), systemImage: "trash")
            }
        } label: {
            Label(count == nil ? "撤销上次导入账单" : "撤销这次导入", systemImage: "arrow.uturn.backward")
        }
    }

    // MARK: 动作

    /// 模板先装（同时选了模板和账单时，账单才认得出），再读账单
    private func load(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        errorText = nil
        undone = nil
        summary = nil
        preview = nil
        let ordered = urls.sorted { ($0.pathExtension.lowercased() == "json" ? 0 : 1) < ($1.pathExtension.lowercased() == "json" ? 0 : 1) }
        var installed = false
        for url in ordered {
            var item = Picked(name: url.lastPathComponent, state: .reading)
            items.append(item)
            let index = items.count - 1
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url)
                }.value
                let content = try await StatementFileReader.read(data, name: item.name)
                if case .locked = content {
                    item.state = .locked(data)
                } else {
                    item.state = try await state(for: content, name: item.name)
                }
                if case .template = item.state { installed = true }
            } catch {
                item.state = .failed(message(error))
            }
            items[index].state = item.state
        }
        if installed { await rereadUnrecognized() }
    }

    private func state(for content: StatementFileReader.Content, name: String) async throws -> Picked.State {
        switch content {
        case .locked:
            return .failed(L("密码不对"))
        case .template(let data):
            let templates = try await store.installStatementTemplates(data)
            templateCount = (try? await store.statementTemplates().count) ?? templateCount
            return .template(templates.map(\.name))
        case .statement(let document):
            let file = try await store.readStatement(document, id: UUID().uuidString)
            return file.reading == nil ? .unrecognized(document) : .statement(file, document)
        }
    }

    /// 新装了模板：之前认不出的账单再认一次
    private func rereadUnrecognized() async {
        for index in items.indices {
            guard case .unrecognized(let document) = items[index].state,
                  let file = try? await store.readStatement(document, id: UUID().uuidString), file.reading != nil else { continue }
            items[index].state = .statement(file, document)
        }
    }

    private func unlock(_ id: String, data: Data) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        let password = items[index].password
        do {
            let content = try await StatementFileReader.read(data, name: items[index].name, password: password)
            items[index].state = try await state(for: content, name: items[index].name)
            items[index].password = ""
        } catch StatementFileReader.ReadError.wrongPassword {
            items[index].password = ""
            errorText = L("「\(items[index].name)」的密码不对")
        } catch {
            items[index].state = .failed(message(error))
        }
    }

    private func reconcile() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await store.previewStatementImport(readyFiles)
            preview = result
            selected = Set(result.missing.map(\.id))
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func commit(_ preview: StatementPreview) async {
        busy = true
        defer { busy = false }
        do {
            summary = try await store.importStatementEntries(preview, selected: selected)
            lastBatch = summary?.batchID
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func undo(_ batchID: String) async {
        busy = true
        defer { busy = false }
        do {
            undone = try await store.undoStatementImport(batchID: batchID)
            summary = nil
            preview = nil
            lastBatch = nil
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func message(_ error: Error) -> String {
        if let template = error as? StatementTemplateError { return L("模板格式不对：\(template.description)") }
        if let read = error as? StatementFileReader.ReadError { return read.errorDescription ?? "" }
        if error is StatementReaders.Failure { return L("读不了这个文件") }
        return L("出错了：\(error.localizedDescription)")
    }
}

/// 装好的账单模板：哪家的什么账单，左滑删除
struct StatementTemplateListView: View {
    @Environment(LedgerStore.self) private var store
    @State private var templates: [StatementTemplate] = []
    @State private var deleting: StatementTemplate?

    var body: some View {
        List {
            if templates.isEmpty {
                Text("还没有模板")
                    .foregroundStyle(.secondary)
            }
            ForEach(templates) { template in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: template.name)
                    Text(verbatim: template.detect.fileTypes.map { $0.rawValue.uppercased() }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = template } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("账单模板")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除后不能恢复", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let template = deleting else { return }
                Task {
                    try? await store.deleteStatementTemplate(id: template.id)
                    templates = (try? await store.statementTemplates()) ?? []
                }
            }
        }
        .task { templates = (try? await store.statementTemplates()) ?? [] }
    }
}
