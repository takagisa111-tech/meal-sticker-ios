import WidgetKit
import SwiftUI
import UIKit

struct MealEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
    let images: [UIImage]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> MealEntry { MealEntry(date: Date(), snap: nil, images: []) }

    func getSnapshot(in context: Context, completion: @escaping (MealEntry) -> Void) {
        completion(load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealEntry>) -> Void) {
        let now = Date()
        let first = load(at: now)
        var entries = [first]
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        var times = (first.snap?.slots ?? []).compactMap { cal.date(byAdding: .minute, value: $0.minutes, to: start) }.filter { $0 > now }
        if let midnight = cal.date(byAdding: .day, value: 1, to: start) { times.append(midnight.addingTimeInterval(5)) }
        for t in times.sorted() { entries.append(MealEntry(date: t, snap: first.snap, images: first.images)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }

    private func load(at date: Date) -> MealEntry {
        let snap = SharedBox.read()
        var imgs: [UIImage] = []
        if let s = snap, let dir = SharedBox.dir {
            for n in s.stickers.prefix(4) {
                if let i = UIImage(contentsOfFile: dir.appendingPathComponent(n).path) { imgs.append(i) }
            }
        }
        return MealEntry(date: date, snap: snap, images: imgs)
    }
}

private let wPaper = Color(red: 1.0, green: 0.992, blue: 0.976)
private let wInk = Color(red: 0.227, green: 0.196, blue: 0.172)
private let wInk2 = Color(red: 0.42, green: 0.373, blue: 0.333)
private let rots: [Double] = [-8, 7, -4, 9]
private let offX: [CGFloat] = [-16, 16, -10, 18]
private let offY: [CGFloat] = [-10, -4, 14, 16]
private let wTomato = Color(red: 0.933, green: 0.416, blue: 0.302)

private func dayString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

struct MealWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MealEntry

    /// 快照是不是今天的（过了零点就当作今天还没记录）
    private var isToday: Bool { entry.snap?.date == dayString(entry.date) }
    private var images: [UIImage] { isToday ? entry.images : [] }
    private var kcal: Int { isToday ? (entry.snap?.kcal ?? 0) : 0 }

    private var nextText: String {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: entry.date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let slots = entry.snap?.slots ?? []
        if let s = slots.first(where: { !(isToday && $0.recorded) && $0.minutes > now }) {
            return "\(s.emoji) \(s.name) \(String(format: "%02d:%02d", s.minutes / 60, s.minutes % 60))"
        }
        if let s = slots.first(where: { !(isToday && $0.recorded) && now >= $0.minutes }) {
            return "\(s.emoji) \(s.name)还没记"
        }
        return "今天三餐都记啦 ✨"
    }

    private var dateText: String {
        let c = Calendar.current.dateComponents([.month, .day], from: entry.date)
        return String(format: "%02d.%02d", c.month ?? 1, c.day ?? 1)
    }

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .containerBackground(for: .widget) {
            ZStack {
                wPaper
                Canvas { ctx, size in
                    var y: CGFloat = 8
                    while y < size.height {
                        var x: CGFloat = 8
                        while x < size.width {
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Color(red: 0.9, green: 0.86, blue: 0.8)))
                            x += 16
                        }
                        y += 16
                    }
                }
            }
        }
        .widgetURL(URL(string: "shitie://add"))
    }

    private var stickers: some View {
        ZStack {
            if images.isEmpty {
                VStack(spacing: 2) {
                    Image(systemName: "camera.fill").font(.system(size: 20)).foregroundStyle(wTomato)
                    Text("贴一餐").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(wInk2)
                }
            } else {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(rots[i % 4]))
                        .offset(x: offX[i % 4], y: offY[i % 4])
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                }
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(dateText).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(wInk)
                Spacer()
                Text("\(kcal) kcal").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(wInk2)
            }
            stickers.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(nextText).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(wTomato).lineLimit(1)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dateText).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(wInk)
                Text("\(kcal) / \(entry.snap?.target ?? 1900) kcal").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(wInk2)
                Text("💧 \(isToday ? (entry.snap?.water ?? 0) : 0)/\(entry.snap?.waterGoal ?? 8) 杯").font(.system(size: 12, design: .rounded)).foregroundStyle(wInk2)
                Spacer(minLength: 0)
                Text(nextText).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(wTomato).lineLimit(1)
                if let tip = entry.snap?.tip, !tip.isEmpty {
                    Text(tip).font(.system(size: 10.5, design: .rounded)).foregroundStyle(wInk2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stickers.frame(width: 120)
        }
    }
}

@main
struct ShiTieWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShiTieWidget", provider: Provider()) { entry in
            MealWidgetView(entry: entry)
        }
        .configurationDisplayName("食贴")
        .description("今天贴了什么、下一餐什么时候")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
