//
//  AppListModel.swift
//  TrollFools
//

import Combine
import OrderedCollections
import SwiftUI

final class AppListModel: ObservableObject {
    enum Scope: Int, CaseIterable {
        case all
        case user
        case troll
        case system

        var localizedShortName: String {
            switch self {
            case .all:
                NSLocalizedString("All", comment: "")
            case .user:
                NSLocalizedString("User", comment: "")
            case .troll:
                NSLocalizedString("TrollStore", comment: "")
            case .system:
                NSLocalizedString("System", comment: "")
            }
        }

        var localizedName: String {
            switch self {
            case .all:
                NSLocalizedString("All Applications", comment: "")
            case .user:
                NSLocalizedString("User Applications", comment: "")
            case .troll:
                NSLocalizedString("TrollStore Applications", comment: "")
            case .system:
                NSLocalizedString("System Applications", comment: "")
            }
        }
    }

    static let isLegacyDevice: Bool = { UIScreen.main.fixedCoordinateSpace.bounds.height <= 736.0 }()
    static let hasTrollStore: Bool = { LSApplicationProxy(forIdentifier: "com.opa334.TrollStore") != nil }()
    private var _allApplications: [App] = []

    let selectorURL: URL?
    var isSelectorMode: Bool { selectorURL != nil }

    @Published var filter = FilterOptions()
    @Published var activeScope: Scope = .all
    @Published var activeScopeApps: OrderedDictionary<String, [App]> = [:]

    @Published var unsupportedCount: Int = 0

    lazy var isFilzaInstalled: Bool = {
        if let filzaURL {
            UIApplication.shared.canOpenURL(filzaURL)
        } else {
            false
        }
    }()
    private let filzaURL = URL(string: "filza://view")

    @Published var isRebuildNeeded: Bool = false

    private let applicationChanged = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()

    init(selectorURL: URL? = nil) {
        self.selectorURL = selectorURL
        reload()

        Publishers.CombineLatest(
            $filter,
            $activeScope
        )
        .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in
            self?.performFilter()
        }
        .store(in: &cancellables)

        applicationChanged
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            darwinCenter,
            Unmanaged.passRetained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let obj = Unmanaged<AppListModel>.fromOpaque(observer).takeUnretainedValue()
                obj.applicationChanged.send()
            },
            "com.apple.LaunchServices.ApplicationsChanged" as CFString,
            nil,
            .coalesce
        )
    }

    deinit {
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(darwinCenter, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }

    func reload() {
        let allApplications = Self.fetchApplications(&unsupportedCount)
        allApplications.forEach { $0.appList = self }
        _allApplications = allApplications
        performFilter()
    }

    func performFilter() {
        var filteredApplications = _allApplications

        if !filter.searchKeyword.isEmpty {
            filteredApplications = filteredApplications.filter {
                $0.name.localizedCaseInsensitiveContains(filter.searchKeyword) ||
                $0.bid.localizedCaseInsensitiveContains(filter.searchKeyword) ||
                $0.normalizedPath.localizedCaseInsensitiveContains(filter.searchKeyword) ||
                $0.latinName.localizedCaseInsensitiveContains(
                    filter.searchKeyword.components(separatedBy: .whitespaces).joined()
                )
            }
        }

        if filter.showPatchedOnly {
            filteredApplications = filteredApplications.filter { $0.isInjected || $0.hasPersistedAssets }
        }

        switch activeScope {
        case .all:
            activeScopeApps = Self.groupedAppList(filteredApplications)

        case .user:
            activeScopeApps = Self.groupedAppList(
                filteredApplications.filter { $0.isUserAppPath }
            )

        case .troll:
            activeScopeApps = Self.groupedAppList(
                filteredApplications.filter { $0.isFromTroll }
            )

        case .system:
            activeScopeApps = Self.groupedAppList(
                filteredApplications.filter { $0.isSystemAppPath }
            )
        }
    }

    private static let excludedIdentifiers: Set<String> = [
        "com.opa334.Dopamine",
        "org.coolstar.SileoStore",
        "xyz.willy.Zebra"
    ]

    private static func normalizeAppPath(_ path: String) -> String {
        App.normalizeAppPath(path)
    }

    private static func isKnownApplicationBundlePath(_ url: URL) -> Bool {
        let path = normalizeAppPath(url.path)
        guard path.hasSuffix(".app") else { return false }

        if path.hasPrefix("/var/containers/Bundle/Application/") {
            return true
        }

        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") {
            return true
        }

        return false
    }

    private static func isSystemServiceLikeApp(id: String, name: String, path: String) -> Bool {
        let lowerID = id.lowercased()
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        let keywords = [
            "viewservice",
            "uiservice",
            "serviceui",
            "authenticationdialog",
            "dialog",
            "indicator",
            "runner",
            "plugin",
            "xpc",
            "daemon"
        ]

        if keywords.contains(where: { lowerID.contains($0) || lowerName.contains($0) || lowerPath.contains($0) }) {
            return true
        }

        return false
    }

    private static func shouldDisplayApp(id: String, name: String, type: String, url: URL) -> Bool {
        let path = normalizeAppPath(url.path)

        guard isKnownApplicationBundlePath(url) else {
            return false
        }

        // 强制保留 TestFlight
        if id == "com.apple.TestFlight" {
            return true
        }

        // 用户应用全部保留，包含 TestFlight 的 /private/var -> /var 归一化路径
        if path.hasPrefix("/var/containers/Bundle/Application/") {
            return true
        }

        // 系统应用只显示桌面常见 App，过滤系统服务
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") {
            if isSystemServiceLikeApp(id: id, name: name, path: path) {
                return false
            }
            return true
        }

        return false
    }

    private static func fetchApplications(_ unsupportedCount: inout Int) -> [App] {
        guard let workspace = LSApplicationWorkspace.default() else {
            unsupportedCount = 0
            return []
        }

        let mergedProxies = workspace.allApplications() + workspace.allInstalledApplications()

        var proxyMap: [String: LSApplicationProxy] = [:]
        for proxy in mergedProxies {
            guard let bid = proxy.applicationIdentifier(), !bid.isEmpty else { continue }
            if proxyMap[bid] == nil {
                proxyMap[bid] = proxy
            }
        }

        let allApps: [App] = proxyMap.values.compactMap { proxy in
            guard let id = proxy.applicationIdentifier(),
                  let url = proxy.bundleURL(),
                  let teamIDRaw = proxy.teamID(),
                  let appType = proxy.applicationType(),
                  let localizedName = proxy.localizedName()
            else {
                return nil
            }

            guard !id.hasPrefix("wiki.qaq."),
                  !id.hasPrefix("com.82flex."),
                  !id.hasPrefix("ch.xxtou.")
            else {
                return nil
            }

            guard !excludedIdentifiers.contains(id) else {
                return nil
            }

            guard shouldDisplayApp(id: id, name: localizedName, type: appType, url: url) else {
                return nil
            }

            let normalizedPath = normalizeAppPath(url.path)
            let normalizedURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)

            let teamID = teamIDRaw.isEmpty ? "SYSTEM" : teamIDRaw
            let shortVersionString: String? = proxy.shortVersionString()

            let app = App(
                bid: id,
                name: localizedName,
                type: appType,
                teamID: teamID,
                url: normalizedURL,
                version: shortVersionString
            )

            if app.isUser && app.isFromApple && app.bid != "com.apple.TestFlight" {
                return nil
            }

            return app
        }

        let filteredApps = allApps
            .filter { app in
                // 强制保留 TestFlight
                if app.bid == "com.apple.TestFlight" {
                    return true
                }

                // 系统桌面 App 直接保留
                if app.isSystemAppPath {
                    return true
                }

                // 用户 App 保留；避免列表阶段把 TestFlight / 某些桌面 App 误杀
                if app.isUserAppPath {
                    return true
                }

                return InjectorV3.main.checkIsEligibleAppBundle(app.displayURL)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        unsupportedCount = max(0, allApps.count - filteredApps.count)
        return filteredApps
    }
}

extension AppListModel {
    func openInFilza(_ url: URL) {
        guard let filzaURL else {
            return
        }

        let normalizedPath = App.normalizeAppPath(url.path)

        let fileURL: URL
        if #available(iOS 16, *) {
            fileURL = filzaURL.appending(path: normalizedPath)
        } else {
            fileURL = URL(
                string: filzaURL.absoluteString +
                (normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
            )!
        }

        UIApplication.shared.open(fileURL)
    }

    func rebuildIconCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            LSApplicationWorkspace.default()?.openApplication(withBundleID: "com.opa334.TrollStore")
        }
    }
}

extension AppListModel {
    static let allowedCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#"
    private static let allowedCharacterSet = CharacterSet(charactersIn: allowedCharacters)

    private static func groupedAppList(_ apps: [App]) -> OrderedDictionary<String, [App]> {
        var groupedApps = OrderedDictionary<String, [App]>()

        for app in apps {
            var key = app.name
                .trimmingCharacters(in: .controlCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .applyingTransform(.stripCombiningMarks, reverse: false)?
                .applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?
                .prefix(1).uppercased() ?? "#"

            if let scalar = UnicodeScalar(key) {
                if !allowedCharacterSet.contains(scalar) {
                    key = "#"
                }
            } else {
                key = "#"
            }

            if groupedApps[key] == nil {
                groupedApps[key] = []
            }

            groupedApps[key]?.append(app)
        }

        groupedApps.sort { app1, app2 in
            if let c1 = app1.key.first,
               let c2 = app2.key.first,
               let idx1 = allowedCharacters.firstIndex(of: c1),
               let idx2 = allowedCharacters.firstIndex(of: c2) {
                return idx1 < idx2
            }
            return app1.key < app2.key
        }

        return groupedApps
    }
}