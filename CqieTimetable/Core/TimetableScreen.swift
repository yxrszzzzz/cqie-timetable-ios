import SwiftUI

/// 课表页：周次选择 + 网格 + 不排时间的课
struct TimetableScreen: View {

    @ObservedObject var model: AppViewModel

    @State private var detail: Course?
    @State private var collision: CollisionPayload?

    private struct CollisionPayload: Identifiable {
        let id = UUID()
        let courses: [Course]
    }

    var body: some View {
        if let data = model.data {
            VStack(alignment: .leading, spacing: 12) {
                weekSelector(data)
                TimetableGrid(
                    data: data,
                    week: model.week,
                    onTapCourse: { detail = $0 },
                    onTapCollision: { collision = CollisionPayload(courses: $0) },
                    hasBackground: model.background != nil,
                    chromeOpacity: model.chromeOpacity
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                extraCourses(data)
            }
            .sheet(item: $detail) { CourseDetailSheet(course: $0) }
            .sheet(item: $collision) { CollisionSheet(courses: $0.courses) }
        }
    }

    // MARK: - 周次

    private func weekSelector(_ data: TimetableData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("第 \(model.week) 周")
                    .font(.headline)
                Text(data.dateRangeText(of: model.week))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.week != data.currentWeek {
                    Button("回到本周") { model.week = data.currentWeek }
                        .font(.caption)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(1...max(data.totalWeeks, 1), id: \.self) { value in
                        Button {
                            model.week = value
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 12, weight: value == model.week ? .bold : .regular))
                                .foregroundStyle(value == model.week ? Color.white : Color.primary)
                                .frame(width: 30, height: 26)
                                .background(chipBackground(value, current: data.currentWeek))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        // 周次行也留一层底，浓度和表头、节次栏走同一个设置
        .padding(.horizontal, model.background == nil ? 0 : 12)
        .padding(.vertical, model.background == nil ? 0 : 4)
        .background(
            Color(.systemBackground)
                .opacity(model.background == nil ? 0 : model.chromeOpacity)
        )
    }

    private func chipBackground(_ value: Int, current: Int) -> Color {
        if value == model.week { return .accentColor }
        if value == current { return Color.accentColor.opacity(0.18) }
        return Color.secondary.opacity(0.12)
    }

    private func badge(for course: Course) -> String {
        if course.isWholeWeek { return "整周" }
        return course.isOnline ? "网课" : "未排时间"
    }

    // MARK: - 不排时间的课

    /// 整周实训和没排时间的网课没有具体格子，单独列出来，否则会被静默丢掉
    private func extraCourses(_ data: TimetableData) -> some View {
        let all = data.wholeWeekCourses(week: model.week) + data.onlineCourses(week: model.week)
        return Group {
            if all.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("不排时间的课")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(all) { course in
                        Button {
                            detail = course
                        } label: {
                            HStack(spacing: 6) {
                                Text(badge(for: course))
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(course.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(course.weeksText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
