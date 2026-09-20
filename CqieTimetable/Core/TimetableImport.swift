import Foundation

/// 导入官网导出的课表。
///
/// 导出文件里没有任何日期信息，算不出「现在第几周」，所以由用户指定开学第一周的周一，
/// 再据此造一个虚拟学期——这样第几周和上课提醒才能照常工作。
@MainActor
enum TimetableImport {

    /// 导入课表用的固定学期 id，和接口返回的学期区分开
    static let sessionId = "imported"

    /// 组装成课表并存进缓存，返回可以直接显示的课表
    static func store(result: OfficialTimetableParser.Result, firstMonday: Date) -> TimetableData {
        let weeks = max(result.maxWeek, 1)
        let monday = DateUtil.calendar.startOfDay(for: firstMonday)
        let end = DateUtil.adding(days: (weeks - 1) * 7 + 6, to: monday)

        let session = SessionItem(
            id: sessionId,
            year: "导入课表",
            term: "",
            beginDate: DateUtil.formatDay(monday),
            endDate: DateUtil.formatDay(end),
            active: "Y"
        )
        let schedule = ScheduleData(
            classTimetableVOList: result.items,
            maxSection: max(result.maxSection, 1)
        )

        TimetableStore.save(session: session, schedule: schedule, periods: defaultPeriods)
        // 导入的课表不属于任何学生，别让上一个账号的姓名跟着显示
        TimetableStore.lastStudentName = nil

        return TimetableBuilder.build(session: session, schedule: schedule, periods: defaultPeriods)
    }

    /// 学校作息（12 小节）。导入的文件里没有作息表，用这份兜底
    private static let defaultPeriods: [PeriodItem] = [
        PeriodItem(smallPeriod: 1, startTime: "08:30", endTime: "09:15"),
        PeriodItem(smallPeriod: 2, startTime: "09:25", endTime: "10:10"),
        PeriodItem(smallPeriod: 3, startTime: "10:30", endTime: "11:15"),
        PeriodItem(smallPeriod: 4, startTime: "11:25", endTime: "12:10"),
        PeriodItem(smallPeriod: 5, startTime: "14:00", endTime: "14:45"),
        PeriodItem(smallPeriod: 6, startTime: "14:55", endTime: "15:40"),
        PeriodItem(smallPeriod: 7, startTime: "16:00", endTime: "16:45"),
        PeriodItem(smallPeriod: 8, startTime: "16:55", endTime: "17:40"),
        PeriodItem(smallPeriod: 9, startTime: "19:00", endTime: "19:45"),
        PeriodItem(smallPeriod: 10, startTime: "19:55", endTime: "20:40"),
        PeriodItem(smallPeriod: 11, startTime: "20:50", endTime: "21:35"),
        PeriodItem(smallPeriod: 12, startTime: "21:45", endTime: "22:30"),
    ]
}
