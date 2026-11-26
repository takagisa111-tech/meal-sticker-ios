import SwiftUI
import UIKit

/// 买菜平台。各家都没有开放「第三方加购物车」的接口，
/// 所以做法是：复制菜名 → 打开对应 App（能直达搜索的就直达搜索结果）。
enum GroceryApp: String, CaseIterable, Identifiable {
    case dingdong, meituan, hema, jd, taobao
    var id: String { rawValue }

    var name: String {
        switch self {
        case .dingdong: return "叮咚买菜"
        case .meituan: return "美团·小象超市"
        case .hema: return "盒马"
        case .jd: return "京东·七鲜"
        case .taobao: return "淘宝·闪购"
        }
    }

    var short: String {
        switch self {
        case .dingdong: return "叮咚"
        case .meituan: return "美团"
        case .hema: return "盒马"
        case .jd: return "京东"
        case .taobao: return "淘宝"
        }
    }

    /// 支持网页一键加购的平台
    var webShop: WebShop? {
        switch self {
        case .jd: return .jd
        case .taobao: return .taobao
        default: return nil
        }
    }

    /// 能直接跳到搜索结果的平台
    var canSearch: Bool { self == .jd || self == .taobao }

    private var openSchemes: [String] {
        switch self {
        case .dingdong: return ["dingdong://", "ddxq://", "ddmc://"]
        case .meituan: return ["imeituan://"]
        case .hema: return ["wdkhema://", "hema://"]
        case .jd: return ["openjd://"]
        case .taobao: return ["taobao://"]
        }
    }

    private func searchURL(_ keyword: String) -> URL? {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        switch self {
        case .jd:
            let params = "{\"des\":\"productList\",\"keyWord\":\"\(keyword)\",\"from\":\"search\",\"category\":\"jump\"}"
            let p = params.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? params
            return URL(string: "openjd://virtual?params=\(p)")
        case .taobao:
            return URL(string: "taobao://s.taobao.com/search?q=\(q)")
        default:
            return nil
        }
    }

    /// 没装 App 时打开 App Store
    private var storeURL: URL? {
        switch self {
        case .dingdong: return URL(string: "itms-apps://apps.apple.com/cn/app/id768082524")
        default:
            let t = name.components(separatedBy: "·").first ?? name
            let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            return URL(string: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=\(q)")
        }
    }

    /// 打开 App；有关键词且支持搜索时直达搜索结果
    @MainActor func open(search keyword: String? = nil) {
        var urls: [URL] = []
        if let k = keyword, let u = searchURL(k) { urls.append(u) }
        urls += openSchemes.compactMap(URL.init(string:))
        tryOpen(urls)
    }

    @MainActor private func tryOpen(_ urls: [URL]) {
        guard let first = urls.first else {
            if let s = storeURL { UIApplication.shared.open(s) }
            return
        }
        UIApplication.shared.open(first, options: [:]) { ok in
            if !ok { Task { @MainActor in tryOpen(Array(urls.dropFirst())) } }
        }
    }
}

/// 「去买菜」：选平台，逐项跳转搜索，或整单复制后打开 App
struct GroceryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let items: [String]
    var title: String = "采购清单"
    @AppStorage("groceryApp") private var appRaw = GroceryApp.dingdong.rawValue
    @State private var done: Set<String> = []
    @State private var syncing = false
    @State private var webShop: WebShopBox?

    private var app: GroceryApp { GroceryApp(rawValue: appRaw) ?? .dingdong }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "下单平台")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(GroceryApp.allCases) { a in
                                let on = a == app
                                Button { appRaw = a.rawValue } label: {
                                    Text(a.name).font(.system(size: 13, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? Color.white : Color.ink)
                                        .padding(.horizontal, 12).frame(height: 32)
                                        .background(on ? Color.ink : Color.card).clipShape(Capsule())
                                        .overlay(Capsule().strokeBorder(on ? Color.clear : Color.line, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1).padding(.vertical, 2)
                    }
                    .padding(.top, 8)

                    SectionHeader(title: "\(items.count) 项 · 轻点去\(app.short)搜索")
                    VStack(spacing: 0) {
                        ForEach(items.indices, id: \.self) { i in
                            let it = items[i]
                            if i > 0 { Rectangle().fill(Color.line).frame(height: 0.5).padding(.leading, 48) }
                            row(it)
                        }
                    }
                    .surface()
                    .padding(.top, 8)

                    Text(app.webShop != nil
                         ? "「一键加入」会在食贴内打开\(app.short)网页：首次需登录，之后自动逐项搜索并加购；遇到需要选规格或安全验证时，请在页面中手动完成。"
                         : app.canSearch
                         ? "轻点某一项会直接打开\(app.short)的搜索结果，选好规格加入购物车即可。"
                         : "\(app.short)暂不支持外部 App 直接搜索或加购。轻点某一项会复制名称并打开\(app.short)，在搜索框粘贴即可；也可以复制整单逐项搜索。")
                        .font(.system(size: 12)).foregroundStyle(Color.ink3)
                        .padding(.top, 10).padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        if let shop = app.webShop {
                            Button { webShop = WebShopBox(shop: shop) } label: {
                                Label("一键加入\(shop.name)购物车", systemImage: "cart.badge.plus")
                            }
                            .buttonStyle(PrimaryButton())
                        }
                        Button {
                            UIPasteboard.general.string = items.joined(separator: "\n")
                            store.flash("已复制 \(items.count) 项，正在打开\(app.short)")
                            app.open()
                        } label: {
                            Label("复制整单并打开\(app.short)", systemImage: "cart")
                        }
                        .buttonStyle(app.webShop != nil ? AnyButtonStyle(SoftButton()) : AnyButtonStyle(PrimaryButton()))

                        Button {
                            Task {
                                syncing = true
                                do { let n = try await ShoppingSync.add(items); store.flash("已添加到「提醒事项」\(n) 项") }
                                catch { store.flash((error as? AIError)?.message ?? "同步失败：\(error.localizedDescription)") }
                                syncing = false
                            }
                        } label: {
                            Label(syncing ? "正在同步…" : "添加到「提醒事项」", systemImage: "checklist")
                        }
                        .buttonStyle(SoftButton())
                        .disabled(syncing)
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(PageBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Color.brand)
        .presentationDetents([.large])
        .fullScreenCover(item: $webShop) { b in ShopCartView(items: items, shop: b.shop) }
    }

    private func row(_ it: String) -> some View {
        let checked = done.contains(it)
        return HStack(spacing: 12) {
            Button {
                if checked { done.remove(it) } else { done.insert(it) }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(checked ? Color.brand : Color.ink3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "标记为未买" : "标记为已买")

            Button {
                UIPasteboard.general.string = it
                if !app.canSearch { store.flash("已复制「\(it)」，到\(app.short)搜索框粘贴") }
                done.insert(it)
                app.open(search: it)
            } label: {
                HStack {
                    Text(it).font(.system(size: 15)).foregroundStyle(checked ? Color.ink3 : Color.ink)
                        .strikethrough(checked, color: Color.ink3)
                    Spacer()
                    HStack(spacing: 3) {
                        Text(app.canSearch ? "搜索" : "去\(app.short)")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// 运行时切换按钮样式
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct WebShopBox: Identifiable {
    let shop: WebShop
    var id: String { shop.name }
}
