import Foundation

struct Aggregate {
    var grams: [FoodGroup: Double] = [:]
    var kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0, fiber = 0.0
    var flags: [String: Int] = [:]
    var names = Set<String>()
    var groupMeals: [FoodGroup: Int] = [:]
    var days = Set<String>()
    var count = 0
    var analyzed = 0

    func value(_ row: GuideRow) -> Double { row.groups.reduce(0) { $0 + (grams[$1] ?? 0) } }
    var dayCount: Double { Double(max(1, days.count)) }
}

struct Tip: Identifiable, Hashable {
    let id = UUID()
    let emoji: String
    let title: String
    let detail: String
}

enum RowStatus {
    case none, low, slightlyLow, ok, slightlyHigh, high
    var text: String {
        switch self {
        case .none: return "没吃到"
        case .low: return "明显不足"
        case .slightlyLow: return "略少"
        case .ok: return "适量"
        case .slightlyHigh: return "略多"
        case .high: return "偏多"
        }
    }
    var isGood: Bool { self == .ok }
    var isWarn: Bool { self == .slightlyLow || self == .slightlyHigh }
    var isHigh: Bool { self == .slightlyHigh || self == .high }
}

enum Nutrition {
    static func aggregate(_ meals: [Meal]) -> Aggregate {
        var a = Aggregate()
        for m in meals {
            a.days.insert(m.date)
            a.count += 1
            guard m.status == .done else { continue }
            a.analyzed += 1
            a.kcal += m.kcal; a.protein += m.protein; a.carbs += m.carbs; a.fat += m.fat; a.fiber += m.fiber
            for f in m.flags { a.flags[f, default: 0] += 1 }
            var seen = Set<FoodGroup>()
            for f in m.foods {
                a.grams[f.group, default: 0] += f.grams
                seen.insert(f.group)
                a.names.insert(f.name.replacingOccurrences(of: " ", with: ""))
            }
            for g in seen { a.groupMeals[g, default: 0] += 1 }
        }
        return a
    }

    struct CuisineStats {
        var cuisines: [(String, Int)] = []
        var methods: [(String, Int)] = []
        var missing: [String] = []
        var summary: String {
            let c = cuisines.map { "\($0.0)×\($0.1)" }.joined(separator: "、")
            let m = methods.map { "\($0.0)×\($0.1)" }.joined(separator: "、")
            return "本周菜系：\(c.isEmpty ? "无" : c)；做法：\(m.isEmpty ? "无" : m)；还没吃过：\(missing.prefix(6).joined(separator: "、"))"
        }
    }

    static func cuisineStats(_ meals: [Meal]) -> CuisineStats {
        var c: [String: Int] = [:], m: [String: Int] = [:]
        for meal in meals {
            if let x = meal.cuisine, !x.isEmpty { c[x, default: 0] += 1 }
            for k in meal.methods ?? [] { m[k, default: 0] += 1 }
        }
        var st = CuisineStats()
        st.cuisines = c.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
        st.methods = m.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
        st.missing = cuisineSuggest.filter { c[$0] == nil }
        return st
    }

    static func status(avg: Double, row: GuideRow) -> RowStatus {
        if avg <= 0 { return .none }
        if avg < row.min * 0.6 { return .low }
        if avg < row.min { return .slightlyLow }
        if avg > row.max * 1.3 { return .high }
        if avg > row.max { return .slightlyHigh }
        return .ok
    }

    static func onTimeRate(_ meals: [Meal], reminders: ReminderSettings) -> Int? {
        var n = 0, ok = 0
        for m in meals where MealSlot.mains.contains(m.slot) {
            n += 1
            if abs(D.minutes(m.time) - reminders.minutes(for: m.slot)) <= 60 { ok += 1 }
        }
        return n == 0 ? nil : Int((Double(ok) / Double(n) * 100).rounded())
    }

    /// 不同成员用的「每日建议量」表（宠物没有）
    static func rows(for kind: MemberKind) -> [GuideRow] {
        switch kind {
        case .me: return guideRows
        case .elder: return elderRows
        case .dog, .cat: return []
        }
    }

    // MARK: 宠物

    struct PetStats {
        var kcalPerDay = 0.0
        var target = 0
        var treatKcal = 0.0
        var totalKcal = 0.0
        var dangers: [(String, String)] = []      // (日期, 说明)
        var humanFoodMeals = 0
        var proteinPerDay = 0.0
        var fatPerDay = 0.0
        var treatShare: Double { totalKcal > 0 ? treatKcal / totalKcal : 0 }
    }

    static func petStats(_ meals: [Meal], member: Member) -> PetStats {
        var st = PetStats()
        st.target = member.kcalTarget
        let done = meals.filter { $0.status == .done }
        let days = Double(max(1, Set(meals.map(\.date)).count))
        for m in done {
            st.totalKcal += m.kcal
            if m.slot == .snack || m.foods.contains(where: { $0.group == .treat }) {
                // 零食：整餐算零食，或只算零食那部分（按重量占比粗估）
                if m.slot == .snack { st.treatKcal += m.kcal } else {
                    let all = m.foods.reduce(0) { $0 + $1.grams }
                    let t = m.foods.filter { $0.group == .treat }.reduce(0) { $0 + $1.grams }
                    if all > 0 { st.treatKcal += m.kcal * t / all }
                }
            }
            if m.foods.contains(where: { $0.group == .human }) { st.humanFoodMeals += 1 }
            if let d = m.danger, !d.isEmpty { st.dangers.append((m.date, d)) }
            st.proteinPerDay += m.protein; st.fatPerDay += m.fat
        }
        st.kcalPerDay = st.totalKcal / days
        st.proteinPerDay /= days; st.fatPerDay /= days
        return st
    }

    // MARK: 本地提醒规则

    @MainActor
    static func tips(store: Store, dates: [String]) -> [Tip] {
        tips(meals: store.meals(in: dates), member: store.member, dates: dates)
    }

    static func tips(meals: [Meal], member: Member, dates: [String]) -> [Tip] {
        let a = aggregate(meals)
        guard a.analyzed > 0 else { return [] }
        let dayIdx = min(7, (D.cal.dateComponents([.day], from: D.date(dates[0]), to: D.date(D.today)).day ?? 0) + 1)
        var t: [Tip] = []
        let name = member.displayName

        if member.kind.isPet {
            let st = petStats(meals, member: member)
            if let d = st.dangers.last { t.append(Tip(emoji: "⚠️", title: "吃到了危险食物", detail: d.1)) }
            if st.treatShare > 0.1 { t.append(Tip(emoji: "🦴", title: "零食占了 \(Int(st.treatShare * 100))% 的热量", detail: "零食最好不超过每天热量的 10%")) }
            if st.kcalPerDay > Double(st.target) * 1.15 { t.append(Tip(emoji: "⚖️", title: "\(name)吃得有点多", detail: "日均约 \(Int(st.kcalPerDay)) kcal，目标 \(st.target) kcal，减一点主粮或零食")) }
            if st.kcalPerDay < Double(st.target) * 0.7 && a.days.count >= 2 { t.append(Tip(emoji: "🍽️", title: "\(name)吃得偏少", detail: "如果是漏记就补上；一直吃得少要留意精神和体重")) }
            if st.humanFoodMeals >= 3 { t.append(Tip(emoji: "🍗", title: "这周吃了 \(st.humanFoodMeals) 次人吃的饭", detail: "人类食物油盐多，尽量以宠物粮为主")) }
            return t
        }

        let dn = a.dayCount
        let rows = rows(for: member.kind)
        func avg(_ id: String) -> Double { rows.first { $0.id == id }.map { a.value($0) / dn } ?? 0 }

        if member.kind == .elder {
            if avg("protein") < 100 { t.append(Tip(emoji: "🥚", title: "\(name)蛋白质可能不够", detail: "每天一个蛋、一杯奶，加些鱼虾或豆腐，预防肌肉流失")) }
            if avg("dairy") < 200 { t.append(Tip(emoji: "🥛", title: "奶制品偏少", detail: "老人每天 300ml 奶补钙，喝不惯可以换酸奶")) }
            if (a.flags["high_salt"] ?? 0) >= 2 { t.append(Tip(emoji: "🧂", title: "偏咸的餐有 \(a.flags["high_salt"] ?? 0) 次", detail: "老人更要控盐，咸菜、腌肉少吃")) }
            if (a.flags["hard"] ?? 0) >= 2 { t.append(Tip(emoji: "🦷", title: "偏硬难嚼的食物有点多", detail: "可以切小、炖软，或换成软烂一点的做法")) }
            if avg("vegs") < 250 { t.append(Tip(emoji: "🥬", title: "蔬菜偏少", detail: "炖软的青菜、蒸南瓜都适合老人")) }
            if a.groupMeals[.seafood] == nil && dayIdx >= 3 { t.append(Tip(emoji: "🐟", title: "这周还没吃鱼", detail: "清蒸鱼刺少的部位，补优质蛋白")) }
            return t
        }

        if a.groupMeals[.seafood] == nil && dayIdx >= 3 { t.append(Tip(emoji: "🐟", title: "这周还没吃鱼虾", detail: "每周至少 2 次水产，可以安排清蒸鱼、虾仁炒蛋")) }
        if avg("vegs") < 300 { t.append(Tip(emoji: "🥬", title: "蔬菜偏少（日均约 \(Int(avg("vegs")))g）", detail: "下一餐加一盘绿叶菜，深色蔬菜最好占一半")) }
        if avg("fruit") < 150 { t.append(Tip(emoji: "🍊", title: "水果吃得少", detail: "每天 200–350g，大约一个苹果加一根香蕉")) }
        if avg("dairy") < 150 { t.append(Tip(emoji: "🥛", title: "奶制品不够", detail: "一杯牛奶或一盒无糖酸奶就能补上不少")) }
        if a.groupMeals[.soy_nut] == nil && dayIdx >= 3 { t.append(Tip(emoji: "🫘", title: "这周还没吃豆制品/坚果", detail: "豆腐、豆浆或一小把坚果都可以")) }
        if a.groupMeals[.whole_grain] == nil && dayIdx >= 3 { t.append(Tip(emoji: "🌽", title: "主食全是精米白面", detail: "试试杂粮饭、燕麦、玉米替换一部分")) }
        if avg("meat") > 110 { t.append(Tip(emoji: "🍖", title: "畜禽肉偏多（日均约 \(Int(avg("meat")))g）", detail: "把一部分换成鱼、蛋或豆腐")) }
        if (a.flags["fried"] ?? 0) >= 3 { t.append(Tip(emoji: "🍟", title: "这周油炸 \(a.flags["fried"] ?? 0) 次了", detail: "接下来几餐清蒸、炖煮为主")) }
        if (a.flags["sugary"] ?? 0) + (a.groupMeals[.sweet] ?? 0) >= 4 { t.append(Tip(emoji: "🧋", title: "甜食/含糖饮料有点多", detail: "奶茶换成无糖茶或鲜奶")) }
        if (a.flags["high_salt"] ?? 0) >= 3 { t.append(Tip(emoji: "🧂", title: "重口味的餐偏多", detail: "每天盐不超过 5g，少喝汤底、少蘸酱")) }
        return t
    }

    /// 给 AI 的一周数据摘要（当前成员）
    @MainActor
    static func weekContext(store: Store, dates: [String]) -> (String, Int) {
        let member = store.member
        let ms = store.meals(in: dates).sorted { ($0.date + $0.time) < ($1.date + $1.time) }
        let a = aggregate(ms)
        let dn = a.dayCount
        let kind = member.kind
        let lines = ms.map { m -> String in
            let foods = m.foods.map { "\($0.name)\(Int($0.grams))g" }.joined(separator: "、")
            let fl = m.flags.compactMap { flagNames[$0] }.joined(separator: "/")
            let tag = [m.cuisine, m.methods?.joined(separator: "/"), m.shop.map { "店：" + $0 }, m.danger.map { "⚠️" + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return "\(m.date.suffix(5)) \(kind.slotName(m.slot)) \(m.time) \(m.title)\(tag.isEmpty ? "" : "（" + tag + "）")：" + "\(foods.isEmpty ? (m.note.isEmpty ? "未识别" : m.note) : foods)\(m.kcal > 0 ? "，约\(Int(m.kcal))kcal" : "")\(fl.isEmpty ? "" : "，" + fl)"
        }.joined(separator: "\n")
        let r = member.reminders
        let head: String
        if kind.isPet {
            let st = petStats(ms, member: member)
            head = """
            记录了 \(a.days.count) 天、\(ms.count) 顿。日均热量约 \(Int(st.kcalPerDay))kcal（目标 \(st.target)kcal），零食占热量 \(Int(st.treatShare * 100))%，蛋白 \(Int(st.proteinPerDay))g/天，脂肪 \(Int(st.fatPerDay))g/天。
            吃人类食物 \(st.humanFoodMeals) 次；危险食物：\(st.dangers.isEmpty ? "无" : st.dangers.map { $0.1 }.joined(separator: "；"))
            喂食提醒时间：\(D.hm(r.breakfast)) / \(D.hm(r.lunch)) / \(D.hm(r.dinner))
            """
        } else {
            let table = rows(for: kind).map { "\($0.name)：日均 \(Int(a.value($0) / dn))g（建议 \(Int($0.min))–\(Int($0.max))g）" }.joined(separator: "\n")
            head = """
            记录了 \(a.days.count) 天、\(ms.count) 餐；食物种类 \(a.names.count) 种（建议每周≥25种）。
            日均热量 \(Int(a.kcal / dn))kcal，蛋白 \(Int(a.protein / dn))g，碳水 \(Int(a.carbs / dn))g，脂肪 \(Int(a.fat / dn))g。
            各类食物（按已记录天数平均，谷物杂豆为生重）：
            \(table)
            \(cuisineStats(ms).summary)
            提醒时间：早餐\(D.hm(r.breakfast)) 午餐\(D.hm(r.lunch)) 晚餐\(D.hm(r.dinner))
            """
        }
        let text = head + "\n逐餐明细：\n" + lines
        return (text, ms.count)
    }
}
