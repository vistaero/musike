import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 520)
        // The content extends behind the native window controls, so the playback
        // controls and traffic lights occupy one continuous top bar.
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        let window = UIWindow(windowScene: scene)
        window.rootViewController = MusikeRootController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
