import SwiftUI

/// 课表备注的编辑器。
///
/// 长按课表空白格进来时只能改三样：节次区间、生效周次、正文——星期由长按的那一列定死，
/// 免得「贴在哪一天」和「手指按在哪一天」还能对不上。
struct NoteEditorSheet: View {

    let initial: TimetableNote
    let isNew: Bool
    let sectionCount: Int
    let totalWeeks: Int
    /// 当前正在看的那一周，用来给「本周」这个快捷项
    let currentWeek: Int
    let onSave: (TimetableNote) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var start: Int
    @State private var end: Int
    @State private var weeks: Set<Int>
    @State private var fill: Color
    @State private var ink: Color
    @State private var autoInk: Bool

    /// 备注正文的长度上限。格子就巴掌大，写太长自己都看不见
    private static let maxLength = 30

    init(
        initial: TimetableNote,
        isNew: Bool,
        sectionCount: Int,
        totalWeeks: Int,
        currentWeek: Int,
        onSave: @escaping (TimetableNote) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.initial = initial
        self.isNew = isNew
        self.sectionCount = sectionCount
        self.totalWeeks = totalWeeks
        self.currentWeek = currentWeek
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: initial.text)
        _start = State(initialValue: initial.sectionStart)
        _end = State(initialValue: initial.sectionEnd)
        _weeks = State(initialValue: Set(initial.weeks))
        _fill = State(initialValue: initial.fillColor.map { Color(argb: $0) } ?? NoteStyle.defaultFill)
        // 先给个具体的深色，别用 .primary——那个是动态色，取色器里没法当色板显示
        _ink = State(initialValue: initial.textColor.map { Color(argb: $0) } ?? Color(argb: 0xFF111827))
        _autoInk = State(initialValue: initial.textColor == nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("如：交实验报告", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: text) { value in
                            if value.count > Self.maxLength {
                                text = String(value.prefix(Self.maxLength))
                            }
                        }
                } header: {
                    Text("备注内容")
                } footer: {
                    Text("\(text.count)/\(Self.maxLength)")
                }

                Section {
                    preview
                    ColorPicker("底色", selection: $fill, supportsOpacity: false)
                    Toggle("文字跟随主题", isOn: $autoInk)
                    if !autoInk {
                        ColorPicker("文字颜色", selection: $ink, supportsOpacity: false)
                    }
                } header: {
                    Text("样式")
                } footer: {
                    Text("上面那张就是课表上的样子，配色搭不搭一眼看得出来。底色是半透明的，课程块不受影响。")
                }

                Section {
                    Picker("起始", selection: $start) {
                        ForEach(1...max(sectionCount, 1), id: \.self) { Text("第 \($0) 节").tag($0) }
                    }
                    Picker("结束", selection: $end) {
                        ForEach(1...max(sectionCount, 1), id: \.self) { Text("第 \($0) 节").tag($0) }
                    }
                } header: {
                    // 星期由长按的那一列定死，摆在这儿让用户确认贴对了没
                    Text("\(initial.weekDayText) · 第 \(sectionText) 节")
                } footer: {
                    Text("便签有多高，排得下的字就有多少：一节约 15 字，两节的 30 字上限就全写得下。")
                }
                // 起点越过往后挪时把终点一起带过去，免得出现「3-1 节」这种反区间
                .onChange(of: start) { value in if end < value { end = value } }
                .onChange(of: end) { value in if start > value { start = value } }

                Section {
                    HStack {
                        Button("本周") { weeks = [currentWeek] }
                        Spacer()
                        Button("全部") { weeks = Set(1...max(totalWeeks, 1)) }
                        Spacer()
                        Button("清空") { weeks = [] }
                    }
                    .font(.footnote)
                    weekGrid
                } header: {
                    Text(weeks.isEmpty ? "周次" : "周次 · 已选 \(weeks.count) 周")
                } footer: {
                    Text("便签只在勾上的周次里出现，默认勾的是当前这一周。")
                }

                if !isNew {
                    Section {
                        Button("删除这张备注", role: .destructive) {
                            onDelete?()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "添加备注" : "修改备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(canSave == false)
                }
            }
        }
    }

    // MARK: - 样式

    /// 和课表上长得一样的实时预览
    private var preview: some View {
        HStack(spacing: 12) {
            Text(text.isEmpty ? "便签长这样" : text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(autoInk ? Color.primary : ink)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .padding(6)
                .frame(width: 104, height: 56, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill.opacity(NoteStyle.fillAlpha))
                )
            Text("课表上就这么大")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - 周次

    private var weekGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
            spacing: 6
        ) {
            ForEach(1...max(totalWeeks, 1), id: \.self) { value in
                Button {
                    if weeks.contains(value) {
                        weeks.remove(value)
                    } else {
                        weeks.insert(value)
                    }
                } label: {
                    Text(value == currentWeek ? "\(value)本" : "\(value)")
                        .font(.system(size: 12, weight: weeks.contains(value) ? .bold : .regular))
                        .foregroundStyle(weeks.contains(value) ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            weeks.contains(value)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 保存

    /// 跟着选择实时变的节次文案
    private var sectionText: String {
        start == end ? "\(start)" : "\(start)-\(end)"
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !weeks.isEmpty
    }

    private func save() {
        guard canSave else { return }
        var note = initial
        note.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        note.sectionStart = start
        note.sectionEnd = end
        note.weeks = weeks.sorted()
        note.fillColor = fill.argb
        // 跟随主题就存 nil，这样深色模式下它自己会变浅
        note.textColor = autoInk ? nil : ink.argb
        onSave(note)
        dismiss()
    }
}
