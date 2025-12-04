//
//  SceneDelegate.swift
//  RGB2GIF
//
//  App scene entry point - launches CaptureViewController
//

import UIKit
import os.log

private let appLogger = Logger(subsystem: "com.rgb2gif", category: "App")

// MARK: - SceneDelegate

@available(iOS 26.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        appLogger.info("RGB2GIF launching...")

        guard let windowScene = scene as? UIWindowScene else {
            appLogger.error("Failed to get window scene")
            return
        }

        let window = UIWindow(windowScene: windowScene)
        let captureVC = CaptureViewController()

        window.rootViewController = captureVC
        window.makeKeyAndVisible()

        self.window = window

        appLogger.info("RGB2GIF ready - 81x81x81 capture")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        appLogger.info("Scene disconnected")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        appLogger.debug("Scene active")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        appLogger.debug("Scene resigning")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        appLogger.debug("Scene entering foreground")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appLogger.debug("Scene entered background")
    }
}
