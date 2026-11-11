import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 520)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = MusikeRootController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
