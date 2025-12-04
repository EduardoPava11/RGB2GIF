//
//  AppDelegate.swift
//  RGB2GIF
//
//  Application entry point
//

import UIKit
import os.log

private let appLogger = Logger(subsystem: "com.rgb2gif", category: "AppDelegate")

// MARK: - AppDelegate

@available(iOS 26.0, *)
@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        appLogger.info("RGB2GIF application started")
        appLogger.info("Architecture: 729-cell tensor palette selection")
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        appLogger.debug("Discarded \(sceneSessions.count) scene sessions")
    }
}
