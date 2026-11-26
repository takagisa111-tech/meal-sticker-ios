import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var store: Store
    @Binding var date: String
    var onPick: () -> Void = {}
    var inSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var monthStart = D.str(D.cal.date(from: D.cal.dateComponents([.year, .month], from: Date())) ?? Date())

    private var cells: [String] {
        let first = D.date(monthStart)
        let wd = D.cal.component(.weekday, from: first)
        let start = D.add(monthStart, -((wd + 5) % 7))
        var out: [String] = []
        for i in 0..<42 {
            let d = D.add(start, i)
            if i >= 35 && D.month(d) != D.month(monthStart) { break }
            out.append(d)
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !inSheet {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("记录总览").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2)
                                Text("日历").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
                            }
                            Spacer()
                            MemberMenu(compact: true)
                        }
                        .padding(.top, 8)
                    }
                    HStack {
                        Text("\(String(D.year(monthStart)))年\(D.month(monthStart))月").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        HStack(spacing: 0) {
                            Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 40, height: 34).contentShape(Rectangle()) }
                            Rectangle().fill(Color.line).frame(width: 0.5, height: 18)
                            Button { shift(1) } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 40, height: 34).contentShape(Rectangle()) }
                        }
                        .background(Color.card).clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                    }
                    .foregroundStyle(Color.ink)

                    stats

                    CardBox(padding: 12) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                                Text(w).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink3)
                            }
                            ForEach(cells, id: \.self) { d in cell(d) }
                        }
                    }
                    Text("选择日期查看当天手账，可补记").font(.system(size: 12)).foregroundStyle(Color.ink3)
                }
                .padding(20)
            }
            .background(PageBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Color.brand)
    }

    private var stats: some View {
        let inMonth = store.meals.filter { D.month($0.date) == D.month(monthStart) && D.year($0.date) == D.year(monthStart) }
        let days = Set(inMonth.map(\.date)).count
        return HStack(spacing: 0) {
            tile("\(days)", "本月记录天数")
            Rectangle().fill(Color.line).frame(width: 0.5, height: 32)
            tile("\(inMonth.count)", "记录餐数")
            Rectangle().fill(Color.line).frame(width: 0.5, height: 32)
            tile("\(store.streak)", "连续记录")
        }
        .padding(.vertical, 12)
        .surface()
    }

    private func tile(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(Color.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
    }

    private func cell(_ d: String) -> some View {
        let ms = store.meals(on: d)
        let sel = d == date
        let out = D.month(d) != D.month(monthStart)
        return Button {
            date = d
            onPick()
            if inSheet { dismiss() }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ms.isEmpty ? Color.fill.opacity(0.6) : Color.card)
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(sel ? Color.ink : (d == D.today ? Color.brand : Color.line), lineWidth: sel || d == D.today ? 1.5 : 0.5)
                if let m = ms.first {
                    Group {
                        if let img = store.image(m.sticker) {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: 20))
                        }
                    }
                    .rotationEffect(.degrees(-6))
                    .padding(EdgeInsets(top: 14, leading: 4, bottom: 4, trailing: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(D.day(d))").font(.system(size: 11, weight: d == D.today ? .bold : .medium)).foregroundStyle(d == D.today ? Color.brand : Color.ink2).padding(4)
                if ms.count > 1 {
                    Text("+\(ms.count - 1)").font(.system(size: 9)).foregroundStyle(Color.ink2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(3)
                }
            }
            .aspectRatio(0.85, contentMode: .fit)
            .opacity(out ? 0.3 : 1)
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        if let d = D.cal.date(byAdding: .month, value: n, to: D.date(monthStart)) { monthStart = D.str(d) }
    }
}
