import SwiftUI
import UIKit

/// 导出内容的开关（记住上次的选择）
struct ExportOptions: Equatable {
    var kcal = true
    var macros = true
    var water = true
    var meals = true
    var mood = true
    var note = true
}

/// 导出预览：上面是成图预览，下面选择要带上的内容
struct ExportView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let date: String

    @AppStorage("ex_kcal") private var kcal = true
    @AppStorage("ex_macros") private var macros = true
    @AppStorage("ex_water") private var water = true
    @AppStorage("ex_meals") private var meals = true
    @AppStorage("ex_mood") private var mood = true
    @AppStorage("ex_note") private var note = true

    @State private var image: UIImage?
    @State private var share = false

    private var opts: ExportOptions {
        ExportOptions(kcal: kcal, macros: macros, water: water, meals: meals, mood: mood, note: note)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)

                    SectionHeader(title: "显示内容")
                    FlowLayout(spacing: 8) {
                        chip("能量", $kcal)
                        chip("三大营养素", $macros)
                        if !store.kind.isPet { chip("饮水", $water) }
                        chip("餐食清单", $meals)
                        chip(store.kind.isPet ? "状态" : "心情", $mood)
                        chip(store.kind.isPet ? "备注" : "小记", $note)
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
                    Text("手账页始终保留；没有数据的项目会自动隐藏。").font(.system(size: 11)).foregroundStyle(Color.ink3)
                        .padding(.top, 10).padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                Button { share = true } label: { Label("分享图片", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButton())
                    .disabled(image == nil)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
                    .background(Color.paper.opacity(0.96))
            }
            .background(PageBackground())
            .navigationTitle("导出手账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(Color.brand)
        .onAppear(perform: render)
        .onChange(of: opts) { _, _ in render() }
        .sheet(isPresented: $share) {
            if let image { ShareSheet(items: [image]) }
        }
    }

    private func chip(_ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: on.wrappedValue ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(on.wrappedValue ? Color.white : Color.ink)
            .padding(.horizontal, 12).frame(height: 32)
            .background(on.wrappedValue ? Color.ink : Color.card)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(on.wrappedValue ? Color.clear : Color.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @MainActor private func render() {
        let view = ExportCard(date: date, opts: opts).environmentObject(store)
        let r = ImageRenderer(content: view)
        r.scale = 3
        image = r.uiImage
    }
}

/// 导出的手账长图
struct ExportCard: View {
    @EnvironmentObject var store: Store
    let date: String
    let opts: ExportOptions

    private static let cnMonths = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]

    var body: some View {
        let member = store.member
        let isPet = member.kind.isPet
        let day = store.day(date)
        let ms = store.meals(on: date).sorted { $0.time < $1.time }
        let a = Nutrition.aggregate(ms)
        let moodItem = TodayView.moods(pet: isPet).first { $0.0 == day.mood }
        let showStats = (opts.kcal && a.kcal > 0) || (opts.water && !isPet) || (opts.meals && !ms.isEmpty)

        VStack(alignment: .leading, spacing: 0) {
            // 抬头
            HStack(alignment: .center, spacing: 12) {
                Text(String(format: "%02d.%02d", D.month(date), D.day(date)))
                    .font(.system(size: 38, weight: .regular, design: .serif))
                    .foregroundStyle(Color.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("星期\(D.weekday(date))").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                    Text("\(String(D.year(date))) · \(Self.cnMonths[D.month(date) - 1])").font(.system(size: 10.5)).foregroundStyle(Color.ink2)
                }
                Spacer()
                if opts.mood, let m = moodItem { stamp(m) }
            }
            .padding(.bottom, 12)
            VStack(spacing: 2) {
                Rectangle().fill(Color.ink.opacity(0.85)).frame(height: 1)
                Rectangle().fill(Color.ink.opacity(0.35)).frame(height: 0.5)
            }

            // 手账页（相片框 + 胶带）
            PaperView(date: date, selected: .constant(nil), interactive: false)
                .frame(width: 300, height: 375)
                .padding(8)
                .padding(.bottom, 10)
                .background(Color.white)
                .shadow(color: Color(red: 0.25, green: 0.18, blue: 0.08).opacity(0.18), radius: 10, y: 6)
                .overlay(alignment: .top) {
                    Tape(color: Color(red: 0.86, green: 0.82, blue: 0.70).opacity(0.8))
                        .rotationEffect(.degrees(-4)).offset(y: -9)
                }
                .rotationEffect(.degrees(-1.2))
                .frame(maxWidth: .infinity)
                .padding(.top, 26).padding(.bottom, 22)

            // 数据
            if showStats {
                HStack(spacing: 0) {
                    if opts.kcal && a.kcal > 0 { stat("\(Int(a.kcal))", "千卡", "能量") }
                    if opts.water && !isPet { stat("\(day.water)", "/ \(store.settings.waterGoal) 杯", "饮水") }
                    if opts.meals && !ms.isEmpty { stat("\(ms.count)", "餐", "记录") }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 0.5) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 0.5) }
            }

            if opts.macros && a.kcal > 0 {
                let t = Double(store.kcalTarget)
                HStack(spacing: 14) {
                    macro("蛋白质", a.protein, t * (isPet ? 0.25 : 0.15) / 4, .berry)
                    macro("碳水", a.carbs, t * (isPet ? 0.45 : 0.55) / 4, .butter)
                    macro("脂肪", a.fat, t * (isPet ? 0.30 : 0.25) / 9, .sky)
                }
                .padding(.top, 14)
            }

            if opts.meals && !ms.isEmpty {
                label(isPet ? "今日进食" : "今日餐食").padding(.top, 20)
                VStack(spacing: 8) {
                    ForEach(ms) { m in mealRow(m, kind: member.kind) }
                }
                .padding(.top, 8)
            }

            if opts.note && !day.note.isEmpty {
                label(isPet ? "备注" : "小记").padding(.top, 20)
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(Color.brand.opacity(0.45)).frame(width: 2)
                    Text(day.note)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }

            // 落款
            HStack {
                Text("食  贴").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Color.ink2)
                Spacer()
                Text("\(member.displayName)的手账").font(.system(size: 10)).foregroundStyle(Color.ink3)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 0.5) }
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 380)
        .background { ZStack { Color.paper; Grain(opacity: 0.9) } }
    }

    private func stamp(_ m: (String, String)) -> some View {
        VStack(spacing: 0) {
            Text(m.0).font(.system(size: 20))
            Text(m.1).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.tomato)
        }
        .frame(width: 52, height: 52)
        .overlay(Circle().strokeBorder(Color.tomato.opacity(0.7), lineWidth: 1.2))
        .overlay(Circle().strokeBorder(Color.tomato.opacity(0.35), lineWidth: 0.6).padding(3))
        .rotationEffect(.degrees(-10))
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundStyle(Color.ink2)
    }

    private func stat(_ v: String, _ unit: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 22, weight: .regular, design: .serif)).foregroundStyle(Color.ink)
                Text(unit).font(.system(size: 10)).foregroundStyle(Color.ink2)
            }
            Text(name).font(.system(size: 10)).foregroundStyle(Color.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macro(_ name: String, _ v: Double, _ target: Double, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 10.5)).foregroundStyle(Color.ink2)
                Spacer()
                Text("\(Int(v))g").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ink.opacity(0.07))
                    Capsule().fill(c).frame(width: g.size.width * min(1, v / max(1, target)))
                }
            }
            .frame(height: 4)
        }
    }

    private func mealRow(_ m: Meal, kind: MemberKind) -> some View {
        HStack(spacing: 10) {
            Group {
                if let img = store.image(m.sticker) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: 16))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.title.isEmpty ? kind.slotName(m.slot) : m.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text("\(m.time) · \(kind.slotName(m.slot))").font(.system(size: 10)).foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 8)
            if opts.kcal && m.kcal > 0 {
                Text("\(Int(m.kcal)) 千卡").font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
        }
    }
}
