import Foundation
#if canImport(CoreFoundation) && canImport(Darwin)
import CoreFoundation
#endif

/// CSV 这类文字账单的编码：先试 UTF-8（带不带 BOM 都行），再试 GB18030（支付宝导出的 CSV 是 GBK）
public enum StatementText {
    public static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]), let text = String(data: bytes, encoding: .utf16) { return text }
        #if canImport(CoreFoundation) && canImport(Darwin)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: bytes, encoding: gb18030) { return text }
        #endif
        return nil
    }
}
