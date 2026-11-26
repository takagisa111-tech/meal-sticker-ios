import Foundation
import UIKit

struct MenuPick: Identifiable, Hashable {
    let id = UUID()
    var emoji: String
    var dish: String
    var why: String
}

struct MenuAdvice {
    var picks: [MenuPick] = []
    var avoid: [MenuPick] = []
    var combo = ""
    var tip = ""
}

struct Recipe: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var emoji: String
    var minutes: Int
    var why: String
    var ingredients: [String]
    var missing: [String]
    var steps: [String]
}

extension AI {
    /// 拍菜单 → 结合这周缺的推荐点什么
    static func menuAdvice(image: UIImage, people: Int, context: String, profile: String, key: String) async throws -> MenuAdvice {
        let prompt = """
        你是营养师，用户在餐厅拍了一张菜单，准备点餐（\(people) 个人吃）。请读出菜单上的菜，结合用户这周的饮食情况，推荐怎么点：优先补上这周缺的营养，照顾菜式多样性，控制油炸和重口味。
        用户情况：\(profile)
        本周情况：
        \(context)
        只输出 JSON：{"picks":[{"emoji":"🥦","dish":"菜单上的菜名","why":"为什么推荐(≤20字)"}],"avoid":[{"emoji":"🍟","dish":"菜单上的菜名","why":"为什么少点(≤20字)"}],"combo":"一句话的推荐组合(≤40字)","tip":"一句提醒(≤24字)"}
        picks 2-5 道（只能写菜单上真实存在的菜），avoid 0-3 道。如果看不清菜单，picks 为空，tip 里说明。
        """
        let r = try await json(prompt: prompt, image: image, key: key)
        func picks(_ v: Any?) -> [MenuPick] { arr(v).map { MenuPick(emoji: str($0["emoji"]), dish: str($0["dish"]), why: str($0["why"])) }.filter { !$0.dish.isEmpty } }
        return MenuAdvice(picks: picks(r["picks"]), avoid: picks(r["avoid"]), combo: str(r["combo"]), tip: str(r["tip"]))
    }

    /// 冰箱食材 → 菜谱
    static func fridgeRecipes(image: UIImage?, text: String, context: String, profile: String, key: String) async throws -> ([Recipe], String) {
        let prompt = """
        你是会做家常菜的营养师。\(image != nil ? "图片是用户冰箱/厨房里的食材，请先认出有哪些食材。" : "")\(text.isEmpty ? "" : "用户说现有食材：" + text)
        请推荐 3 道用这些食材就能做（最多再买 1-2 样）的家常菜，优先补上用户这周缺的营养、照顾菜式多样性，步骤简单、30 分钟内为主。
        用户情况：\(profile)
        本周情况：
        \(context)
        只输出 JSON：{"found":"认出的食材，用顿号分隔","recipes":[{"name":"菜名","emoji":"🍳","minutes":20,"why":"补什么(≤20字)","ingredients":["鸡蛋 2个","番茄 1个"],"missing":["需要另外买的，没有就空数组"],"steps":["第一步…","第二步…"]}]}
        每道菜 steps 3-6 步，每步一句话。
        """
        let r = try await json(prompt: prompt, image: image, key: key)
        let recipes = arr(r["recipes"]).map {
            Recipe(name: str($0["name"]), emoji: str($0["emoji"]), minutes: Int(num($0["minutes"])), why: str($0["why"]),
                   ingredients: strs($0["ingredients"]), missing: strs($0["missing"]), steps: strs($0["steps"]))
        }.filter { !$0.name.isEmpty }
        return (recipes, str(r["found"]))
    }
}
