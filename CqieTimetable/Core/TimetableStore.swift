import Foundation

/// 课表本地缓存。
///
/// 存的是**服务端原始数据**，不是拼好的展示模型：以后改网格、改周次算法，
/// 用户手上那份旧缓存照样能读（Android 端同样是这么存的）。
///
/// 另外要记着「上次看的学期 id」——冷启动得能不联网直接定位到缓存文件，
/// 否则还得先问一次学期列表，「不登录也能看课表」就无从谈起。
@MainActor
enum TimetableStore {

    private struct RawSnapshot: Codable {
        var session: SessionItem
        var schedule: ScheduleData
        var periods: [PeriodItem]
    }

    private static let cachePrefix = "timetable_"
    private static let cacheSuffix = ".json"
    private static let lastSessionKey = "cqie_cache_last_session"
    private static let lastNameKey = "cqie_cache_last_name"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static let directory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - 读

    /// 只读本地，**不联网**。
    /// 依次尝试：指定学期 → 上次看过的学期 → 最新写入的那份。
    static func load(sessionId: String? = nil) -> TimetableData? {
        var candidates: [URL] = []
        if let sessionId { candidates.append(fileURL(sessionId)) }
        if let last = lastSessionId { candidates.append(fileURL(last)) }
        candidates.append(contentsOf: allCacheFiles().map { $0.url })

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? decoder.decode(RawSnapshot.self, from: data) else { continue }
            return TimetableBuilder.build(
                session: raw.session,
                schedule: raw.schedule,
                periods: raw.periods
            )
        }
        return nil
    }

    // MARK: - 写

    static func save(session: SessionItem, schedule: ScheduleData, periods: [PeriodItem]) {
        let raw = RawSnapshot(session: session, schedule: schedule, periods: periods)
        guard let data = try? encoder.encode(raw) else { return }

        var url = fileURL(session.id)
        try? data.write(to: url, options: .atomic)
        // 课表属于个人数据，不该跟着 iCloud 备份跑
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        lastSessionId = session.id
    }

    /// 缓存对应的学生姓名。没有登录态时靠它把界面撑起来，
    /// 否则缓存课表就是一份没人认领的数据。
    static var lastStudentName: String? {
        get { UserDefaults.standard.string(forKey: lastNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastNameKey) }
    }

    /// 退出登录时清掉——课程信息属于个人数据，不该在登出后还留在设备上
    static func clear() {
        for file in allCacheFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
        UserDefaults.standard.removeObject(forKey: lastSessionKey)
        UserDefaults.standard.removeObject(forKey: lastNameKey)
    }

    // MARK: - 内部

    private static var lastSessionId: String? {
        get { UserDefaults.standard.string(forKey: lastSessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSessionKey) }
    }

    private static func fileURL(_ sessionId: String) -> URL {
        directory.appendingPathComponent("\(cachePrefix)\(sessionId)\(cacheSuffix)")
    }

    /// 最近写入的排在最前面
    private static func allCacheFiles() -> [(url: URL, modified: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(cachePrefix) && $0.hasSuffix(cacheSuffix) }
            .map { name in
                let url = directory.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, modified)
            }
            .sorted { $0.modified > $1.modified }
    }
}
