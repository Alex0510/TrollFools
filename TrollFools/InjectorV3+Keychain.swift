//
//  InjectorV3+Keychain.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import Foundation
import SQLite3
import CocoaLumberjackSwift

extension InjectorV3 {
    /// 清除指定 Bundle ID 应用的 Keychain 数据
    /// - Parameter bundleID: 应用的 Bundle Identifier
    func clearKeychainData(for bundleID: String) throws {
        let dbPath = "/keychains/keychain-2.db"
        var db: OpaquePointer?
        
        // 尝试杀掉 keychaind 进程以减少数据库锁定
        killKeychainDaemon()
        
        // 打开数据库（读写模式）
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw Error.generic("无法打开 Keychain 数据库: \(errMsg)")
        }
        defer { sqlite3_close(db) }
        
        // 需要清理的表（存储不同类型钥匙串数据）
        let tables = ["genp", "cert", "keys", "inet"]
        var hasError = false
        var lastError: String?
        
        for table in tables {
            // 删除 agrp 字段中包含 bundleID 的记录（TeamID.BundleID 或 TeamID.* 格式）
            let sql = "DELETE FROM \(table) WHERE agrp LIKE '%\(bundleID)%';"
            var errMsg: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
                let error = String(cString: errMsg!)
                sqlite3_free(errMsg)
                hasError = true
                lastError = error
                break
            }
        }
        
        if hasError {
            throw Error.generic("SQLite 错误: \(lastError ?? "未知错误")")
        }
        
        // 可选：同步修改到磁盘
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }
    
    // MARK: - Private Helpers
    
    private func killKeychainDaemon() {
        // 使用 Execute.rootSpawn 执行 killall 命令（iOS 兼容）
        do {
            _ = try Execute.rootSpawn(binary: "/usr/bin/killall", arguments: ["-9", "keychaind"], ddlog: logger)
            // 等待进程完全终止，避免数据库被锁定
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            DDLogWarn("Failed to kill keychaind: \(error)", ddlog: logger)
        }
    }
}
