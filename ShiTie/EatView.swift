import SwiftUI
import PhotosUI
import MapKit

/// 「吃什么」：本周菜式、附近找店、拍菜单点菜、冰箱菜谱、购物清单
struct EatView: View {
    @EnvironmentObject var store: Store
    var onClose: (() -> Void)? = nil     // 从管家里弹出来时显示关闭按钮
    @State private var query = ""
    @State private var nearby: IDBox?
    @State private var showNext = false
    @State private var showMenu = false
    @State private var showFridge = false
    @State private var syncing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.kind.isPet ? "喂养建议" : "推荐").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
                        }
                        Spacer()
                        MemberMenu(compact: true)
                        if let onClose { IconButton(symbol: "xmark", label: "关闭", action: onClose) }
                    }
                    .padding(.top, 8)
                    nextCard.padding(.top, 16)
                    if store.kind.isPet || store.kind == .elder {
                        SectionHeader(title: "食物安全查询")
                        CanEatCard().padding(.top, 8)
                    }
                    if !store.kind.isPet {
                        SectionHeader(title: "附近餐厅")
                        findCard.padding(.top, 8)
                        SectionHeader(title: "本周菜系分布")
                        cuisineCard.padding(.top, 8)
                        SectionHeader(title: "点餐与做饭")
                        toolsCard.padding(.top, 8)
                    }
                    SectionHeader(title: "采购清单")
                    shoppingCard.padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PageBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $nearby) { b in NearbyView(keyword: b.id) }
        .sheet(isPresented: $showNext) { NextMealView() }
        .sheet(isPresented: $showMenu) { MenuAdviceView() }
        .sheet(isPresented: $showFridge) { FridgeView() }
    }

    private var nextCard: some View {
        let slot = MealSlot.guess()
        return Button { showNext = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color.brand).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.kind.isPet ? "下一餐喂什么" : (store.kind == .elder ? "\(store.member.displayName)的\(slot.name)推荐" : "\(slot.name)推荐"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                    Text(store.kind.isPet ? "按热量需求和零食占比给出喂法" : "根据今日摄入与本周缺口，给出 3 个搭配方案").font(.system(size: 12)).foregroundStyle(Color.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .surface()
    }

    private var cuisineCard: some View {
        let st = Nutrition.cuisineStats(store.meals(in: D.weekDates(offset: 0)))
        return CardBox {
            if st.cuisines.isEmpty {
                Text("识别几餐后，这里会统计本周吃过的菜系与烹饪方式。").font(.system(size: 13)).foregroundStyle(Color.ink2)
            } else {
                sub("已吃过")
                FlowLayout {
                    ForEach(st.cuisines, id: \.0) { c in Pill(text: "\(c.0) ×\(c.1)", style: .green) }
                }
                if !st.methods.isEmpty {
                    sub("烹饪方式")
                    FlowLayout {
                        ForEach(st.methods, id: \.0) { m in
                            Pill(text: "\(m.0) ×\(m.1)", style: (m.0 == "炸" && m.1 >= 3) || (m.0 == "烤" && m.1 >= 4) ? .red : .plain)
                        }
                    }
                }
            }
            if !st.missing.isEmpty {
                Rectangle().fill(Color.line).frame(height: 0.5)
                HStack {
                    sub("本周尚未尝试")
                    Spacer()
                    Text("轻点查找附近餐厅").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                FlowLayout {
                    ForEach(st.missing.prefix(8), id: \.self) { c in
                        Button { nearby = IDBox(id: c) } label: {
                            HStack(spacing: 4) {
                                Text(c)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.card).clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                        }
                    }
                }
            }
        }
    }

    private func sub(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink2)
    }

    private var findCard: some View {
        CardBox {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink3)
                TextField("搜索菜系或菜品，如 粤菜、轻食", text: $query)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                    .onSubmit { go() }
                if !query.isEmpty {
                    Button("搜索", action: go).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.brand)
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(Color.fill).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
            FlowLayout {
                ForEach(["轻食沙拉", "清蒸鱼", "粥铺", "蔬菜多的", "日料", "酸菜鱼"], id: \.self) { k in
                    Button { nearby = IDBox(id: k) } label: { Pill(text: k) }
                }
            }
            Text("店铺数据来自 Apple 地图，评分与评价可跳转大众点评查看。").font(.system(size: 11)).foregroundStyle(Color.ink3)
        }
    }

    private func go() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        nearby = IDBox(id: q)
    }

    private var toolsCard: some View {
        VStack(spacing: 0) {
            tool("menucard", "菜单点餐建议", "在餐厅拍下菜单，按本周缺口推荐点什么") { showMenu = true }
            Rectangle().fill(Color.line).frame(height: 0.5).padding(.leading, 62)
            tool("refrigerator", "冰箱食材做菜", "拍下或列出现有食材，推荐可做的菜") { showFridge = true }
        }
        .surface()
    }

    private func tool(_ symbol: String, _ t: String, _ s: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.brand)
                    .frame(width: 34, height: 34).background(Color.brandSoft).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
                    Text(s).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder private var shoppingCard: some View {
        let items = store.report(D.weekDates(offset: 0)[0])?.shopping ?? []
        CardBox {
            if items.isEmpty {
                Text("在「分析」页生成本周评估报告后，这里会列出建议采购的食材。").font(.system(size: 13)).foregroundStyle(Color.ink2)
            } else {
                FlowLayout { ForEach(items, id: \.self) { Pill(text: $0, style: .green) } }
                ShoppingButton(items: items, label: "去买菜 · 叮咚 / 美团 / 盒马", prominent: true)
            }
        }
    }
}

// MARK: - 能不能吃（宠物 / 老人）

struct CanEatCard: View {
    @EnvironmentObject var store: Store
    @State private var food = ""
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var result: AI.CanEat?

    private var examples: [String] {
        switch store.kind {
        case .dog: return ["葡萄", "鸡胸肉", "苹果", "牛奶", "巧克力"]
        case .cat: return ["金枪鱼罐头", "牛奶", "鸡蛋黄", "洋葱", "猫草"]
        default: return ["柿子", "糯米团", "西柚", "腌菜", "坚果"]
        }
    }

    var body: some View {
        CardBox {
            Text(store.kind.isPet ? "查询某种食物能否给\(store.member.displayName)吃" : "查询某种食物是否适合\(store.member.displayName)").font(.system(size: 13)).foregroundStyle(Color.ink2)
            HStack(spacing: 8) {
                TextField("输入食物，比如 葡萄", text: $food)
                    .submitLabel(.search)
                    .onSubmit { Task { await run() } }
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(Color.fill).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
                PhotosPicker(selection: $item, matching: .images) {
                    Image(systemName: image == nil ? "camera" : "photo.fill").font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
                }
                .foregroundStyle(Color.ink)
                Button { Task { await run() } } label: {
                    Group { if loading { ProgressView().tint(.white) } else { Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold)) } }
                        .foregroundStyle(.white).frame(width: 42, height: 42).background(Color.brand).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(loading || (food.trimmingCharacters(in: .whitespaces).isEmpty && image == nil))
            }
            FlowLayout {
                ForEach(examples, id: \.self) { e in
                    Button { food = e; Task { await run() } } label: { Pill(text: e) }
                }
            }
            if let r = result {
                let style: (String, Color, Color) = r.verdict == "ok" ? ("checkmark.circle.fill", .brand, .brandSoft) : (r.verdict == "no" ? ("xmark.octagon.fill", .tomato, .tomatoSoft) : ("exclamationmark.triangle.fill", Color(red: 0.6, green: 0.44, blue: 0.1), .butterSoft))
                VStack(alignment: .leading, spacing: 6) {
                    Label(r.title, systemImage: style.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(style.1)
                    if !r.reason.isEmpty { Text(r.reason).font(.system(size: 13)).foregroundStyle(Color.ink) }
                    if !r.tip.isEmpty { Text(r.tip).font(.system(size: 13)).foregroundStyle(Color.ink2) }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(style.2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    image = StickerMaker.normalized(img, maxSide: 1200)
                    await run()
                }
            }
        }
        .onChange(of: store.currentID) { _, _ in result = nil; image = nil; food = "" }
    }

    private func run() async {
        let f = food.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty || image != nil else { return }
        loading = true
        do { result = try await AI.canEat(f, image: f.isEmpty ? image : nil, member: store.member, key: store.apiKey) }
        catch { store.flash((error as? AIError)?.message ?? error.localizedDescription) }
        loading = false
        image = nil
    }
}

// MARK: - 附近的店（地图 + 列表）

struct NearbyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loc = LocationProvider()
    @State var keyword: String
    @State private var places: [Place] = []
    @State private var loading = true
    @State private var error = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: UUID?

    init(keyword: String) { _keyword = State(initialValue: keyword) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            Button { Dianping.search(keyword) } label: {
                                HStack {
                                    Image(systemName: "star.bubble.fill")
                                    Text("在大众点评里搜「\(keyword)」，看评分和评价").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .foregroundStyle(Color.ink)
                                .padding(12).surface(radius: 12)
                            }
                            if loading {
                                HStack { ProgressView(); Text("正在找附近的店…").foregroundStyle(Color.ink2) }.padding(.vertical, 20)
                            } else if !error.isEmpty {
                                Text(error).foregroundStyle(Color.ink2).padding(.vertical, 20)
                            } else if places.isEmpty {
                                Text("附近没找到「\(keyword)」，换个词试试，或者直接去大众点评搜。").foregroundStyle(Color.ink2).padding(.vertical, 20)
                            } else {
                                if loc.denied {
                                    Text("没有定位权限，结果可能不在你附近（设置 → 食贴 → 位置）").font(.caption).foregroundStyle(Color.ink2)
                                }
                                ForEach(Array(places.enumerated()), id: \.element.id) { i, p in
                                    PlaceRow(place: p, index: i + 1, highlighted: selected == p.id)
                                        .id(p.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { select(p) }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: selected) { _, id in
                        if let id { withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
            }
            .background(PageBackground())
            .navigationTitle(keyword)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "想吃什么")
            .onSubmit(of: .search) { Task { await load() } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await load() }
        }
    }

    private var map: some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()
            ForEach(Array(places.enumerated()), id: \.element.id) { i, p in
                Marker(p.name, monogram: Text("\(i + 1)"), coordinate: p.item.placemark.coordinate)
                    .tint(selected == p.id ? Color.brand : Color.ink2)
                    .tag(p.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .frame(height: 300)
        .overlay(alignment: .bottom) {
            if let id = selected, let p = places.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(p.distanceText).font(.caption2).foregroundStyle(Color.ink2)
                    }
                    Spacer()
                    Button { Dianping.search(p.name) } label: { Text("点评").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderedProminent).tint(.brand)
                    Button { _ = p.item.openInMaps() } label: { Text("导航").font(.caption.weight(.semibold)) }
                        .buttonStyle(.bordered).tint(.ink2)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(10)
            }
        }
    }

    private func select(_ p: Place) {
        selected = p.id
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: p.item.placemark.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private func load() async {
        loading = true
        error = ""
        selected = nil
        let l = await loc.current()
        do { places = try await Nearby.search(keyword, near: l) }
        catch { places = []; self.error = "搜索失败：\(error.localizedDescription)" }
        loading = false
        withAnimation(.easeInOut) { camera = .automatic }
    }
}

struct PlaceRow: View {
    let place: Place
    var index: Int = 0
    var highlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(highlighted ? Color.brand : Color.ink2).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(place.name).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(place.distanceText).font(.caption).foregroundStyle(Color.ink2)
                }
                if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(Color.ink2).lineLimit(2) }
                HStack(spacing: 8) {
                    Button { Dianping.search(place.name) } label: { Label("点评", systemImage: "star.bubble") }
                        .buttonStyle(.bordered).tint(.ink)
                    Button { _ = place.item.openInMaps() } label: { Label("导航", systemImage: "map") }
                        .buttonStyle(.bordered).tint(.ink2)
                    if let phone = place.phone, let url = URL(string: "tel://" + phone.filter { "0123456789+".contains($0) }) {
                        Button { UIApplication.shared.open(url) } label: { Label("电话", systemImage: "phone") }
                            .buttonStyle(.bordered).tint(.brand)
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(highlighted ? Color.brand : Color.line, lineWidth: highlighted ? 1.5 : 0.5))
    }
}

// MARK: - 拍菜单帮我点

struct MenuAdviceView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var image: UIImage?
    @State private var people = 1
    @State private var loading = false
    @State private var advice: MenuAdvice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let img = image {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    HStack(spacing: 10) {
                        Button { showCamera = true } label: { pickLabel("📷", "拍菜单") }
                        PhotosPicker(selection: $item, matching: .images) { pickLabel("🖼️", "从相册选") }
                    }
                    .foregroundStyle(Color.ink)
                    Stepper("几个人吃：\(people) 人", value: $people, in: 1...10)
                        .padding(12).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
                    Button { Task { await run() } } label: {
                        HStack {
                            if loading { ProgressView().tint(.white) }
                            Text(loading ? "正在看菜单…" : "帮我点菜") }
                            .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(image == nil ? Color.gray.opacity(0.4) : Color.brand).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(image == nil || loading)

                    if let a = advice { result(a) }
                }
                .padding(18)
            }
            .background(PageBackground())
            .navigationTitle("菜单点餐建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { image = StickerMaker.normalized($0, maxSide: 1800); advice = nil }.ignoresSafeArea() }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    image = StickerMaker.normalized(img, maxSide: 1800); advice = nil
                }
            }
        }
    }

    private func pickLabel(_ e: String, _ t: String) -> some View {
        HStack { Text(e); Text(t).font(.subheadline.weight(.semibold)) }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
    }

    private func run() async {
        guard let img = image else { return }
        loading = true
        let (ctx, _) = Nutrition.weekContext(store: store, dates: D.weekDates(offset: 0))
        do { advice = try await AI.menuAdvice(image: img, people: people, context: ctx, profile: store.profileText, key: store.apiKey) }
        catch { store.flash((error as? AIError)?.message ?? error.localizedDescription) }
        loading = false
    }

    @ViewBuilder private func result(_ a: MenuAdvice) -> some View {
        if !a.combo.isEmpty {
            Text("👉 " + a.combo).font(.system(size: 15, weight: .semibold)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.butterSoft).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        if !a.picks.isEmpty {
            CardBox {
                CardTitle(text: "推荐点")
                ForEach(a.picks) { p in TipRow(emoji: p.emoji.isEmpty ? "✅" : p.emoji, title: p.dish, detail: p.why) }
            }
        }
        if !a.avoid.isEmpty {
            CardBox {
                CardTitle(text: "这次少点")
                ForEach(a.avoid) { p in TipRow(emoji: p.emoji.isEmpty ? "➖" : p.emoji, title: p.dish, detail: p.why) }
            }
        }
        if !a.tip.isEmpty { Text("💡 " + a.tip).font(.subheadline).foregroundStyle(Color.ink2) }
    }
}

// MARK: - 冰箱里有什么

struct FridgeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var image: UIImage?
    @State private var text = ""
    @State private var loading = false
    @State private var recipes: [Recipe] = []
    @State private var found = ""
    @State private var open: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let img = image {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 200).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    HStack(spacing: 10) {
                        Button { showCamera = true } label: { label("📷", "拍冰箱") }
                        PhotosPicker(selection: $item, matching: .images) { label("🖼️", "从相册选") }
                    }
                    .foregroundStyle(Color.ink)
                    TextField("或者直接写：鸡蛋、番茄、半颗西兰花、豆腐…", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(12).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                    Button { Task { await run() } } label: {
                        HStack {
                            if loading { ProgressView().tint(.white) }
                            Text(loading ? "正在想菜谱…" : "推荐能做的菜") }
                            .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(canRun ? Color.brand : Color.gray.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canRun || loading)

                    if !found.isEmpty { Text("认出的食材：" + found).font(.caption).foregroundStyle(Color.ink2) }
                    ForEach(recipes) { r in recipeCard(r) }
                }
                .padding(18)
            }
            .background(PageBackground())
            .navigationTitle("冰箱食材做菜")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { image = StickerMaker.normalized($0, maxSide: 1600) }.ignoresSafeArea() }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { image = StickerMaker.normalized(img, maxSide: 1600) }
            }
        }
    }

    private var canRun: Bool { image != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    private func label(_ e: String, _ t: String) -> some View {
        HStack { Text(e); Text(t).font(.subheadline.weight(.semibold)) }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
    }

    private func run() async {
        loading = true
        let (ctx, _) = Nutrition.weekContext(store: store, dates: D.weekDates(offset: 0))
        do {
            let (r, f) = try await AI.fridgeRecipes(image: image, text: text, context: ctx, profile: store.profileText, key: store.apiKey)
            recipes = r; found = f; open = r.first?.id
        } catch { store.flash((error as? AIError)?.message ?? error.localizedDescription) }
        loading = false
    }

    private func recipeCard(_ r: Recipe) -> some View {
        CardBox {
            Button { open = open == r.id ? nil : r.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(r.emoji.isEmpty ? "🍳" : r.emoji).font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.headline)
                        Text("\(r.minutes > 0 ? "约 \(r.minutes) 分钟 · " : "")\(r.why)").font(.caption).foregroundStyle(Color.ink2)
                    }
                    Spacer()
                    Image(systemName: open == r.id ? "chevron.up" : "chevron.down").foregroundStyle(Color.ink2)
                }
            }
            .foregroundStyle(Color.ink)
            if open == r.id {
                Text("食材").font(.caption.weight(.semibold)).foregroundStyle(Color.ink2)
                FlowLayout { ForEach(r.ingredients, id: \.self) { Pill(text: $0) } }
                if !r.missing.isEmpty {
                    Text("还要买").font(.caption.weight(.semibold)).foregroundStyle(Color.ink2)
                    FlowLayout { ForEach(r.missing, id: \.self) { Pill(text: $0, style: .yellow) } }
                    ShoppingButton(items: r.missing, label: "去买缺的食材")
                }
                Text("做法").font(.caption.weight(.semibold)).foregroundStyle(Color.ink2)
                ForEach(Array(r.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20).background(Color.brand).clipShape(Circle())
                        Text(step).font(.subheadline)
                    }
                }
            }
        }
    }
}
