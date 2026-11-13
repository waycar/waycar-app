/// How a scene UIKit builds itself reaches the app's one `WaycarAppModel`.
///
/// The CarPlay scene's delegate is instantiated by UIKit from its class, so
/// nothing can hand it the model; and `UIApplication.shared.delegate` is
/// SwiftUI's proxy, not `PushRegistrationDelegate`. The app delegate
/// registers its lazy model here at launch, as `QuickActionCenter.shared`
/// carries quick actions to windows. The provider keeps the model lazy, so
/// the Debug screenshot mode still never builds the production stores.
@MainActor
final class AppModelRegistry {
    static let shared = AppModelRegistry()

    private var provider: (@MainActor () -> WaycarAppModel)?

    func register(_ provider: @escaping @MainActor () -> WaycarAppModel) {
        self.provider = provider
    }

    /// The app's model, built on first use; nil before launch registered it.
    var appModel: WaycarAppModel? { provider?() }
}
