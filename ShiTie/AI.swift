import Foundation
import UIKit

struct AIError: Error {
    let message: String
    var retryable = false
}

struct MealResult {
    var title = "", emoji = ""
    var foods: [FoodItem] = []
    var kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0, fiber = 0.0
    var flags: [String] = []
    var comment = ""
    var cuisine = ""
    var methods: [String] = []
    var shop = ""
    var danger = ""
}

struct MealIdea: Identifiable, Hashable {
    let id = UUID()
    var emoji: String
    var dish: String
    var why: String
    var kcal: Double
    var search: String = ""   // 出去吃时用来搜附近店的关键词，比如「粤菜」「轻食」
}

/// DeepSeek 开放平台（OpenAI 兼容格式）。识图模型：deepseek-flash
enum AI {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let model = "deepseek-flash"

    // MARK: 底层调用

    /// 解析失败（比如输出被截断）时自动再试一次
    static func json(prompt: String, image: UIImage? = nil, key: String) async throws -> [String: Any] {
        do {
            return try await jsonOnce(prompt: prompt, image: image, key: key)
        } catch let e as AIError where e.retryable {
            return try await jsonOnce(prompt: prompt + "\n\n再次强调：只输出 JSON 本身，保持简短，foods 最多列 12 项。", image: image, key: key)
        }
    }

    static func jsonOnce(prompt: String, image: UIImage? = nil, key: String) async throws -> [String: Any] {
        guard !key.isEmpty else { throw AIError(message: "还没有填 DeepSeek API Key（我的 → API Key）") }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image, let data = jpeg(image) {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "temperature": 0.3,
            "max_tokens": 6000,
            "stream": false,
            // deepseek-flash 默认开启深度思考，菜多时思考内容会占满输出长度，导致 JSON 被截断。识别餐食不需要深度思考，关掉更快更省钱。
            "thinking": ["type": "disabled"],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 150
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw AIError(message: "AI 想太久超时了，再点一次「重新识别」", retryable: true) }
        catch { throw AIError(message: "网络连接失败，检查一下网络再试") }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let detail = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            switch code {
            case 401: throw AIError(message: "API Key 不对，去「我的」里检查一下")
            case 402: throw AIError(message: "DeepSeek 余额不足，去开放平台充值")
            case 429: throw AIError(message: "调用太频繁，稍等一下再试")
            case 400: throw AIError(message: "请求被拒绝：\(detail)")
            default: throw AIError(message: "DeepSeek 出错了（\(code)），稍后再试")
            }
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String, !text.isEmpty
        else { throw AIError(message: "AI 没有给出结果，再试一次", retryable: true) }
        guard let parsed = extractJSON(text) else {
            let cut = (choices.first?["finish_reason"] as? String) == "length"
            throw AIError(message: cut ? "这餐内容太多，结果被截断了，再试一次" : "AI 返回的格式看不懂，再试一次", retryable: true)
        }
        return parsed
    }

    static func jpeg(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 1024
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let flat = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return flat.jpegData(compressionQuality: 0.82)
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b { t = String(t[a...b]) }
        guard let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.filter { "0123456789.".contains($0) }) ?? 0 }
        return 0
    }
    static func str(_ v: Any?) -> String { (v as? String) ?? (v.map { "\($0)" } ?? "") }
    static func arr(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }
    static func strs(_ v: Any?) -> [String] { (v as? [Any])?.map { str($0) } ?? [] }

    // MARK: 识别一餐

    static var mealSchema: String { """
    只输出一个 JSON 对象，不要任何其他文字：
    {"title":"这餐的简短名字(≤8字)","emoji":"一个最能代表它的食物emoji","cuisine":"川菜","methods":["炒"],"foods":[{"name":"米饭","grams":75,"group":"grain"}],"kcal":620,"protein":24,"carbs":80,"fat":18,"fiber":5,"flags":[],"comment":"一句具体、温和的营养点评(≤30字)"}
    cuisine 从这些里选一个最贴切的：\(cuisineList.joined(separator: "、"))。methods 是这餐用到的主要做法，从这些里选：\(cookMethods.joined(separator: "、"))。
    group 只能取：grain(精米白面等精制谷物) whole_grain(糙米燕麦玉米小米红豆绿豆等全谷物和杂豆) tuber(土豆红薯芋头山药) veg(浅色蔬菜) dark_veg(深绿/红/橙/紫色蔬菜) fruit meat(猪牛羊鸡鸭及其制品) seafood(鱼虾贝等水产) egg dairy(牛奶酸奶奶酪) soy_nut(大豆、豆腐豆浆等豆制品、坚果) sweet(甜点、含糖饮料、糖果零食) other(其他)。
    grams 估算实际吃下的量：谷物和杂豆折算成生重/干重（一碗米饭约折合生米75g，一个馒头约折合面粉60g）；豆制品折算成大豆重量；其余按可食部分重量。
    kcal、protein、carbs、fat、fiber 是整餐估算（单位：千卡/克）。
    """ }

    static var petSchema: String { """
    只输出一个 JSON 对象，不要任何其他文字：
    {"title":"这顿的简短名字(≤8字)","emoji":"一个最能代表它的emoji","foods":[{"name":"鸡肉冻干","grams":20,"group":"treat"}],"kcal":320,"protein":20,"carbs":15,"fat":12,"fiber":2,"flags":[],"danger":"","comment":"一句具体的喂养点评(≤30字)"}
    group 只能取：kibble(干粮主粮) wetfood(湿粮罐头/主食罐) treat(零食冻干肉干洁齿骨等) meat seafood egg veg fruit grain dairy human(人吃的饭菜，有油盐调味) other。
    grams 估算这次吃下的量。kcal 等为这一顿估算值；宠物粮按常见能量密度估算（干粮约 3.5–4 kcal/g，湿粮约 0.8–1.2 kcal/g）。
    danger：如果这顿里有对这种动物有毒或危险的东西（如狗/猫：葡萄和葡萄干、洋葱大蒜韭菜葱、巧克力、咖啡因、酒精、木糖醇、夏威夷果、牛油果、生面团、熟骨头、调味重的人类食物；猫还要注意百合、生鱼长期喂食、牛奶），用一句话写清楚是什么、为什么危险、该怎么办；没有就空字符串。
    flags 从 ["danger","fatty","high_salt"] 里选，没有就空数组。
    """ }

    static func analyzeMeal(meal: Meal, image: UIImage?, text: String, member: Member, key: String, takeout: Bool = false) async throws -> MealResult {
        let kind = member.kind
        let slot = kind.slotName(meal.slot)
        let task: String
        if takeout {
            task = "这是一张外卖订单截图。请读出订单里的店名和每道菜及份数，按「一个人吃完了这些」估算分量和营养（如果明显是多人份，按一人份估算并在 comment 里说明）。额外输出 \"shop\":\"店名\"。"
        } else if image != nil {
            task = kind.isPet ? "请识别图片里这一顿喂了什么，估算分量和营养。" : "请识别图片里这一餐吃了什么，估算分量和营养。"
        } else {
            task = "根据用户的文字描述估算这一\(kind.isPet ? "顿" : "餐")的分量和营养。"
        }
        let role: String
        let extraRule: String
        switch kind {
        case .me:
            role = "你是一位细心的注册营养师，帮用户记录饮食。"
            extraRule = "flags 从 [\"fried\",\"high_salt\",\"sugary\",\"processed\"] 里选（油炸/重盐/高糖/加工肉），没有就空数组。"
        case .elder:
            role = "你是一位熟悉老年营养的注册营养师，帮用户记录家里老人的饮食。点评时关注：蛋白质够不够、软烂好不好嚼、咸不咸、钙和蔬菜。"
            extraRule = "flags 从 [\"fried\",\"high_salt\",\"sugary\",\"processed\",\"hard\",\"spicy\"] 里选（油炸/重盐/高糖/加工肉/偏硬难嚼/辛辣），没有就空数组。comment 写给照顾老人的家人看。"
        case .dog, .cat:
            role = "你是一位宠物营养师，帮主人记录\(kind == .dog ? "狗狗" : "猫咪")的饮食，判断有没有不能吃的东西。"
            extraRule = ""
        }
        let prompt = """
        \(role)\(task)
        这是\(slot)（\(meal.date) \(meal.time)）。\(text.isEmpty ? "" : "用户补充：" + text)
        对象情况：\(member.profileText)。
        \(kind.isPet ? petSchema : mealSchema)
        \(extraRule)
        """
        let r = try await json(prompt: prompt, image: image, key: key)
        var out = MealResult()
        out.title = String(str(r["title"]).prefix(12))
        out.emoji = String(str(r["emoji"]).prefix(2))
        out.foods = arr(r["foods"]).prefix(20).compactMap { f in
            let name = String(str(f["name"]).prefix(20))
            guard !name.isEmpty else { return nil }
            return FoodItem(name: name, grams: num(f["grams"]).rounded(), group: FoodGroup(rawValue: str(f["group"])) ?? .other)
        }
        out.kcal = num(r["kcal"]).rounded(); out.protein = num(r["protein"]).rounded()
        out.carbs = num(r["carbs"]).rounded(); out.fat = num(r["fat"]).rounded(); out.fiber = num(r["fiber"]).rounded()
        out.flags = strs(r["flags"]).filter { flagNames[$0] != nil }
        out.comment = String(str(r["comment"]).prefix(60))
        let c = str(r["cuisine"])
        out.cuisine = kind.isPet ? "" : (cuisineList.contains(c) ? c : (c.isEmpty ? "" : "其他"))
        out.methods = strs(r["methods"]).filter { cookMethods.contains($0) }
        out.shop = String(str(r["shop"]).prefix(30))
        out.danger = String(str(r["danger"]).prefix(80))
        if !out.danger.isEmpty && !out.flags.contains("danger") { out.flags.append("danger") }
        return out
    }

    static func emojiTitle(for text: String, key: String) async -> (String, String) {
        let p = "为这顿饭挑一个最贴切的食物 emoji，并起一个≤8字的名字。只输出 JSON：{\"emoji\":\"🍜\",\"title\":\"牛肉面\"}\n内容：\(text)"
        guard let r = try? await json(prompt: p, key: key) else { return ("🍽️", String(text.prefix(8))) }
        let e = str(r["emoji"])
        return (e.isEmpty ? "🍽️" : String(e.prefix(2)), String(str(r["title"]).prefix(10)))
    }

    // MARK: 周报

    static func weeklyReport(context: String, member: Member, key: String, mealCount: Int) async throws -> WeekReport {
        let today = D.weekday(D.today)
        let intro: String
        let focus: String
        switch member.kind {
        case .me:
            intro = "你是温和、专业的注册营养师，参考《中国居民膳食指南(2022)》，分析用户这一周的饮食"
            focus = "菜式方面，看菜系和做法是否单一（比如一周都是同一类菜、油炸太多），在 missing/too_much 里提出，plan 里安排一些这周还没吃过的菜系。"
        case .elder:
            intro = "你是熟悉老年营养的注册营养师，参考《中国老年人膳食指南》，分析家里老人这一周的饮食，建议写给照顾老人的家人看"
            focus = "重点看：蛋白质（预防肌肉流失）、奶和钙、盐和腌制品、食物是否软烂好嚼、蔬果、少量多餐和按时吃饭。plan 安排适合老人的软烂、清淡菜品。"
        case .dog, .cat:
            intro = "你是宠物营养师，分析这只\(member.kind == .dog ? "狗" : "猫")这一周的饮食，建议写给主人看"
            focus = "重点看：总热量和目标比是否合适、零食是否超过 10%、有没有吃到危险食物、人类食物是否太多、喂食时间是否规律。不要追求菜式多样，宠物主粮稳定更重要。plan 写接下来几顿怎么喂（份量、零食怎么控制）；shopping 写需要买的宠物用品或食材。"
        }
        let prompt = """
        \(intro)，用中文给出具体可执行的建议（不要说教，不做医学诊断，出现严重问题时建议就医/看兽医）。
        对象情况：\(member.profileText)
        今天是周\(today)。
        \(context)

        注意：数据来自照片估算，可能漏记；只针对记录到的内容判断。按时方面，对比每顿时间和提醒时间。\(focus)
        只输出 JSON：
        {"score":0到100的评分,"headline":"一句话总结(≤24字)","good":["做得好的点"],"missing":[{"item":"缺少的/该加强的","advice":"具体怎么做(≤30字)"}],"too_much":[{"item":"多了的/要注意的","advice":"怎么调整(≤30字)"}],"plan":[{"when":"如：周三晚饭","dish":"具体安排","emoji":"🐟","why":"为什么(≤20字)"}],"shopping":["购物清单"],"habit":"关于规律进食/按时的一句建议"}
        good 1-3 条，missing 和 too_much 各 0-4 条，plan 3-5 条（从今天之后开始安排），shopping 3-8 项。
        """
        let r = try await json(prompt: prompt, key: key)
        return WeekReport(
            at: Date(), mealCount: mealCount, score: Int(num(r["score"])), headline: str(r["headline"]),
            good: strs(r["good"]).isEmpty ? arr(r["good"]).map { str($0["item"]) } : strs(r["good"]),
            missing: arr(r["missing"]).map { ReportItem(item: str($0["item"]), advice: str($0["advice"])) },
            tooMuch: arr(r["too_much"]).map { ReportItem(item: str($0["item"]), advice: str($0["advice"])) },
            plan: arr(r["plan"]).map { ReportPlan(when: str($0["when"]), dish: str($0["dish"]), emoji: str($0["emoji"]), why: str($0["why"])) },
            shopping: strs(r["shopping"]), habit: str(r["habit"])
        )
    }

    // MARK: 下一餐吃什么

    static func nextMeal(slot: MealSlot, today: String, context: String, member: Member, key: String) async throws -> ([MealIdea], String) {
        let kind = member.kind
        let name = kind.slotName(slot)
        let ask: String
        switch kind {
        case .me:
            ask = "用户接下来要吃\(name)，请根据今天已经吃的和这周的整体情况，推荐 3 个家常、容易买到或做到的\(name)方案（出去吃、外卖或自己做都行），优先补上这周缺的营养，也照顾菜式多样性（多推荐这周还没吃过的菜系或做法，少推荐这周已经吃多的）。"
        case .elder:
            ask = "家里老人接下来要吃\(name)，请推荐 3 个适合老人的\(name)方案：软烂好嚼、清淡少盐、蛋白质足够，优先补上这周缺的，做法简单。search 写如果出去吃适合搜什么店（如 粥铺、蒸菜）。"
        case .dog, .cat:
            ask = "主人接下来要喂\(member.displayName)\(name)，请给出 3 个喂法建议（主粮份量、可以加的安全食材或零食怎么控制），结合这周的热量和零食情况。kcal 写这顿建议的热量，search 留空。"
        }
        let prompt = """
        你是\(kind.isPet ? "宠物营养师" : "营养师")。\(ask)
        对象情况：\(member.profileText)
        今天已吃：\(today)
        本周情况：
        \(context)
        只输出 JSON：{"ideas":[{"emoji":"🥗","dish":"具体搭配","why":"补什么/为什么(≤24字)","kcal":550,"search":"如果出去吃，在地图上搜什么类型的店(2-4字，如 粤菜、轻食、鱼火锅)"}],"tip":"一句提醒(≤24字)"}
        """
        let r = try await json(prompt: prompt, key: key)
        let ideas = arr(r["ideas"]).map { MealIdea(emoji: str($0["emoji"]), dish: str($0["dish"]), why: str($0["why"]), kcal: num($0["kcal"]), search: kind.isPet ? "" : str($0["search"])) }
        return (ideas, str(r["tip"]))
    }

    // MARK: 能不能吃（宠物 / 老人）

    struct CanEat {
        var verdict: String   // ok / little / no
        var title: String
        var reason: String
        var tip: String
    }

    static func canEat(_ food: String, image: UIImage?, member: Member, key: String) async throws -> CanEat {
        let who = member.kind.isPet ? "这只\(member.kind == .dog ? "狗" : "猫")" : "这位老人"
        let prompt = """
        你是\(member.kind.isPet ? "宠物营养师" : "老年营养师")。主人想知道\(who)能不能吃：\(food.isEmpty ? "图片里的东西" : food)。
        对象情况：\(member.profileText)
        判断要谨慎，有毒或有风险就直说；不确定时偏保守。
        只输出 JSON：{"verdict":"ok 或 little 或 no","title":"一句结论(≤14字)，如：可以少量吃","reason":"为什么(≤50字)","tip":"怎么喂/怎么做更安全，或者误食了怎么办(≤50字)"}
        verdict：ok=可以吃；little=可以但要少量或处理后吃；no=不能吃。
        """
        let r = try await json(prompt: prompt, image: image, key: key)
        let v = str(r["verdict"])
        return CanEat(verdict: ["ok", "little", "no"].contains(v) ? v : "little", title: str(r["title"]), reason: str(r["reason"]), tip: str(r["tip"]))
    }
}
