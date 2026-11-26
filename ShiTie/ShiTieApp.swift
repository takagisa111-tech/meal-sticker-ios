import SwiftUI

@main
struct ShiTieApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    _ = await Reminders.requestAuth()
                    store.refreshReminders()
                    store.writeWidget()
                }
        }
        .onChange(of: phase) { _, p in
            if p == .background { store.saveNow() }
            if p == .active { store.refreshReminders() }
        }
    }
}

enum Tab: Hashable { case today, calendar, eat, nutrition, me }

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var tab: Tab = .today
    @State private var date = D.today

    var body: some View {
        TabView(selection: $tab) {
            TodayView(date: $date, tab: $tab)
                .tabItem { Label("今日", systemImage: "book.closed") }.tag(Tab.today)
            CalendarView(date: $date, onPick: { tab = .today })
                .tabItem { Label("日历", systemImage: "calendar") }.tag(Tab.calendar)
            EatView()
                .tabItem { Label("推荐", systemImage: "fork.knife") }.tag(Tab.eat)
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
