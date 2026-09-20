import SwiftUI
import UserNotifications

@main
struct CqieTimetableApp: App {

    init() {
        // 接管前台通知的展示方式，否则 App 开着的时候上课提醒不会弹出来
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
