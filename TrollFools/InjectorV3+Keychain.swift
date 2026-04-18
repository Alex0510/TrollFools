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

    // MARK: - Public API

    /// 清除指定 Bundle ID 应用的所有 Keychain 数据
    /// - Parameter bundleID: 应用的 Bundle Identifier
    func clearKeychainData(for bundleID: String) throws {
        let dbPath = "/var/Keychains/keychain-2.db"
        var db: OpaquePointer?

        // 1. 关键步骤：修改数据库文件权限
        try grantDatabasePermissions(dbPath: dbPath)

        // 2. 打开数据库（读写模式）
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw Error.generic("无法打开 Keychain 数据库: \(errMsg)")
        }
        defer { sqlite3_close(db) }

        // 3. 构建并执行 SQL 删除语句
        let tables = ["genp", "cert", "keys", "inet"]
        for table in tables {
            let sql = "DELETE FROM \(table) WHERE agrp LIKE '%\(bundleID)%';"
            var errMsg: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
                let error = String(cString: errMsg!)
                sqlite3_free(errMsg)
                throw Error.generic("SQLite 错误 (表: \(table)): \(error)")
            }
        }

        DDLogInfo("Keychain 数据清除成功", ddlog: logger)
    }

    // MARK: - Private Helpers

    /// 修改数据库文件权限为可读写
    private func grantDatabasePermissions(dbPath: String) throws {
        // 使用 /usr/bin/chmod 修改数据库文件权限为 0777
        let chmodResult = try Execute.rootSpawn(
            binary: "/usr/bin/chmod",
            arguments: ["777", dbPath],
            ddlog: logger
        )
        guard case .exit(0) = chmodResult else {
            throw Error.generic("修改数据库权限失败，chmod 退出码: \(chmodResult)")
        }
        
        // 可选：同时修改上层目录权限，以防万一
        let keychainsDir = (dbPath as NSString).deletingLastPathComponent
        _ = try Execute.rootSpawn(
            binary: "/usr/bin/chmod",
            arguments: ["755", keychainsDir],
            ddlog: logger
        )
    }
}