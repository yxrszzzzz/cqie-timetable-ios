import SwiftUI

/// 上课提醒的设置
struct ReminderSheet: View {

    @ObservedObject var model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var enabled = ReminderStore.enabled
    @State private var lead = ReminderStore.leadMinutes
    @State private var denied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("上课前提醒", isOn: $enabled)
                        .onChange(of: enabled) { value in
                            Task { await applyEnabled(value) }
                        }
                } footer: {
                    Text("到点由系统直接发通知，App 不用开着。只排未来一周，每次打开 App 会自动往后续。")
                }

                if enabled {
                    Section {
                        Picker("提前", selection: $lead) {
                            ForEach(ReminderStore.leadOptions, id: \.self) { value in
                                Text("\(value) 分钟").tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: lead) { value in
                            ReminderStore.leadMinutes = value
                            Task { await ClassReminder.reschedule(model.data) }
                        }
                    } header: {
                        Text("时间")
                    } footer: {
                        if model.data == nil {
                            Text("还没拿到课表，排不出提醒。先回到课表页加载一次。")
                        } else {
                            Text("每节课按第一节的开始时间提醒，比如第 3-4 节会在 08:20 提醒（提前 10 分钟时）。")
                        }
                    }
                }

                if denied {
                    Section {
                        Label(
                            "系统里的通知权限被关掉了。去「设置 → 通知 → 重工课表」打开允许通知，再回来打开这个开关。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("上课提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            denied = await ClassReminder.isDenied()
        }
        .onChange(of: scenePhase) { phase in
            // 从系统设置里改完权限回来，提示要及时消失
            guard phase == .active else { return }
            Task { denied = await ClassReminder.isDenied() }
        }
    }

    private func applyEnabled(_ value: Bool) async {
        if value {
            let granted = await ClassReminder.enable(model.data)
            if !granted {
                // 系统没给权限就把开关拨回去，否则界面显示"已开启"但永远收不到通知
                enabled = false
                denied = true
            } else {
                denied = false
            }
        } else {
            await ClassReminder.disable()
        }
    }
}
