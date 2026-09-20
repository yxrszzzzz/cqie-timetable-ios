import Compression
import Foundation

/// 导入课表时的错误。每条都带上人话，界面上直接显示
enum ImportError: LocalizedError {
    case notZip
    case noWorksheet
    case tooLarge
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notZip:
            return "这个文件不是 xlsx。官网导出的文件一般叫「课表详情.xlsx」"
        case .noWorksheet:
            return "文件里没有工作表，可能不是课表导出"
        case .tooLarge:
            return "文件内容异常大，不像是课表"
        case .unreadable(let reason):
            return "文件读不了：\(reason)"
        }
    }
}

// MARK: - ZIP

/// 极简 ZIP 读取器：只认 xlsx 用到的那点结构。
///
/// 支持 store 和 deflate 两种方式（官网导出的是 deflate）。不引第三方库的理由
/// 和写入那边一样——为了读一个课表不值得。
private enum ZipReader {

    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// 从尾部往回找中央目录结束记录（EOCD）——ZIP 的目录在文件最后
    static func entries(in data: Data) throws -> [Entry] {
        guard let eocd = findEndRecord(in: data),
              let count = data.uint16(at: eocd + 10),
              let centralOffset = data.uint32(at: eocd + 16) else {
            throw ImportError.notZip
        }

        var result: [Entry] = []
        var cursor = Int(centralOffset)
        for _ in 0..<Int(count) {
            guard data.uint32(at: cursor) == 0x0201_4B50,
                  let method = data.uint16(at: cursor + 10),
                  let compressed = data.uint32(at: cursor + 20),
                  let uncompressed = data.uint32(at: cursor + 24),
                  let nameLength = data.uint16(at: cursor + 28),
                  let extraLength = data.uint16(at: cursor + 30),
                  let commentLength = data.uint16(at: cursor + 32),
                  let localOffset = data.uint32(at: cursor + 42) else { break }

            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""

            result.append(Entry(
                name: name,
                method: method,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)
            ))
            cursor = nameEnd + Int(extraLength) + Int(commentLength)
        }
        return result
    }

    static func data(of entry: Entry, in data: Data) throws -> Data {
        let offset = entry.localHeaderOffset
        guard data.uint32(at: offset) == 0x0403_4B50,
              let nameLength = data.uint16(at: offset + 26),
              let extraLength = data.uint16(at: offset + 28) else {
            throw ImportError.unreadable("条目「\(entry.name)」的文件头无效")
        }

        let start = offset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else {
            throw ImportError.unreadable("条目「\(entry.name)」的内容越界")
        }

        let raw = data.subdata(in: start..<end)
        switch entry.method {
        case 0:
            return raw
        case 8:
            guard let inflated = inflate(raw, expectedSize: entry.uncompressedSize) else {
                throw ImportError.unreadable("条目「\(entry.name)」解压失败")
            }
            return inflated
        default:
            throw ImportError.unreadable("不支持的压缩方式 \(entry.method)")
        }
    }

    private static func findEndRecord(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        // EOCD 之后是最长 65535 字节的注释，所以从尾部往回最多找这么多
        let lowerBound = max(0, data.count - minimum - 65535)
        var offset = data.count - minimum
        while offset >= lowerBound {
            if data.uint32(at: offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }

    /// ZIP 里的 deflate 是裸流（不带 zlib 头），正好对应 COMPRESSION_ZLIB
    private static func inflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)

        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            guard let dest = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dest, expectedSize,
                    src, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }
}

private extension Data {

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { raw in
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

// MARK: - xlsx

/// 极简 xlsx 读取器，只认官网课表导出那一种结构。
///
/// 不解样式、不解公式、不解日期序列号——够用就行。
/// iOS 上没有 `XMLDocument`（那是 macOS 的），所以用 SAX 的 `XMLParser` 手写状态机。
enum XlsxReader {

    /// 单个条目和整包的解压上限，挡住 zip 炸弹
    private static let maxEntryBytes = 8 * 1024 * 1024
    private static let maxTotalBytes = 24 * 1024 * 1024

    /// 一份工作表的原始内容
    struct Sheet {
        var cells: [String: String] = [:]
        var merges: [String] = []

        func text(_ reference: String) -> String { cells[reference] ?? "" }

        /// 出现过内容的行号（升序）
        var rows: [Int] {
            Set(cells.keys.compactMap(\.rowNumber)).sorted()
        }
    }

    /// xlsx 本身就是个 zip：`xl/sharedStrings.xml` 存文本，`xl/worksheets/sheetN.xml` 存单元格
    static func read(_ data: Data) throws -> Sheet {
        var shared: [String] = []
        var worksheets: [String: Data] = [:]
        var total = 0

        for entry in try ZipReader.entries(in: data) {
            let isShared = entry.name == "xl/sharedStrings.xml"
            let isSheet = entry.name.hasPrefix("xl/worksheets/") && entry.name.hasSuffix(".xml")
            guard isShared || isSheet else { continue }

            let content = try ZipReader.data(of: entry, in: data)
            guard content.count <= maxEntryBytes else { throw ImportError.tooLarge }
            total += content.count
            guard total <= maxTotalBytes else { throw ImportError.tooLarge }

            if isShared {
                shared = sharedStrings(from: content)
            } else {
                worksheets[entry.name] = content
            }
        }

        guard let sheetData = worksheets["xl/worksheets/sheet1.xml"]
            ?? worksheets.sorted(by: { $0.key < $1.key }).first?.value else {
            throw ImportError.noWorksheet
        }
        return parseSheet(sheetData, shared: shared)
    }

    private static func sharedStrings(from data: Data) -> [String] {
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private static func parseSheet(_ data: Data, shared: [String]) -> Sheet {
        let delegate = SheetDelegate(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Sheet(cells: delegate.cells, merges: delegate.merges)
    }
}

/// 一个 `<si>` 是一个字符串；富文本会拆成多个 `<r><t>`，拼起来才是完整内容
private final class SharedStringsDelegate: NSObject, XMLParserDelegate {

    private(set) var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "si":
            current = ""
            inItem = true
        case "t":
            inText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem, inText else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "si":
            strings.append(current)
            inItem = false
        case "t":
            inText = false
        default:
            break
        }
    }
}

/// 单元格：`t="s"` 的值是 sharedStrings 的下标，`inlineStr` 才是内联文本
private final class SheetDelegate: NSObject, XMLParserDelegate {

    private let shared: [String]
    private(set) var cells: [String: String] = [:]
    private(set) var merges: [String] = []

    private var reference = ""
    private var type = ""
    private var rawValue = ""
    private var inlineText = ""
    private var inValue = false
    private var inInlineText = false

    init(shared: [String]) {
        self.shared = shared
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "c":
            reference = attributeDict["r"] ?? ""
            type = attributeDict["t"] ?? ""
            rawValue = ""
            inlineText = ""
        case "v":
            inValue = true
        case "t":
            if !reference.isEmpty { inInlineText = true }
        case "mergeCell":
            if let value = attributeDict["ref"], !value.isEmpty { merges.append(value) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue {
            rawValue += string
        } else if inInlineText {
            inlineText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v":
            inValue = false
        case "t":
            inInlineText = false
        case "c":
            defer { reference = "" }
            guard !reference.isEmpty else { return }
            let text: String
            switch type {
            case "s":
                let index = Int(rawValue.trimmingCharacters(in: .whitespaces)) ?? -1
                text = (index >= 0 && index < shared.count) ? shared[index] : ""
            case "inlineStr":
                text = inlineText
            default:
                text = rawValue
            }
            if !text.isEmpty { cells[reference] = text }
        default:
            break
        }
    }
}

extension String {

    /// "AB12" -> 12
    var rowNumber: Int? { Int(filter { $0.isNumber }) }

    /// "AB12" -> "AB"
    var columnLetters: String { String(prefix { $0.isLetter }) }
}
