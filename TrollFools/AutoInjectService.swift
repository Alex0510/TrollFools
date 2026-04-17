// AutoInjectService.swift
//
//  AutoInjectService.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import Combine
import Foundation

final class AutoInjectService: ObservableObject {
    static let shared = AutoInjectService()
    
    private var timer: Timer?
    private var isMonitoring = false
    
    private init() {}
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // 每30分钟检查一次
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.checkAndAutoInjectAll()
        }
        
        // 应用启动时立即检查一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkAndAutoInjectAll()
        }
        
        DDLogInfo("AutoInjectService started monitoring")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        DDLogInfo("AutoInjectService stopped monitoring")
    }
    
    func checkAndAutoInjectAll() {
        // 获取所有支持的应用
        let apps = AppListModel.fetchApplications(&{}(), &{}())
        
        DispatchQueue.global(qos: .background).async {
            var injectedCount = 0
            
            for app in apps {
                // 检查是否有需要自动注入的插件
                let persistedURLs = InjectorV3.main.persistedAssetURLs(bid: app.bid)
                let injectedURLs = InjectorV3.main.injectedAssetURLsInBundle(app.url)
                let toInject = persistedURLs.filter { !injectedURLs.contains($0) }
                
                if !toInject.isEmpty {
                    do {
                        let injector = try InjectorV3(app.url)
                        if injector.appID.isEmpty {
                            injector.appID = app.bid
                        }
                        if injector.teamID.isEmpty {
                            injector.teamID = app.teamID
                        }
                        
                        try injector.inject(toInject, shouldPersist: false)
                        injectedCount += toInject.count
                        
                        DDLogInfo("Auto injected \(toInject.count) plugins into \(app.bid)")
                    } catch {
                        DDLogError("Auto inject failed for \(app.bid): \(error)")
                    }
                }
            }
            
            if injectedCount > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("AutoInjectCompleted"),
                        object: nil,
                        userInfo: ["count": injectedCount]
                    )
                }
            }
        }
    }
}