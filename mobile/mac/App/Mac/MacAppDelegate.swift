import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var instanceLock: MacInstanceLock?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            guard let lock = try MacInstanceLock.acquire(in: MacInstanceLock.applicationDirectory) else {
                // Launch Services normally activates the existing instance. A forced second launch exits here.
                exit(EXIT_SUCCESS)
            }
            instanceLock = lock
            return true
        } catch {
            NSLog("Musike could not establish its single-instance lock: %@", error.localizedDescription)
            exit(EXIT_FAILURE)
        }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
