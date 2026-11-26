import Foundation
import UIKit
import MapKit
import CoreLocation
import EventKit

// MARK: - 定位

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var denied = false
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> CLLocation? {
        if let l = location, Date().timeIntervalSince(l.timestamp) < 300 { return l }
        let st = manager.authorizationStatus
        if st == .denied || st == .restricted { denied = true; return nil }
        return await withCheckedContinuation { c in
            waiters.append(c)
            if st == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let st = m.authorizationStatus
        Task { @MainActor in
            if st == .authorizedWhenInUse || st == .authorizedAlways {
                if !self.waiters.isEmpty { self.manager.requestLocation() }
            } else if st == .denied || st == .restricted {
                self.denied = true
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        let l = locs.last
        Task { @MainActor in
            self.location = l
            self.finish(l)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func finish(_ l: CLLocation?) {
        let w = waiters
        waiters = []
        w.forEach { $0.resume(returning: l) }
    }
}

// MARK: - 附近餐厅（苹果地图，国内数据来自高德）

struct Place: Identifiable {
    let id = UUID()
    let item: MKMapItem
    let distance: Double?

    var name: String { item.name ?? "未命名" }
    var address: String { item.placemark.title ?? "" }
    var phone: String? { item.phoneNumber }
    var distanceText: String {
        guard let d = distance else { return "" }
        return d < 1000 ? "\(Int(d)) m" : String(format: "%.1f km", d / 1000)
    }
}

enum Nearby {
    static func search(_ keyword: String, near loc: CLLocation?) async throws -> [Place] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = keyword
        req.resultTypes = .pointOfInterest
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery, .foodMarket])
        if let loc {
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000)
        }
        let resp = try await MKLocalSearch(request: req).start()
        let places = resp.mapItems.map { item -> Place in
            let d = loc.flatMap { l in item.placemark.location?.distance(from: l) }
            return Place(item: item, distance: d)
        }
        return places.sorted { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
    }
}

// MARK: - 跳转大众点评

enum Dianping {
    /// 打开大众点评 App 并搜索关键词；没装点评就打开 App Store 页面
    static func search(_ keyword: String) {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        guard let url = URL(string: "dianping://searchshoplist?keyword=\(q)") else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok, let store = URL(string: "https://apps.apple.com/cn/app/id351091731") {
                UIApplication.shared.open(store)
            }
        }
    }
}

// MARK: - 购物清单 → iPhone「提醒事项」

enum ShoppingSync {
    static let eventStore = EKEventStore()
    static let listName = "食贴购物清单"

    /// 返回成功加入的条数
    static func add(_ items: [String]) async throws -> Int {
        let clean = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return 0 }
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else { throw AIError(message: "没有「提醒事项」权限，去 设置 → 食贴 里打开") }
        let cal = try list()
        for t in clean {
            let r = EKReminder(eventStore: eventStore)
            r.title = t
            r.calendar = cal
            try eventStore.save(r, commit: false)
        }
        try eventStore.commit()
        return clean.count
    }

    private static func list() throws -> EKCalendar {
        if let c = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) { return c }
        let fallback = eventStore.defaultCalendarForNewReminders()
        let c = EKCalendar(for: .reminder, eventStore: eventStore)
        c.title = listName
        if let src = fallback?.source ?? eventStore.sources.first(where: { $0.sourceType == .local }) {
            c.source = src
            do {
                try eventStore.saveCalendar(c, commit: true)
                return c
            } catch {
                if let f = fallback { return f }
                throw error
            }
        }
        if let f = fallback { return f }
        throw AIError(message: "找不到可用的提醒事项列表")
    }
}
