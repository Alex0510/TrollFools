//
//  EjectListModel.swift
//  TrollFools
//
//  Created by 82Flex on 2024/10/30.
//

import Combine
import SwiftUI

final class EjectListModel: ObservableObject {
    let app: App
    private(set) var injectedPlugIns: [InjectedPlugIn] = []

    @Published var filter = FilterOptions()
    @Published var filteredPlugIns: [InjectedPlugIn] = []

    @Published var isOkToEnableAll = false
    @Published var isOkToDisableAll = false

    @Published var processingPlugIn: InjectedPlugIn?

    private var cancellables = Set<AnyCancellable>()

    init(_ app: App) {
        self.app = app
        reload()

        $filter
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.performFilter()
            }
            .store(in: &cancellables)
    }

    func reload() {
        var plugIns = [InjectedPlugIn]()
        plugIns += InjectorV3.main.injectedAssetURLsInBundle(app.url)
            .map { InjectedPlugIn(url: $0, isEnabled: true) }

        let enabledNames = plugIns.map { $0.url.lastPathComponent }
        plugIns += InjectorV3.main.persistedAssetURLs(bid: app.bid)
            .filter { !enabledNames.contains($0.lastPathComponent) }
            .map { InjectedPlugIn(url: $0, isEnabled: false) }

        injectedPlugIns = plugIns
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        performFilter()
        
        // 同步保存当前已启用的插件状态到 AutoResumeService
        syncSavedState()
    }

    // 将当前已启用的插件状态保存到 AutoResumeService
    private func syncSavedState() {
        let enabledPlugIns = injectedPlugIns.filter { $0.isEnabled }
        let enabledURLs = enabledPlugIns.map { $0.url }
        AutoResumeService.shared.saveEnabledPlugIns(for: app, enabledURLs: enabledURLs)
    }

    func performFilter() {
        var filteredPlugIns = injectedPlugIns

        if !filter.searchKeyword.isEmpty {
            filteredPlugIns = filteredPlugIns.filter {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter.searchKeyword)
            }
        }

        self.filteredPlugIns = filteredPlugIns
        isOkToEnableAll = filteredPlugIns.contains { !$0.isEnabled }
        isOkToDisableAll = filteredPlugIns.contains { $0.isEnabled }
    }

    func togglePlugIn(_ plugIn: InjectedPlugIn, isEnabled: Bool) {
        guard plugIn.isEnabled != isEnabled else {
            return
        }
        processingPlugIn = plugIn
        
        // 单个插件状态变化时，同步保存完整状态（最终由 syncSavedState 统一处理）
        // 但为了避免重复保存，可以在 toggle 操作完成后再调用 syncSavedState
    }
}