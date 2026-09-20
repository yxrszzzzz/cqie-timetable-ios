import Foundation

/// 解析官网「Excel 导出」出来的 `课表详情.xlsx`。
///
/// 文件长这样（即 `XlsxReader` 读出来的原始文本）：
///  - 第 1 行标题，第 3 行表头（`节次` + `星期一`…`星期日`）
///  - 第 4 行起每行是一个大节，B～H 列对应周一到周日
///  - 最后一行的 A 列写着 `占周占时间`，B 列放整周占用的课程
///
/// 每个格子里是**自由文本**，不是结构化字段，撞课时多门课用换行拼在一起：
/// ```
/// 电力电子技术(必修)
/// 葛会平-05675[主讲];
/// [1-7,10-13,16周] [1-2]
/// 智慧教室 6210(智慧教室)
/// 组班：24自动化4班(46)
///
/// 学生：46人
/// ```
/// 好在教师串、周次、节次这几段的写法与教务接口的字段**完全一致**，
/// 所以能直接还原成 `ClassTimetableItem`，下游的组装、缓存、提醒全部复用。
///
/// 对不上的内容一律跳过并计数，绝不猜——宁可少显示一门课，也不能编出一门不存在的课。
enum OfficialTimetableParser {

    /// 表头之后、整周占用之前，最多再看这么多行，防止误读整张表
    private static let maxSectionRows = 30

    private static let weekdayTexts = [
        "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日",
    ]

    private static let timeLine = Pattern(#"^\[([^\]]+?)周\]\s*\[([^\]]+)]$"#)
    private static let headLine = Pattern(#"^(.+?)\(([^()]*)\)\s*(?:\[([^\[\]]*)])?$"#)
    private static let classLine = Pattern(#"^组班[:：](.+)$"#)
    private static let studentLine = Pattern(#"^学生[:：]\s*(\d+)\s*人?$"#)
    private static let classItem = Pattern(#"^(.+?)\((\d+)\)$"#)
    private static let roomLine = Pattern(#"^(.*?)\s*\(([^()]*)\)$"#)

    /// 整周占用那行的格式：`课程名 教师[角色]; [1-3周]3202`
    private static let wholeWeekLine = Pattern(#"^(.+?)\s+([^\s;]+(?:\[[^\]]*])?)\s*;\s*\[([^\]]+?)周]\s*(\S*)\s*$"#)

    struct Result {
        var items: [ClassTimetableItem] = []
        /// 文件里出现过的最大周次，用来定学期长度
        var maxWeek = 0
        /// 文件里出现过的最大小节，用来决定课表画几行
        var maxSection = 0
        /// 解析不了、被跳过的块数。界面上要如实告诉用户
        var skipped = 0

        var isEmpty: Bool { items.isEmpty }
    }

    static func parse(_ sheet: XlsxReader.Sheet) -> Result {
        let rows = sheet.rows
        guard let headerRow = rows.first(where: { row in
            let label = sheet.text("A\(row)")
            return label == "节次" || (label.isEmpty && weekdayColumns(sheet, headerRow: row).count >= 5)
        }) else { return Result() }

        let columns = weekdayColumns(sheet, headerRow: headerRow)
        guard !columns.isEmpty else { return Result() }

        var result = Result()

        for row in rows {
            guard row > headerRow, row <= headerRow + maxSectionRows else { continue }
            let label = sheet.text("A\(row)").trimmingCharacters(in: .whitespaces)

            // 整周占用单独一行，格式和网格里的不一样
            if label.contains("占周") || label.contains("占用") {
                for item in parseWholeWeek(sheet.text("B\(row)")) {
                    consume(item, into: &result)
                }
                continue
            }
            if label.isEmpty { continue }

            for (column, weekDay) in columns {
                let cell = sheet.text("\(column)\(row)")
                if cell.isEmpty { continue }
                for block in splitBlocks(cell) {
                    if let item = parseBlock(block, weekDay: weekDay) {
                        consume(item, into: &result)
                    } else {
                        result.skipped += 1
                    }
                }
            }
        }

        return result
    }

    private static func consume(_ item: ClassTimetableItem, into result: inout Result) {
        result.items.append(item)
        if let value = WeekUtil.parse(item.teachingWeekFormat).max() {
            result.maxWeek = max(result.maxWeek, value)
        }
        if let value = WeekUtil.parse(item.periodFormat).max() {
            result.maxSection = max(result.maxSection, value)
        }
    }

    /// 表头行里 `星期一`～`星期日` 所在的列 -> 1～7；没有文字表头时退回 B～H
    private static func weekdayColumns(_ sheet: XlsxReader.Sheet, headerRow: Int) -> [String: Int] {
        var found: [String: Int] = [:]
        for (reference, text) in sheet.cells {
            guard reference.rowNumber == headerRow else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let index = weekdayTexts.firstIndex(of: trimmed) {
                found[reference.columnLetters] = index + 1
            }
        }
        if found.count >= 5 { return found }
        return ["B": 1, "C": 2, "D": 3, "E": 4, "F": 5, "G": 6, "H": 7]
    }

    /// 把一格拆成若干门课。
    ///
    /// 块之间的换行是 `\r\n`、块内是 `\n`，但不同版本未必稳定，
    /// 所以改用「`学生：N人` 是每块的结尾」来切——比依赖换行符可靠。
    private static func splitBlocks(_ cell: String) -> [[String]] {
        let lines = cell
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            current.append(line)
            if line.hasPrefix("学生：") || line.hasPrefix("学生:") {
                blocks.append(current)
                current = []
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func parseBlock(_ lines: [String], weekDay: Int) -> ClassTimetableItem? {
        guard let timeIndex = lines.firstIndex(where: { timeLine.matches($0) }), timeIndex > 0 else {
            return nil
        }
        guard let timeGroups = timeLine.groups(lines[timeIndex]) else { return nil }
        let weeks = timeGroups[1]
        let sections = timeGroups[2]

        let head = lines[0]
        let headGroups = headLine.groups(head)
        let name = (headGroups?[1] ?? head).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        let nature = headGroups?[2] ?? ""
        let exam = headGroups?[3] ?? ""

        // 教师可能跨多行，全并起来；格式与接口一致，交给下游的 cleanTeacher 处理
        let teachers = lines[1..<timeIndex].joined()

        let rest = Array(lines[(timeIndex + 1)...])
        let roomRaw = rest.first { !$0.hasPrefix("组班") && !$0.hasPrefix("学生") } ?? ""
        let (room, roomLabel) = parseRoom(roomRaw)

        let classText = rest.first { $0.hasPrefix("组班") }
            .flatMap { classLine.groups($0) }
            .flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
        let studentText = rest.first { $0.hasPrefix("学生") }
            .flatMap { studentLine.groups($0) }
            .flatMap { $0.count > 1 ? $0[1] : nil } ?? ""

        let classes = parseClasses(classText)

        return ClassTimetableItem(
            weekDay: String(weekDay),
            courseName: name,
            roomName: room,
            roomLabel: roomLabel,
            instructorName: teachers.isEmpty ? nil : teachers,
            courseStudyNature: nature.isEmpty ? nil : nature,
            reviewWay: exam.isEmpty ? nil : exam,
            teachingWeekFormat: weeks,
            periodFormat: sections,
            selectedStuNum: studentText.isEmpty ? nil : studentText,
            assignTeachingObject: classes.isEmpty ? nil : classes
        )
    }

    /// 「智慧教室 6210(智慧教室)」/「 6118(智慧教室)」/「 」 -> (教室号, 教室标签)
    private static func parseRoom(_ line: String) -> (room: String, label: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ("", "") }

        let groups = roomLine.groups(trimmed)
        let body = (groups?[1] ?? trimmed).trimmingCharacters(in: .whitespaces)
        let label = (groups?[2] ?? "").trimmingCharacters(in: .whitespaces)
        // 教室号是最后一段，前面的「智慧教室」只是标签的重复
        let last = body.components(separatedBy: " ").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return (last.isEmpty ? body : last, label)
    }

    private static func parseClasses(_ text: String) -> [TeachingObject] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .compactMap { part -> TeachingObject? in
                let piece = part.trimmingCharacters(in: .whitespaces)
                if piece.isEmpty { return nil }
                let groups = classItem.groups(piece)
                // 下标先落到局部变量：直接连着写 `groups?[2].flatMap`，
                // 那个 `?[` 会被当成三元运算符的开头，flatMap 会解析成 Sequence 版本，
                // 于是闭包参数成了 Character、返回值成了 [Double]
                let studentText = groups?[2]
                return TeachingObject(
                    className: (groups?[1] ?? piece).trimmingCharacters(in: .whitespaces),
                    stuNums: studentText.flatMap { Double($0) }
                )
            }
    }

    /// 整周占用：一行一门课
    private static func parseWholeWeek(_ cell: String) -> [ClassTimetableItem] {
        cell.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line -> ClassTimetableItem? in
                guard let groups = wholeWeekLine.groups(line) else { return nil }
                return ClassTimetableItem(
                    courseName: groups[1].trimmingCharacters(in: .whitespaces),
                    roomName: groups[4].trimmingCharacters(in: .whitespaces),
                    instructorName: groups[2].trimmingCharacters(in: .whitespaces),
                    teachingWeekFormat: groups[3].trimmingCharacters(in: .whitespaces),
                    wholeWeekOccupy: true
                )
            }
    }
}

/// `NSRegularExpression` 取分组的写法太啰嗦，包一层。
/// 模式都是写死的常量，编译期已知正确，所以直接 `try!`。
private struct Pattern {

    private let regex: NSRegularExpression

    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 返回分组，下标 0 是整体匹配；不匹配返回 nil
    func groups(_ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let sub = Range(match.range(at: index), in: text) else { return "" }
            return String(text[sub])
        }
    }
}
