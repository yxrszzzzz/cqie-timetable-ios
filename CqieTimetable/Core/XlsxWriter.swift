import Foundation

/// 极简 XLSX（OOXML SpreadsheetML）生成器。
///
/// 按 OOXML 规范拼 XML，再打包成一个 zip。iOS 没有内置的 zip 写入 API，
/// 所以这里自带一个只用 store 模式的打包器——xlsx 允许条目不压缩，
/// 自己拼比引第三方库划算（Android 端也是自研的，没上 Apache POI）。
enum XlsxWriter {

    struct Cell {
        var text: String
        var style: Int = 0
    }

    struct Sheet {
        var name: String
        var columnWidths: [Double] = []
        var rows: [[Cell]] = []
        var merges: [String] = []
        var rowHeight: Double?
    }

    static func build(_ sheets: [Sheet]) -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes(sheets.count))
        zip.add("_rels/.rels", rootRels())
        zip.add("xl/workbook.xml", workbook(sheets))
        zip.add("xl/_rels/workbook.xml.rels", workbookRels(sheets.count))
        zip.add("xl/styles.xml", styles)
        for (index, sheet) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(index + 1).xml", sheetXml(sheet))
        }
        return zip.finish()
    }

    // MARK: - 课表专用

    private static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 周课表（网格）+ 课程清单，两个工作表
    static func timetable(_ data: TimetableData, week: Int, studentName: String) -> Data {
        let dates = data.dates(of: week)
        let sectionCount = max(data.maxSection, 1)

        // ---- Sheet1：周课表网格 ----
        var gridRows: [[Cell]] = []
        var title = "\(data.session.displayName) 第 \(week) 周"
        if dates.count == 7, let first = dates.first, let last = dates.last {
            title += "（\(DateUtil.monthDay(first)) - \(DateUtil.monthDay(last))）"
        }
        if !studentName.isEmpty { title += "  \(studentName)" }
        gridRows.append([Cell(text: title, style: 3)] + Array(repeating: Cell(text: ""), count: 7))

        var header: [Cell] = [Cell(text: "节次", style: 1)]
        for (index, name) in dayNames.enumerated() {
            if index < dates.count {
                header.append(Cell(text: "\(name)\n\(DateUtil.monthDay(dates[index]))", style: 1))
            } else {
                header.append(Cell(text: name, style: 1))
            }
        }
        gridRows.append(header)

        for section in 1...sectionCount {
            let start = data.periodTimes.first { ($0.smallPeriod ?? 0) == section }?.startTime ?? ""
            var row: [Cell] = [
                Cell(text: start.isEmpty ? "\(section)" : "\(section)\n\(start)", style: 1)
            ]
            for weekDay in 1...7 {
                let courses = data.coursesAt(week: week, weekDay: weekDay, section: section)
                // 跨节次的课只在首节写一次，否则每一行都会重复一遍课名
                let lines = courses.compactMap { course -> String? in
                    guard section == (course.sections.min() ?? section) else { return nil }
                    return course.room.isEmpty ? course.name : "\(course.name)\n@\(course.room)"
                }
                // 撞课时把这一格的课都写上，不能只取第一门
                row.append(Cell(text: lines.joined(separator: "\n"), style: 2))
            }
            gridRows.append(row)
        }

        let gridSheet = Sheet(
            name: "周课表",
            columnWidths: [9.0] + Array(repeating: 18.0, count: 7),
            rows: gridRows,
            merges: ["A1:H1"],
            rowHeight: 44.0
        )

        // ---- Sheet2：课程清单 ----
        var listRows: [[Cell]] = [[
            Cell(text: "课程名称", style: 1), Cell(text: "教师", style: 1),
            Cell(text: "星期", style: 1), Cell(text: "节次", style: 1),
            Cell(text: "周次", style: 1), Cell(text: "教室", style: 1),
            Cell(text: "性质", style: 1), Cell(text: "考核", style: 1),
            Cell(text: "组班", style: 1), Cell(text: "人数", style: 1),
        ]]
        for course in data.courses {
            listRows.append([
                Cell(text: course.name, style: 2),
                Cell(text: course.teacher, style: 2),
                Cell(text: weekDayText(course.weekDay), style: 2),
                Cell(text: course.sectionsText, style: 2),
                Cell(text: course.weeksText, style: 2),
                Cell(text: course.roomText, style: 2),
                Cell(text: course.nature, style: 2),
                Cell(text: course.reviewWay, style: 2),
                Cell(text: course.classesText, style: 2),
                Cell(text: course.students, style: 2),
            ])
        }

        let listSheet = Sheet(
            name: "课程清单",
            columnWidths: [30, 12, 7, 9, 12, 16, 10, 10, 24, 8],
            rows: listRows
        )

        return build([gridSheet, listSheet])
    }

    private static func weekDayText(_ value: Int?) -> String {
        guard let value, (1...7).contains(value) else { return "—" }
        return dayNames[value - 1]
    }

    // MARK: - 拼 XML

    private static func sheetXml(_ sheet: Sheet) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#

        if !sheet.columnWidths.isEmpty {
            xml += "<cols>"
            for (index, width) in sheet.columnWidths.enumerated() {
                let column = index + 1
                xml += #"<col min="\#(column)" max="\#(column)" width="\#(width)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }

        xml += "<sheetData>"
        for (rowIndex, cells) in sheet.rows.enumerated() {
            let rowNumber = rowIndex + 1
            var attributes = #" r="\#(rowNumber)""#
            // 第一行是标题，给它也设行高会把标题撑得很空
            if let height = sheet.rowHeight, rowIndex > 0 {
                attributes += #" ht="\#(height)" customHeight="1""#
            }
            xml += "<row\(attributes)>"
            for (columnIndex, cell) in cells.enumerated() {
                if cell.text.isEmpty, cell.style == 0 { continue }
                let reference = columnLetter(columnIndex + 1) + "\(rowNumber)"
                xml += #"<c r="\#(reference)" s="\#(cell.style)" t="inlineStr"><is><t xml:space="preserve">"#
                xml += escape(cell.text)
                xml += "</t></is></c>"
            }
            xml += "</row>"
        }
        xml += "</sheetData>"

        if !sheet.merges.isEmpty {
            xml += #"<mergeCells count="\#(sheet.merges.count)">"#
            for merge in sheet.merges {
                xml += #"<mergeCell ref="\#(merge)"/>"#
            }
            xml += "</mergeCells>"
        }

        xml += "</worksheet>"
        return xml
    }

    private static func columnLetter(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            value = (value - 1) / 26
        }
        return result
    }

    /// 换行要写成 `&#10;`，XML 里直接放裸换行会被解析器吞掉
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": break
            default:
                // XML 不允许的裸控制字符要剔掉，否则整个表格文件解析不了
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20 { break }
                result.append(character)
            }
        }
        return result
    }

    private static func contentTypes(_ sheetCount: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        xml += #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        xml += #"<Default Extension="xml" ContentType="application/xml"/>"#
        xml += #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
        for index in 1...max(sheetCount, 1) {
            xml += #"<Override PartName="/xl/worksheets/sheet\#(index).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        xml += #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        xml += "</Types>"
        return xml
    }

    private static func rootRels() -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        xml += #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>"#
        xml += "</Relationships>"
        return xml
    }

    private static func workbook(_ sheets: [Sheet]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" "#
        xml += #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        xml += "<sheets>"
        for (index, sheet) in sheets.enumerated() {
            xml += #"<sheet name="\#(escape(sheet.name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private static func workbookRels(_ sheetCount: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for index in 1...max(sheetCount, 1) {
            xml += #"<Relationship Id="rId\#(index)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(index).xml"/>"#
        }
        xml += #"<Relationship Id="rId\#(max(sheetCount, 1) + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        xml += "</Relationships>"
        return xml
    }

    /// 样式：0 普通 / 1 表头 / 2 正文（自动换行居中）/ 3 标题
    private static let styles = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><color theme="1"/><name val="DengXian"/></font><font><b/><sz val="11"/><color theme="1"/><name val="DengXian"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEFF3F7"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFD0D5DD"/></left><right style="thin"><color rgb="FFD0D5DD"/></right><top style="thin"><color rgb="FFD0D5DD"/></top><bottom style="thin"><color rgb="FFD0D5DD"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf></cellXfs></styleSheet>
    """#
}

// MARK: - ZIP

/// 只支持 store（不压缩）的极简 ZIP 写入器。
///
/// ZIP 结构本身就三块：本地头 + 数据、中央目录、结尾记录。store 模式下
/// 不需要实现 deflate，只要算对 CRC32，Excel 就能正常打开。
private struct ZipWriter {

    private struct Entry {
        let name: String
        let crc: UInt32
        let size: Int
        let offset: Int
    }

    private var output = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ content: String) {
        add(name, Data(content.utf8))
    }

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = output.count

        output.appendUInt32(0x0403_4B50)      // 本地文件头
        output.appendUInt16(20)               // version needed
        output.appendUInt16(0)                // flags
        output.appendUInt16(0)                // method: store
        output.appendUInt16(0)                // 修改时间
        output.appendUInt16(0x0021)           // 修改日期：固定 1980-01-01，产物才是可复现的
        output.appendUInt32(crc)
        output.appendUInt32(UInt32(data.count))
        output.appendUInt32(UInt32(data.count))
        output.appendUInt16(UInt16(nameBytes.count))
        output.appendUInt16(0)                // 扩展字段长度
        output.append(contentsOf: nameBytes)
        output.append(data)

        entries.append(Entry(name: name, crc: crc, size: data.count, offset: offset))
    }

    func finish() -> Data {
        let centralStart = output.count
        var central = Data()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            central.appendUInt32(0x0201_4B50)   // 中央目录条目
            central.appendUInt16(20)            // version made by
            central.appendUInt16(20)            // version needed
            central.appendUInt16(0)             // flags
            central.appendUInt16(0)             // method: store
            central.appendUInt16(0)             // 修改时间
            central.appendUInt16(0x0021)        // 修改日期
            central.appendUInt32(entry.crc)
            central.appendUInt32(UInt32(entry.size))
            central.appendUInt32(UInt32(entry.size))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)             // 扩展字段
            central.appendUInt16(0)             // 注释
            central.appendUInt16(0)             // 起始磁盘号
            central.appendUInt16(0)             // 内部属性
            central.appendUInt32(0)             // 外部属性
            central.appendUInt32(UInt32(entry.offset))
            central.append(contentsOf: nameBytes)
        }

        var result = output
        result.append(central)
        result.appendUInt32(0x0605_4B50)        // 结尾记录
        result.appendUInt16(0)                  // 当前磁盘号
        result.appendUInt16(0)                  // 中央目录起始磁盘号
        result.appendUInt16(UInt16(entries.count))
        result.appendUInt16(UInt16(entries.count))
        result.appendUInt32(UInt32(central.count))
        result.appendUInt32(UInt32(centralStart))
        result.appendUInt16(0)                  // 注释长度
        return result
    }
}

private enum CRC32 {

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    /// ZIP 一律小端
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
