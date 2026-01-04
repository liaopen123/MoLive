//
//  MotionJPEGConvertApp.swift
//  MotionJPEGConvert
//
//  Created by 李龙宇 on 2024/12/3.
//

import SwiftUI

@main
struct MotionJPEGConvertApp: App {
    @StateObject private var permissionManager = PermissionManager()
    
    init() {
        // 初始化 CoreData 栈
        _ = ConversionRecordManager.shared.persistentContainer
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(permissionManager)
        }
    }
}
