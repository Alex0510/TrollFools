//
//  AppListModel.swift
//  TrollFools
//
//  Created by 82Flex on 2024/10/30.
//

import Combine
import OrderedCollections
import SwiftUI
import CocoaLumberjackSwift

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
                NSLocalizedString("Injectable System Applications", comment: "")
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
    @Published var unsupportedApps: [App] = []

    // 公开所有支持注入的应用（用于批量操作）
    var allSupportedApps: [App] { _allApplications }

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

    // 记录每个应用上次自动注入时的版本，避免重复注入
    private let autoInjectKeyPrefix = "AutoInjectVersion_"
    // 串行队列，避免并发执行 InjectorV3 操作导致内存问题
    private let autoInjectQueue = DispatchQueue(label: "wiki.qaq.TrollFools.autoInject", qos: .background)

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
        CFNotificationCenterAddObserver(darwinCenter, Unmanaged.passRetained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer = Unmanaged<AppListModel>.fromOpaque(observer!).takeUnretainedValue() as AppListModel? else {
                return
            }
            observer.applicationChanged.send()
        }, "com.apple.LaunchServices.ApplicationsChanged" as CFString, nil, .coalesce)
    }

    deinit {
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(darwinCenter, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }

    func reload() {
        let allApplications = Self.fetchApplications(&unsupportedCount, &unsupportedApps)
        allApplications.forEach { $0.appList = self }
        _allApplications = allApplications
        performFilter()
        // 应用列表刷新后，检查需要自动重新注入的应用
        autoReinjectAfterUpdate()
    }

    func performFilter() {
        var filteredApplications = _allApplications

        if !filter.searchKeyword.isEmpty {
            filteredApplications = filteredApplications.filter {
                $0.name.localizedCaseInsensitiveContains(filter.searchKeyword) || $0.bid.localizedCaseInsensitiveContains(filter.searchKeyword) ||
                    (
                        $0.latinName.localizedCaseInsensitiveContains(
                            filter.searchKeyword
                                .components(separatedBy: .whitespaces).joined()
                        )
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
            activeScopeApps = Self.groupedAppList(filteredApplications.filter { $0.isUser })
        case .troll:
            activeScopeApps = Self.groupedAppList(filteredApplications.filter { $0.isFromTroll })
        case .system:
            activeScopeApps = Self.groupedAppList(filteredApplications.filter { $0.isFromApple })
        }
    }

    // MARK: - 自动重新注入（应用更新后）- 使用串行队列避免并发问题
    private func autoReinjectAfterUpdate() {
        // 收集需要自动注入的应用信息
        var appsToInject: [(app: App, currentVersion: String)] = []
        for app in _allApplications {
            guard app.hasPersistedAssets && !app.isInjected,
                  let currentVersion = app.version else {
                continue
            }
            let key = autoInjectKeyPrefix + app.bid
            let lastAutoInjectedVersion = UserDefaults.standard.string(forKey: key)
            if lastAutoInjectedVersion != currentVersion {
                appsToInject.append((app, currentVersion))
            }
        }
        guard !appsToInject.isEmpty else { return }

        // 在串行队列中逐个执行注入，避免并发内存问题
        autoInjectQueue.async { [weak self] in
            for (app, currentVersion) in appsToInject {
                guard let self = self else { break }
                do {
                    let injector = try InjectorV3(app.url)
                    if injector.appID.isEmpty {
                        injector.appID = app.bid
                    }
                    if injector.teamID.isEmpty {
                        injector.teamID = app.teamID
                    }
                    // 读取用户配置（注意：UserDefaults 是线程安全的）
                    let useWeakReference = UserDefaults.standard.bool(forKey: "UseWeakReference-\(app.bid)")
                    let preferMainExecutable = UserDefaults.standard.bool(forKey: "PreferMainExecutable-\(app.bid)")
                    let useFrameworkEnumerationFallback = UserDefaults.standard.bool(forKey: "UseFrameworkEnumerationFallback-\(app.bid)")
                    let strategyRaw = UserDefaults.standard.string(forKey: "InjectStrategy-\(app.bid)") ?? InjectorV3.Strategy.lexicographic.rawValue
                    injector.useWeakReference = useWeakReference
                    injector.preferMainExecutable = preferMainExecutable
                    injector.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
                    injector.injectStrategy = InjectorV3.Strategy(rawValue: strategyRaw) ?? .lexicographic

                    let persistedURLs = InjectorV3.main.persistedAssetURLs(bid: app.bid)
                    if !persistedURLs.isEmpty {
                        try injector.inject(persistedURLs, shouldPersist: false)
                        DispatchQueue.main.async {
                            app.reload()
                        }
                        // 记录已自动注入的版本
                        UserDefaults.standard.set(currentVersion, forKey: self.autoInjectKeyPrefix + app.bid)
                    }
                } catch {
                    DDLogError("Auto reinject failed for \(app.bid): \(error)")
                }
            }
        }
    }

    private static let excludedIdentifiers: Set<String> = [
        "com.opa334.Dopamine",
        "org.coolstar.SileoStore",
        "xyz.willy.Zebra",
    ]

    private static func fetchApplications(_ unsupportedCount: inout Int, _ unsupportedApps: inout [App]) -> [App] {
        let allApps: [App] = LSApplicationWorkspace.default()
            .allApplications()
            .compactMap { proxy in
                guard let id = proxy.applicationIdentifier(),
                      let url = proxy.bundleURL(),
                      let teamID = proxy.teamID(),
                      let appType = proxy.applicationType(),
                      let localizedName = proxy.localizedName()
                else {
                    return nil
                }

                guard !id.hasPrefix("wiki.qaq.") && !id.hasPrefix("com.82flex.") && !id.hasPrefix("ch.xxtou.") else {
                    return nil
                }

                guard !excludedIdentifiers.contains(id) else {
                    return nil
                }

                let shortVersionString: String? = proxy.shortVersionString()
                let app = App(
                    bid: id,
                    name: localizedName,
                    type: appType,
                    teamID: teamID,
                    url: url,
                    version: shortVersionString
                )

                if app.isUser && app.isFromApple {
                    return nil
                }

                guard app.isRemovable else {
                    return nil
                }

                return app
            }

        let filteredApps = allApps
            .filter { $0.isSystem || InjectorV3.main.checkIsEligibleAppBundle($0.url) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        unsupportedCount = allApps.count - filteredApps.count
        let filteredSet = Set(filteredApps.map { $0.bid })
        unsupportedApps = allApps.filter { !filteredSet.contains($0.bid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return filteredApps
    }
}

extension AppListModel {
    func openInFilza(_ url: URL) {
        guard let filzaURL else {
            return
        }

        let fileURL: URL
        if #available(iOS 16, *) {
            fileURL = filzaURL.appending(path: url.path)
        } else {
            fileURL = URL(string: filzaURL.absoluteString + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))!
        }

        UIApplication.shared.open(fileURL)
    }

    func rebuildIconCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            LSApplicationWorkspace.default().openApplication(withBundleID: "com.opa334.TrollStore")
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
               let idx2 = allowedCharacters.firstIndex(of: c2)
            {
                return idx1 < idx2
            }
            return app1.key < app2.key
        }

        return groupedApps
    }
}