import SwiftUI
import UserNotifications

/// 通知点开后要做的事，由 ContentView 处理（那里拿得到 Store、管家和 Tab）
@MainActor final class NotifRouter: ObservableObject {
    static let shared = NotifRouter()
    struct Pending: Equatable { var action: String; var info: [String: String] }
    @Published var pending: Pending?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Reminders.registerCategories()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let k = k as? String, let v = v as? String { info[k] = v }
        }
        let action = response.actionIdentifier
        await MainActor.run { NotifRouter.shared.pending = .init(action: action, info: info) }
    }
}

@main
struct ShiTieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var butler = Butler()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(butler)
                .task {
                    _ = await Reminders.requestAuth()
                    store.refreshReminders()
                    store.writeWidget()
                }
        }
        .onChange(of: phase) { _, p in
            if p == .background { store.saveNow(); butler.save() }
            if p == .active { store.refreshReminders() }
        }
    }
}

extension ContentView {
    /// 通知：「是的，记一下」直接复制那一餐；「告诉管家」/ 周报 / 手账提醒 → 打开管家并替你问
    func handle(_ p: NotifRouter.Pending) {
        if p.action == NotifKey.logAction, let id = p.info["meal"], let src = store.meal(id), let slot = MealSlot(rawValue: p.info["slot"] ?? "") {
            if let who = p.info["member"] { store.switchTo(who) }
            store.duplicate(src, date: D.today, slot: slot)
            date = D.today
            tab = .today
            store.flash("已记下「\(src.title)」✓")
            return
        }
        if p.action == NotifKey.otherAction {
            if let who = p.info["member"] { store.switchTo(who) }
            tab = .butler
            butler.draft = "\(MealSlot(rawValue: p.info["slot"] ?? "")?.name ?? "这顿")吃的不是\(p.info["title"] ?? "")，我吃了"
            return
        }
        if let ask = p.info["ask"] {
            tab = .butler
            butler.send(ask, image: nil, store: store)
        }
    }
}

enum Tab: Hashable { case today, calendar, butler, nutrition, me }

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var butler: Butler
    @ObservedObject private var router = NotifRouter.shared
    @State private var tab: Tab = .today
    @State private var date = D.today

    var body: some View {
        TabView(selection: $tab) {
            TodayView(date: $date, tab: $tab)
                .tabItem { Label("今日", systemImage: "book.closed") }.tag(Tab.today)
            CalendarView(date: $date, onPick: { tab = .today })
                .tabItem { Label("日历", systemImage: "calendar") }.tag(Tab.calendar)
            ButlerView()
                .tabItem { Label("管家", systemImage: "sparkles") }.tag(Tab.butler)
            NutritionView()
                .tabItem { Label("分析", systemImage: "chart.bar.xaxis") }.tag(Tab.nutrition)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person") }.tag(Tab.me)
        }
        .tint(Color.brand)
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.ink.opacity(0.9))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.toast)
        .onReceive(router.$pending) { p in
            guard let p else { return }
            router.pending = nil
            handle(p)
        }
        .onOpenURL { url in
            // 桌面小组件点进来：shitie://add
            if url.host == "add" {
                tab = .today
                date = D.today
                store.openAdd = true
            }
        }
    }
}
