import Foundation
import SwiftUI

// MARK: - 成员类型

enum MemberKind: String, Codable, CaseIterable, Identifiable {
    case me, elder, dog, cat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .me: return "我自己"
        case .elder: return "老人"
        case .dog: return "狗狗"
        case .cat: return "猫咪"
        }
    }

    var subtitle: String {
        switch self {
        case .me: return "均衡饮食、热量和营养"
        case .elder: return "蛋白质、钙、少盐、软烂好咀嚼"
        case .dog: return "热量、零食占比、危险食物"
        case .cat: return "热量、蛋白质、危险食物"
        }
    }

    var defaultEmoji: String {
        switch self {
        case .me: return "🙂"
        case .elder: return "👵"
        case .dog: return "🐶"
        case .cat: return "🐱"
        }
    }

    var isPet: Bool { self == .dog || self == .cat }

    var accent: Color {
        switch self {
        case .me: return .brand
        case .elder: return Color(red: 0.541, green: 0.384, blue: 0.200)
        case .dog: return Color(red: 0.184, green: 0.431, blue: 0.494)
        case .cat: return Color(red: 0.420, green: 0.353, blue: 0.620)
        }
    }

    var accentSoft: Color {
        switch self {
        case .me: return .brandSoft
        case .elder: return Color(red: 0.957, green: 0.929, blue: 0.890)
        case .dog: return Color(red: 0.898, green: 0.937, blue: 0.945)
        case .cat: return Color(red: 0.929, green: 0.918, blue: 0.957)
        }
    }

    /// 界面上用的系统图标
    var symbol: String {
        switch self {
        case .me: return "person.fill"
        case .elder: return "figure.walk"
        case .dog: return "dog.fill"
        case .cat: return "cat.fill"
        }
    }

    var defaultPaper: PaperStyle { isPet ? .paws : .dots }

    /// 宠物和老人一天吃几顿、叫什么
    func slotName(_ s: MealSlot) -> String {
        if isPet {
            switch s {
            case .breakfast: return "早饭"
            case .lunch: return "午饭"
            case .dinner: return "晚饭"
            case .snack: return "零食"
            }
        }
        return s.name
    }

    func slotSymbol(_ s: MealSlot) -> String {
        if isPet && s == .snack { return "pawprint" }
        return s.symbol
    }

    func slotEmoji(_ s: MealSlot) -> String {
        if isPet && s == .snack { return "🦴" }
        return s.emoji
    }

    /// 那个人/宠物吃东西时，主语怎么称呼
    func who(_ name: String) -> String { self == .me ? "你" : name }
}

// MARK: - 成员

struct Member: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: MemberKind
    var emoji: String
    // 人
    var sex: String = "female"
    var age: String = ""
    var height: String = ""
    var weight: String = ""
    var activity: Double = 1.375
    var goal: String = "keep"
    var avoid: String = ""          // 忌口/过敏
    var health: String = ""         // 健康情况：牙口、慢性病等（老人常用）
    // 宠物
    var breed: String = ""
    var neutered: Bool = true
    // 提醒和手账
    var reminders = ReminderSettings()
    var paper: PaperStyle = .dots
    var paperImage: String? = nil
    var kcalOverride: Int? = nil     // 用户手动指定的每日热量目标（管家或设置页改的），nil = 自动算

    static func makeMe(from p: Profile, reminders: ReminderSettings) -> Member {
        var m = Member(id: "me", name: "我", kind: .me, emoji: "🙂")
        m.sex = p.sex; m.age = p.age; m.height = p.height; m.weight = p.weight
        m.activity = p.activity; m.goal = p.goal; m.avoid = p.avoid
        m.reminders = reminders
        return m
    }

    static func new(kind: MemberKind) -> Member {
        var m = Member(id: UUID().uuidString, name: "", kind: kind, emoji: kind.defaultEmoji)
        m.paper = kind.defaultPaper
        switch kind {
        case .elder:
            m.age = "70"; m.activity = 1.2
            m.reminders.breakfast = 7 * 60 + 30; m.reminders.lunch = 11 * 60 + 30; m.reminders.dinner = 17 * 60 + 30
            m.reminders.water = false; m.reminders.weekly = false
        case .dog, .cat:
            m.sex = "male"; m.age = "3"; m.weight = kind == .dog ? "10" : "4"
            m.reminders.breakfast = 8 * 60; m.reminders.lunch = 13 * 60; m.reminders.dinner = 19 * 60
            m.reminders.water = false; m.reminders.weekly = false
        case .me: break
        }
        return m
    }

    /// 每日热量目标（kcal）
    var kcalTarget: Int {
        if let o = kcalOverride, o > 0 { return o }
        let w = Double(weight) ?? 0
        if kind.isPet {
            guard w > 0 else { return kind == .dog ? 600 : 220 }
            // 静息能量 RER = 70 × 体重^0.75，再乘活动/绝育系数
            let rer = 70 * pow(w, 0.75)
            var f: Double
            if kind == .dog { f = neutered ? 1.6 : 1.8 } else { f = neutered ? 1.2 : 1.4 }
            if goal == "lose" { f = kind == .dog ? 1.0 : 0.8 }
            if goal == "gain" { f += 0.3 }
            let a = Double(age) ?? 3
            if a < 1 { f = kind == .dog ? 2.5 : 2.5 } else if a >= 10 { f -= 0.2 }
            return Int((rer * f / 10).rounded() * 10)
        }
        let h = Double(height) ?? 0, a = Double(age) ?? 0
        guard w > 0, h > 0, a > 0 else { return kind == .elder ? 1650 : 1900 }
        var t = (10 * w + 6.25 * h - 5 * a + (sex == "male" ? 5 : -161)) * activity
        if goal == "lose" { t -= 400 }
        if goal == "gain" { t += 300 }
        return Int((t / 10).rounded() * 10)
    }

    /// 给 AI 看的成员描述
    var profileText: String {
        var parts: [String] = []
        switch kind {
        case .me, .elder:
            parts.append(kind == .elder ? "这是用户家里的老人（\(name.isEmpty ? "长辈" : name)），由家人帮忙记录" : "用户本人")
            parts.append(sex == "male" ? "男" : "女")
            if !age.isEmpty { parts.append(age + "岁") }
            if !height.isEmpty { parts.append(height + "cm") }
            if !weight.isEmpty { parts.append(weight + "kg") }
            parts.append(["lose": "目标减脂", "gain": "目标增重/增肌"][goal] ?? "目标保持均衡")
        case .dog, .cat:
            parts.append("这是用户养的\(kind == .dog ? "狗" : "猫")，名字叫\(name.isEmpty ? "它" : name)")
            if !breed.isEmpty { parts.append("品种：" + breed) }
            parts.append(sex == "male" ? "公" : "母")
            parts.append(neutered ? "已绝育" : "未绝育")
            if !age.isEmpty { parts.append(age + "岁") }
            if !weight.isEmpty { parts.append(weight + "kg") }
            parts.append(["lose": "需要减重", "gain": "需要增重"][goal] ?? "体重正常")
        }
        if !avoid.isEmpty { parts.append("忌口/过敏：" + avoid) }
        if !health.isEmpty { parts.append("健康情况：" + health) }
        parts.append("每日热量目标约\(kcalTarget)kcal")
        return parts.joined(separator: "，")
    }

    var displayName: String { name.isEmpty ? kind.title : name }
}

// MARK: - 手账背景

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case dots, grid, lines, blank, kraft, paws, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .dots: return "点点"
        case .grid: return "方格"
        case .lines: return "横线"
        case .blank: return "纯色"
        case .kraft: return "牛皮纸"
        case .paws: return "小爪印"
        case .custom: return "我的图片"
        }
    }
    static var presets: [PaperStyle] { [.dots, .grid, .lines, .blank, .kraft, .paws] }
}
