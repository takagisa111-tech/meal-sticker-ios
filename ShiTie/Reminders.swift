import Foundation
import UserNotifications

struct ReminderPlan {
    let member: Member
    let recordedToday: Set<MealSlot>
    let tips: [String]
}

/// 系统通知：每个成员未来几天的三餐提醒（当天已记录的餐次跳过），「我」的喝水提醒，周日晚的周报提醒。
/// iOS 最多保留 64 条待发通知，成员多时自动缩短排期天数。
enum Reminders {
    static func requestAuth() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(_ plans: [ReminderPlan]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ours = reqs.map(\.identifier).filter { $0.hasPrefix("shitie.") }
            center.removePendingNotificationRequests(withIdentifiers: ours)

            let active = plans.filter { $0.member.reminders.on }
            let meWater = active.first { $0.member.kind == .me && $0.member.reminders.water }
            let perDay = active.count * 3 + (meWater != nil ? 3 : 0)
            let days = max(1, min(7, (60 - 1) / max(1, perDay)))

            let cal = Calendar.current
            let now = Date()
            for plan in active {
                let m = plan.member
                var tipIndex = 0
                for dayOffset in 0..<days {
                    guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { continue }
                    for slot in MealSlot.mains {
                        if dayOffset == 0 && plan.recordedToday.contains(slot) { continue }
                        guard let fire = cal.date(byAdding: .minute, value: m.reminders.minutes(for: slot), to: day), fire > now else { continue }
                        let c = UNMutableNotificationContent()
                        let slotName = m.kind.slotName(slot)
                        switch m.kind {
                        case .me:
                            c.title = "\(slot.emoji) \(slotName)时间到啦"
                        case .elder:
                            c.title = "\(m.emoji) \(m.displayName)该吃\(slotName)了"
                        case .dog, .cat:
                            c.title = "\(m.emoji) 该给\(m.displayName)喂\(slotName)啦"
                        }
                        if !plan.tips.isEmpty {
                            c.body = plan.tips[tipIndex % plan.tips.count]
                            tipIndex += 1
                        } else {
                            switch m.kind {
                            case .me: c.body = "按时吃饭，吃完拍一张贴到手账上～"
                            case .elder: c.body = "提醒一下长辈按时吃饭，拍一张记到手账"
                            case .dog, .cat: c.body = "喂完拍一张，记一下它今天吃了什么"
                            }
                        }
                        c.sound = .default
                        add(center, id: "shitie.\(m.id).\(dayOffset).\(slot.rawValue)", content: c, date: fire, cal: cal)
                    }
                    if let w = meWater, w.member.id == m.id {
                        for h in [10, 15, 20] {
                            guard let fire = cal.date(byAdding: .hour, value: h, to: day), fire > now else { continue }
                            let c = UNMutableNotificationContent()
                            c.title = "💧 喝口水吧"
                            c.body = "今天的喝水打卡别忘了"
                            add(center, id: "shitie.water.\(dayOffset).\(h)", content: c, date: fire, cal: cal)
                        }
                    }
                }
            }
            if let me = plans.first(where: { $0.member.kind == .me })?.member, me.reminders.on, me.reminders.weekly {
                let c = UNMutableNotificationContent()
                c.title = "✨ 这周的饮食周报"
                c.body = "打开食贴，看看这周吃得均不均衡、下周该补点什么"
                c.sound = .default
                var dc = DateComponents()
                dc.weekday = 1
                dc.hour = 20
                dc.minute = 30
                center.add(UNNotificationRequest(identifier: "shitie.weekly", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
            }
        }
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, content: UNMutableNotificationContent, date: Date, cal: Calendar) {
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
    }
}
