//
//  SceneDelegate.swift
//  RGB2GIF
//
//  Scene delegate for iOS 26
//

import UIKit
import os.log

private let sceneLogger = Logger(subsystem: "com.rgb2gif", category: "SceneDelegate")

@available(iOS 26.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
              willConnectTo session: UISceneSession,
              options connectionOptions: UIScene.ConnectionOptions) {

        guard let windowScene = (scene as? UIWindowScene) else { return }

        // Create window
        window = UIWindow(windowScene: windowScene)

        // ENHANCED VERSION: Use SimpleRealCameraViewController with 80×80/128×128 modes
        let rootViewController = SimpleRealCameraViewController()

        // Wrap in navigation controller for future navigation
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.navigationBar.isHidden = true  // Hide initially

        // Set root and show
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()

        sceneLogger.info("Scene connected with SimpleRealCameraViewController")
        print("✅ SceneDelegate: Window created with enhanced camera controller (80×80/128×128, front/back camera)")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        sceneLogger.info("Scene disconnected")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        sceneLogger.info("Scene became active")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        sceneLogger.info("Scene will resign active")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        sceneLogger.info("Scene will enter foreground")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        sceneLogger.info("Scene did enter background")
    }
}
