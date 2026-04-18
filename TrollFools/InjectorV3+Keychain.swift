//
//  InjectorV3+Keychain.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import Foundation
import CocoaLumberjackSwift

extension InjectorV3 {
    /// 清除指定 Bundle ID 应用的 Keychain 数据
    func clearKeychainData(for bundleID: String) throws {
        let dbPath = "/var/Keychains/keychain-2.db"
        
        // 1. 杀死 keychaind 减少锁定
        killKeychainDaemon()
        
        // 2. 准备 SQL 语句
        let sql = """
        DELETE FROM genp WHERE agrp LIKE '%\(bundleID)%';
        DELETE FROM cert WHERE agrp LIKE '%\(bundleID)%';
        DELETE FROM keys WHERE agrp LIKE '%\(bundleID)%';
        DELETE FROM inet WHERE agrp LIKE '%\(bundleID)%';
        """
        
        // 3. 将 SQL 写入临时文件
        let sqlFile = temporaryDirectoryURL.appendingPathComponent("clear_\(bundleID).sql")
        try sql.write(to: sqlFile, atomically: true, encoding: .utf8)
        
        // 4. 使用 sqlite3 命令行执行
        let sqlite3Path = "/usr/bin/sqlite3"
        let retCode = try Execute.rootSpawn(binary: sqlite3Path, arguments: [
            dbPath,
            ".read \(sqlFile.path)"
        ], ddlog: logger)
        
        // 检查执行结果
        guard case .exit(0) = retCode else {
            throw Error.generic("sqlite3 执行失败，退出码: \(retCode)")
        }
        
        // 清理临时文件
        try? FileManager.default.removeItem(at: sqlFile)
    }
    
    // MARK: - Private Helpers
    
    private func killKeychainDaemon() {
        do {
            _ = try Execute.rootSpawn(binary: "/usr/bin/killall", arguments: ["-9", "keychaind"], ddlog: logger)
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            DDLogWarn("无法杀死 keychaind: \(error)", ddlog: logger)
        }
    }
}