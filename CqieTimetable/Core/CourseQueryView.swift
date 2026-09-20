import SwiftUI

/// 课表查询页：选范围 → 填条件 → 搜对象 → 查询 → 看课表。
///
/// 字段显隐与网页端一致，各范围的筛选项见 [QueryScope]。
struct CourseQueryView: View {

    @StateObject private var model: CourseQueryModel
    private let onClose: () -> Void

    init(api: CqieApi, auth: AuthRepository, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CourseQueryModel(api: api, auth: auth))
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if let data = model.result {
                QueryResultScreen(data: data, title: model.resultTitle)
            } else {
                form
            }
        }
        .navigationTitle(model.result == nil ? "课表查询" : "查询结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.result != nil {
                    Button("返回") { model.clearResult() }
                } else {
                    Button("关闭") { onClose() }
                }
            }
        }
        .task { model.start() }
    }

    // MARK: - 查询表单

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                scopePicker
                ChoiceRow(
                    label: "学期",
                    items: model.sessions,
                    selectedId: model.sessionId,
                    onSelect: { model.setSession($0) }
                )
                scopeFields
                if model.scope.needsSearch { searchRow }
                searchResults
                selectedList
                messageRow
                queryButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("查询范围")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QueryScope.allCases) { item in
                        Button {
                            model.setScope(item)
                        } label: {
                            Text(item.label)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    model.scope == item
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.12)
                                )
                                .foregroundStyle(model.scope == item ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    /// 各范围特有的筛选项
    @ViewBuilder
    private var scopeFields: some View {
        switch model.scope {
        case .teacher, .student:
            EmptyView()

        case .building, .classroom:
            ChoiceRow(
                label: "校区",
                items: model.campuses,
                selectedId: model.campusId,
                onSelect: { model.setCampus($0) }
            )
            ChoiceRow(
                label: "楼宇",
                items: model.buildings,
                selectedId: model.buildingId,
                enabled: !model.campusId.isEmpty,
                onSelect: { model.setBuilding($0) }
            )

        case .laboratory:
            ChoiceRow(
                label: "实验中心",
                items: model.laboratories,
                selectedId: model.laboratoryId,
                onSelect: { model.setLaboratory($0) }
            )

        case .adminClass:
            ChoiceRow(
                label: "学院(部门)",
                items: model.departments,
                selectedId: model.departmentId,
                onSelect: { model.setDepartment($0) }
            )
            ChoiceRow(
                label: "层次",
                items: model.degrees,
                selectedId: model.degree,
                onSelect: { model.setDegree($0) }
            )
            ChoiceRow(
                label: "年级",
                items: model.grades,
                selectedId: model.grade,
                onSelect: { model.setGrade($0) }
            )
            ChoiceRow(
                label: "专业",
                items: model.majors,
                selectedId: model.majorId,
                enabled: !model.departmentId.isEmpty,
                onSelect: { model.setMajor($0) }
            )

        case .course:
            if model.selectedCourse != nil {
                ChoiceRow(
                    label: "教学班号",
                    items: model.classNumbers.map { OptionItem(id: $0.id, name: $0.label) },
                    selectedId: model.classNumberId,
                    onSelect: { model.setClassNumber($0) }
                )
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            TextField(model.scope.searchHint, text: $model.keyword)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { model.search() }

            Button {
                model.search()
            } label: {
                if model.searching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("搜索")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.searching)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !model.targets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(resultHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 结果多时给个固定高度的内部滚动区，别把「已选」和查询按钮顶到屏幕外
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.targets) { target in
                            TargetRow(
                                target: target,
                                selected: model.isSelected(target),
                                showsCheck: !model.scope.picksCourseFirst,
                                onTap: {
                                    if model.scope.picksCourseFirst {
                                        model.pickCourse(target)
                                    } else {
                                        model.toggle(target)
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var resultHint: String {
        switch model.scope {
        case .course:
            return "选择课程"
        case .student:
            return "搜索结果（\(model.targets.count) 人，重名请按学号区分，可多选）"
        case .teacher:
            return "搜索结果（\(model.targets.count) 人，重名请按工号区分，可多选）"
        default:
            return "搜索结果（\(model.targets.count) 项，可多选）"
        }
    }

    @ViewBuilder
    private var selectedList: some View {
        if !model.selected.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.vertical, 4)
                Text("已选")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.selected) { target in
                    HStack(spacing: 8) {
                        Text(target.display)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            model.remove(target)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// 学期是查询的前提，加载不出来就必须能重来；否则按钮是灰的、用户也不知道为什么
    @ViewBuilder
    private var messageRow: some View {
        if model.sessions.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(model.message ?? "学期列表没加载出来，暂时没法查询")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("重试") { model.loadSessions() }
                    .font(.caption)
            }
        } else if let message = model.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queryButton: some View {
        Button {
            model.runQuery()
        } label: {
            Text(model.loading ? "查询中…" : "查询课表")
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canQuery || model.loading)
        .padding(.top, 4)
    }
}

/// 一行「标签 + 下拉」
private struct ChoiceRow: View {

    let label: String
    let items: [OptionItem]
    let selectedId: String
    var enabled = true
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            Menu {
                if items.isEmpty {
                    Text("暂无可选项")
                } else {
                    ForEach(items, id: \.self) { item in
                        Button(item.title) { onSelect(item.identity) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
    }

    private var title: String {
        items.first { $0.identity == selectedId }?.title ?? "请选择"
    }

    private var isPlaceholder: Bool {
        selectedId.isEmpty || items.first { $0.identity == selectedId } == nil
    }
}

/// 搜索结果里的一行，选中态整行高亮
private struct TargetRow: View {

    let target: QueryTarget
    let selected: Bool
    let showsCheck: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if !target.subtitle.isEmpty {
                        Text(target.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if showsCheck && selected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 结果

/// 查询结果的课表。展示逻辑与「我的课表」一致，只是数据来自查询接口。
private struct QueryResultScreen: View {

    let data: TimetableData
    let title: String

    @State private var week: Int
    @State private var owner: String?
    @State private var detail: Course?
    @State private var collision: CollisionPayload?

    private struct CollisionPayload: Identifiable {
        let id = UUID()
        let courses: [Course]
    }

    init(data: TimetableData, title: String) {
        self.data = data
        self.title = title
        _week = State(initialValue: min(max(data.currentWeek, 1), max(data.totalWeeks, 1)))
    }

    private var shown: TimetableData { data.filteredBy(owner: owner) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if data.owners.count > 1 { ownerBar }
            weekBar
            extraCourses
            Divider()
            TimetableGrid(
                data: shown,
                week: week,
                onTapCourse: { detail = $0 },
                onTapCollision: { collision = CollisionPayload(courses: $0) }
            )
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .sheet(item: $detail) { CourseDetailSheet(course: $0) }
        .sheet(item: $collision) { CollisionSheet(courses: $0.courses) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text("\(shown.session.displayName)　第 \(week) 周　\(shown.dateRangeText(of: week))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 多人查询时可按人筛选，否则合并在一起分不清谁是谁的
    private var ownerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ownerChip("全部", active: owner == nil) { owner = nil }
                ForEach(data.owners, id: \.self) { name in
                    ownerChip(name, active: owner == name) { owner = name }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func ownerChip(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(active ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var weekBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(1...max(shown.totalWeeks, 1), id: \.self) { value in
                    Button {
                        week = value
                    } label: {
                        Text("\(value)")
                            .font(.system(size: 12, weight: value == week ? .bold : .regular))
                            .foregroundStyle(value == week ? Color.white : Color.primary)
                            .frame(width: 30, height: 26)
                            .background(
                                value == week
                                    ? Color.accentColor
                                    : (value == shown.currentWeek
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.12))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    /// 没有固定节次的课（整周实训 / 网课），网格里画不出来，单列一行
    @ViewBuilder
    private var extraCourses: some View {
        let all = shown.wholeWeekCourses(week: week) + shown.onlineCourses(week: week)
        if !all.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(all) { course in
                        Button {
                            detail = course
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("\(course.isWholeWeek ? "整周" : "网课") · \(course.weeksText)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}
