import Foundation
import UserNotifications

struct ReminderPlan {
    let member: Member
    let recordedToday: Set<MealSlot>
    let tips: [String]
    var guesses: [MealSlot: Meal] = [:]     // 这个餐次最常吃的（猜你吃了什么，通知里一键记下）
    var journalNudge = false                // 晚上提醒让管家排手账
}

/// 通知里的按钮和点开后要做的事
enum NotifKey {
    static let guessCategory = "MEAL_GUESS"
    static let logAction = "LOG_GUESS"
    static let otherAction = "TELL_BUTLER"
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
            let perDay = active.count * 3 + (meWater != nil ? 3 : 0) + 1
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
                        if let g = plan.guesses[slot] {
                            // 猜你吃了什么：长按通知点「是的，记一下」直接复制那一餐
                            let who = m.kind == .me ? "" : m.displayName
                            c.body = "\(who)又是「\(g.title)」吗？长按这条通知，一键记下"
                            c.categoryIdentifier = NotifKey.guessCategory
                            c.userInfo = ["meal": g.id, "slot": slot.rawValue, "member": m.id, "title": g.title]
                        }
                        c.sound = .default
                        add(center, id: "shitie.\(m.id).\(dayOffset).\(slot.rawValue)", content: c, date: fire, cal: cal)
                    }
                    if plan.journalNudge, let fire = cal.date(byAdding: .minute, value: 21 * 60, to: day), fire > now {
                        let c = UNMutableNotificationContent()
                        c.title = "🎨 今天的手账排一下？"
                        c.body = "让管家把今天吃的做成一页好看的手账"
                        c.userInfo = ["ask": "帮我把今天的手账做出来，做得好看一点"]
                        add(center, id: "shitie.journal.\(dayOffset)", content: c, date: fire, cal: cal)
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
                c.body = "点开让管家看看这周吃得怎么样，再排好下周的晚饭"
                c.userInfo = ["ask": "帮我看看这周吃得怎么样，缺什么，再排一下下周的晚饭"]
                c.sound = .default
                var dc = DateComponents()
                dc.weekday = 1
                dc.hour = 20
                dc.minute = 30
                center.add(UNNotificationRequest(identifier: "shitie.weekly", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
            }
        }
    }

    /// 管家设的一次性提醒
    static func once(id: String, title: String, body: String, at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let dc = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
    }

    /// 通知上的按钮
    static func registerCategories() {
        let log = UNNotificationAction(identifier: NotifKey.logAction, title: "是的，记一下", options: [.foreground])
        let other = UNNotificationAction(identifier: NotifKey.otherAction, title: "吃的别的，告诉管家", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotifKey.guessCategory, actions: [log, other], intentIdentifiers: [], options: []),
        ])
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, content: UNMutableNotificationContent, date: Date, cal: Calendar) {
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
    }
}
