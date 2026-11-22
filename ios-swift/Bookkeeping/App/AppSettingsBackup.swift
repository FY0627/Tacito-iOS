import Foundation
import UIKit

/// 「我的」里的设置，跟着「导出数据」走（zip 里的 `设置.json`，ADR 0019）：换手机、换 App 后导入就恢复成原来的样子。
/// 只放用户自己选的；开发与调试、汇率缓存（账本里有每天的汇率）不放。没有的项导入时不动
struct AppSettingsBackup: Codable, Equatable {
    var appearance: String?
    var appIcon: String?
    var themeColor: String?
    var language: String?
    var primaryCurrency: String?
    var notifyIngest: String?
    var notifyRates: Bool?
    var statsScope: String?

    private static let appearanceKey = "appearance"
    private static let statsScopeKey = "stats.scope"

    static func current() -> AppSettingsBackup {
        let d = UserDefaults.standard
        return AppSettingsBackup(
            appearance: d.string(forKey: Self.appearanceKey),
            appIcon: d.string(forKey: AppearanceMode.iconKey),
            themeColor: d.string(forKey: ThemeColor.key),
            language: d.string(forKey: AppLanguage.key),
            primaryCurrency: d.string(forKey: ExchangeRateStore.primaryKey),
            notifyIngest: d.string(forKey: IngestNotifier.modeKey),
            notifyRates: d.object(forKey: ImportExchangeRatesIntent.notifyKey) as? Bool,
            statsScope: d.string(forKey: statsScopeKey)
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> AppSettingsBackup? {
        try? JSONDecoder().decode(AppSettingsBackup.self, from: data)
    }

    /// 写回本机设置，再让语言、图标、主题色马上生效。打开了通知的，没有通知权限时先问；不给就关掉。
    /// `replacing`（撤销导入，换回导入前存的那份）：没有的项也换回默认，不然导入时改过的留着
    @MainActor func apply(replacing: Bool = false) async {
        let d = UserDefaults.standard
        func put(_ value: Any?, _ key: String) {
            if let value { d.set(value, forKey: key) } else if replacing { d.removeObject(forKey: key) }
        }
        put(appearance.flatMap { AppearanceMode(rawValue: $0) == nil ? nil : $0 }, Self.appearanceKey)
        put(themeColor, ThemeColor.key)
        put(primaryCurrency, ExchangeRateStore.primaryKey)
        put(notifyRates, ImportExchangeRatesIntent.notifyKey)
        put(statsScope, Self.statsScopeKey)
        let icon = appIcon.flatMap { AppearanceMode(rawValue: $0) == nil ? nil : $0 }
        if icon != nil || replacing {
            put(icon, AppearanceMode.iconKey)
            AppearanceMode.applyIcon()
        }
        let selected = language.flatMap { AppLanguage(rawValue: $0) } ?? (replacing ? .system : nil)
        if let selected, selected != AppLanguage.selected {
            AppLanguage.select(selected)
        }
        ThemeColor.applyToWindows()

        let wantsNotifications = (notifyIngest.flatMap(IngestNotifier.Mode.init).map { $0 != .off } ?? false) || notifyRates == true
        let allowed = wantsNotifications ? await IngestNotifier.requestAuthorization() : true
        if let notifyIngest, IngestNotifier.Mode(rawValue: notifyIngest) != nil {
            d.set(allowed ? notifyIngest : IngestNotifier.Mode.off.rawValue, forKey: IngestNotifier.modeKey)
        } else if replacing {
            d.removeObject(forKey: IngestNotifier.modeKey)
        }
        if notifyRates == true, !allowed { d.set(false, forKey: ImportExchangeRatesIntent.notifyKey) }
    }
}
