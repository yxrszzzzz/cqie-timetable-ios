import SwiftUI

/// 课程配色：按课程名做哈希，同一门课永远是同一个颜色
enum CoursePalette {

    private static let hues: [Double] = [0.58, 0.03, 0.33, 0.75, 0.13, 0.88, 0.45, 0.22, 0.66, 0.95]

    static func hue(for name: String) -> Double {
        guard !name.isEmpty else { return hues[0] }
        var hash = 5381
        for scalar in name.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        let index = ((hash % hues.count) + hues.count) % hues.count
        return hues[index]
    }
}

/// 单门课的色块。
///
/// 跨节次的课在每一行都画一次，只在首尾行做圆角——视觉上就是一块连续的色块，
/// 不用去算跨行布局。文字只在首行画，避免重复。
struct CourseBlock: View {

    let course: Course
    let section: Int
    var compact = false

    @Environment(\.colorScheme) private var scheme

    private var isFirst: Bool { section == (course.sections.min() ?? section) }
    private var isLast: Bool { section == (course.sections.max() ?? section) }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(fill)
            if isFirst {
                VStack(spacing: 1) {
                    Text(course.name)
                        .font(.system(size: compact ? 8 : 9, weight: .semibold))
                        .lineLimit(compact ? 3 : 2)
                        .minimumScaleFactor(0.7)
                    Text(course.roomText)
                        .font(.system(size: compact ? 7 : 8))
                        .lineLimit(1)
                    if !compact, !course.teacher.isEmpty {
                        Text(course.teacher)
                            .font(.system(size: 7))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.top, 3)
                .foregroundStyle(text)
            }
        }
        .padding(.horizontal, compact ? 0.5 : 1)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 6 : 0,
            bottomLeadingRadius: isLast ? 6 : 0,
            bottomTrailingRadius: isLast ? 6 : 0,
            topTrailingRadius: isFirst ? 6 : 0
        )
    }

    private var fill: Color {
        let hue = CoursePalette.hue(for: course.name)
        return scheme == .dark
            ? Color(hue: hue, saturation: 0.45, brightness: 0.40)
            : Color(hue: hue, saturation: 0.30, brightness: 0.98)
    }

    private var text: Color {
        scheme == .dark
            ? .white
            : Color(hue: CoursePalette.hue(for: course.name), saturation: 0.85, brightness: 0.30)
    }
}

/// 三门及以上撞课时，等分后连课名都放不下，收成汇总块点开看全部
struct CollisionBlock: View {
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.22))
            VStack(spacing: -1) {
                Text("\(count)").font(.system(size: 15, weight: .bold))
                Text("门课").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 1)
    }
}

struct TimetableGrid: View {

    let data: TimetableData
    let week: Int
    let onTapCourse: (Course) -> Void
    let onTapCollision: ([Course]) -> Void
    var hasBackground = false
    var chromeOpacity: Double = TimetableBackground.defaultChromeOpacity

    private static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private static let gutterWidth: CGFloat = 38
    private static let rowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ForEach(1...data.visibleSectionCount, id: \.self) { section in
                HStack(spacing: 0) {
                    gutter(section)
                    ForEach(1...7, id: \.self) { day in
                        cell(day: day, section: section)
                    }
                }
                .frame(height: Self.rowHeight)
                // 行之间不画分隔线：跨节次上的同一门课会被它切出一条缝。
                // 网格感由节次栏和列之间的竖线提供就够了
            }
        }
    }

    private var headerView: some View {
        let dates = data.dates(of: week)
        let today = Date()
        return HStack(spacing: 0) {
            Text("节次")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth)
            ForEach(0..<7, id: \.self) { index in
                let date = index < dates.count ? dates[index] : nil
                let isToday = date.map { DateUtil.calendar.isDate($0, inSameDayAs: today) } ?? false
                VStack(spacing: 1) {
                    Text(Self.dayNames[index])
                        .font(.system(size: 11, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                    if let date {
                        Text(DateUtil.monthDay(date))
                            .font(.system(size: 9))
                            .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        // 有底图时底衬浓度可调：调薄底图更清楚，调厚周几、日期更清楚
        .background(Color(.systemBackground).opacity(hasBackground ? chromeOpacity : 1))
    }

    private func gutter(_ section: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(section)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let period = data.periodTimes.first(where: { $0.smallPeriod == section }),
               let start = period.startTime, !start.isEmpty {
                Text(start)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.gutterWidth)
        // 必须撑满整行高度。只给宽度的话，这一列的高度就只剩内容那么高（约 20pt，
        // 一行是 56pt），底衬只在中间画一段——有底图时看着就是「123 断开了」
        .frame(maxHeight: .infinity)
        // 节次栏也留一层底。底图调到接近全屏可见时整屏都是图，
        // 没这层的话「第几节」和上课时间会糊在背景里读不出来
        .background(Color(.systemBackground).opacity(hasBackground ? chromeOpacity : 1))
    }

    private func cell(day: Int, section: Int) -> some View {
        let courses = data.coursesAt(week: week, weekDay: day, section: section)
        return ZStack {
            content(courses: courses, section: section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private func content(courses: [Course], section: Int) -> some View {
        if courses.isEmpty {
            Color.clear
        } else if courses.count == 1, let course = courses.first {
            Button { onTapCourse(course) } label: {
                CourseBlock(course: course, section: section)
            }
            .buttonStyle(.plain)
        } else if courses.count == 2 {
            // 两门并排：格子约 45pt 宽，二等分后还能看清课名
            HStack(spacing: 1) {
                ForEach(courses) { course in
                    Button { onTapCourse(course) } label: {
                        CourseBlock(course: course, section: section, compact: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Button { onTapCollision(courses) } label: {
                CollisionBlock(count: courses.count)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 课程详情。点格子弹出来，把「组班」「学生人数」这些格子里放不下的信息放全。
struct CourseDetailSheet: View {

    let course: Course

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("课程", course.name)
                    if !course.nature.isEmpty { row("性质", course.nature) }
                    if !course.reviewWay.isEmpty { row("考核", course.reviewWay) }
                }
                Section("时间地点") {
                    if let day = course.weekDay { row("星期", "周\(day)") }
                    if !course.sections.isEmpty { row("节次", course.sectionsText) }
                    row("周次", course.weeksText)
                    row("教室", course.roomText)
                    if !course.roomLabel.isEmpty, course.roomLabel != course.roomText {
                        row("教室类型", course.roomLabel)
                    }
                }
                Section("教师") {
                    row("授课", course.teacher.isEmpty ? "—" : course.teacher)
                }
                if !course.classesText.isEmpty || !course.students.isEmpty {
                    Section("组班") {
                        if !course.classesText.isEmpty { row("班级", course.classesText) }
                        if !course.students.isEmpty { row("学生", "\(course.students) 人") }
                    }
                }
            }
            .navigationTitle("课程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}

/// 撞课汇总弹窗：列出这一格上的全部课程
struct CollisionSheet: View {

    let courses: [Course]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(courses) { course in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(course.name).font(.subheadline).fontWeight(.medium)
                        Text("\(course.roomText)　\(course.teacher)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(course.weeksText)　\(course.sectionsText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("这一格有 \(courses.count) 门课")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
