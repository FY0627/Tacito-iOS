import Foundation

/// 解压 deflate（RFC 1951）：xlsx 是 zip，里面的文件多半压缩过。iOS 的 Compression 在 Linux 上没有，
/// 用第三方库又要另写 ADR；解压只有一百多行，在哪都能测（ADR 0029）。只解压，不压缩。
enum Inflate {
    enum Failure: Error, Equatable { case corrupt, tooLarge }

    /// `limit`：解出来最多多少字节（防止坏文件、压缩炸弹把内存吃光）
    static func decompress(_ input: [UInt8], limit: Int = 64 << 20) throws -> [UInt8] {
        var reader = BitReader(bytes: input)
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, input.count * 4))
        var last = false
        while !last {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                reader.alignToByte()
                let length = try reader.bits(16)
                let complement = try reader.bits(16)
                guard length == ~complement & 0xFFFF else { throw Failure.corrupt }
                guard out.count + length <= limit else { throw Failure.tooLarge }
                for _ in 0..<length { out.append(UInt8(try reader.bits(8))) }
            case 1:
                try inflateBlock(&reader, &out, literal: fixedLiteral, distance: fixedDistance, limit: limit)
            case 2:
                let (literal, distance) = try dynamicTables(&reader)
                try inflateBlock(&reader, &out, literal: literal, distance: distance, limit: limit)
            default:
                throw Failure.corrupt
            }
        }
        return out
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0
        var buffer: UInt32 = 0
        var count = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func bits(_ n: Int) throws -> Int {
            while count < n {
                guard position < bytes.count else { throw Failure.corrupt }
                buffer |= UInt32(bytes[position]) << count
                position += 1
                count += 8
            }
            let value = Int(buffer & ((1 << n) - 1))
            buffer >>= n
            count -= n
            return value
        }

        mutating func alignToByte() {
            buffer = 0
            count = 0
        }
    }

    /// 规范霍夫曼表：每个长度有几个码、按码排好的符号
    private struct Huffman {
        var counts: [Int]
        var symbols: [Int]

        init(lengths: [Int]) {
            counts = [Int](repeating: 0, count: 16)
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<16 { offsets[length] = offsets[length - 1] + counts[length - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.corrupt
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let fixedLiteral: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman(lengths: lengths)
    }()
    private static let fixedDistance = Huffman(lengths: [Int](repeating: 5, count: 30))

    private static func dynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Failure.corrupt }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeCount { codeLengths[order[i]] = try reader.bits(3) }
        let codeTable = Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            let symbol = try codeTable.decode(&reader)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Failure.corrupt }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + (try reader.bits(2))))
            case 17:
                lengths.append(contentsOf: repeatElement(0, count: 3 + (try reader.bits(3))))
            default:
                lengths.append(contentsOf: repeatElement(0, count: 11 + (try reader.bits(7))))
            }
        }
        guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else { throw Failure.corrupt }
        return (Huffman(lengths: Array(lengths[0..<literalCount])), Huffman(lengths: Array(lengths[literalCount...])))
    }

    private static func inflateBlock(_ reader: inout BitReader, _ out: inout [UInt8], literal: Huffman, distance: Huffman, limit: Int) throws {
        while true {
            let symbol = try literal.decode(&reader)
            if symbol < 256 {
                guard out.count < limit else { throw Failure.tooLarge }
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < lengthBase.count else { throw Failure.corrupt }
                let length = lengthBase[index] + (try reader.bits(lengthExtra[index]))
                let distanceSymbol = try distance.decode(&reader)
                guard distanceSymbol < distanceBase.count else { throw Failure.corrupt }
                let back = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
                guard back <= out.count else { throw Failure.corrupt }
                guard out.count + length <= limit else { throw Failure.tooLarge }
                let start = out.count - back
                for i in 0..<length { out.append(out[start + i]) }
            }
        }
    }
}

/// 读 zip 里的文件（只存不压缩的、deflate 压缩的都行）。导出备份用的 `ZipStore` 只认自己写的不压缩的 zip，这里给 xlsx 用
enum ZipReader {
    enum Failure: Error, Equatable { case unreadable, unsupported(String) }

    static func files(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func le32(_ i: Int) -> Int { le16(i) | le16(i + 2) << 16 }
        // 目录结尾：从文件末尾往前找签名 PK\5\6
        guard bytes.count >= 22 else { throw Failure.unreadable }
        guard let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 5 && bytes[$0 + 3] == 6
        }) else { throw Failure.unreadable }
        let entryCount = le16(end + 10)
        var cursor = le32(end + 16)
        var files: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, le32(cursor) == 0x0201_4B50 else { throw Failure.unreadable }
            let method = le16(cursor + 10)
            let compressedSize = le32(cursor + 20)
            let nameLength = le16(cursor + 28), extraLength = le16(cursor + 30), commentLength = le16(cursor + 32)
            let localOffset = le32(cursor + 42)
            guard cursor + 46 + nameLength <= bytes.count else { throw Failure.unreadable }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength
            guard localOffset + 30 <= bytes.count, le32(localOffset) == 0x0403_4B50 else { throw Failure.unreadable }
            let start = localOffset + 30 + le16(localOffset + 26) + le16(localOffset + 28)
            guard start + compressedSize <= bytes.count else { throw Failure.unreadable }
            let body = Array(bytes[start..<(start + compressedSize)])
            switch method {
            case 0: files[name] = Data(body)
            case 8:
                do {
                    files[name] = Data(try Inflate.decompress(body))
                } catch {
                    throw Failure.unreadable
                }
            default: throw Failure.unsupported(name)
            }
        }
        return files
    }
}
