import CarPlay
import UIKit

/// The CarPlay scene's delegate, chosen by role in
/// `PushRegistrationDelegate.application(_:configurationForConnecting:options:)`
/// (docs/design/carplay.md §6).
///
/// The car runs on the app's one `ConsoleStore`, reached through
/// `AppModelRegistry`: the same Host connections, Agent list and Composer
/// drafts the phone has. A CarPlay-only launch (the phone locked in a
/// pocket) starts the app here, since no window ever appears to do it, and
/// the scene's foreground edges hold the Host connections like a window's
/// do. The Debug screenshot mode runs on the demo store instead, so the
/// Simulator's CarPlay display can be exercised without any Host.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayTemplateCoordinator?
    /// Nil in the screenshot mode, whose demo store owns no app activity.
    private var appModel: WaycarAppModel?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        guard CarPlaySupport.isAvailable else {
            showUnsupported(on: interfaceController)
            return
        }
        guard case let (console, actions)? = connectConsole() else { return }
        let coordinator = CarPlayTemplateCoordinator(
            interfaceController: interfaceController, console: console, actions: actions,
            dictation: DictationEngines.live)
        self.coordinator = coordinator
        coordinator.start()
        // The Natural voice's model loads now, not on the first line.
        Task { await NaturalVoice.prepare() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
        appModel?.carPlayDidEnterBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        appModel?.carPlayDidBecomeActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        coordinator?.sceneDidEnterBackground()
        appModel?.carPlayDidEnterBackground()
    }

    /// Below iOS 26.4 the voice template has no action buttons and the
    /// category does not exist: one static screen, no Console, no dial
    /// (docs/design/carplay.md Q21). It states the condition only (CPG p.4).
    private func showUnsupported(on interfaceController: CPInterfaceController) {
        let template = CPInformationTemplate(
            title: "Waycar", layout: .leading,
            items: [CPInformationItem(title: nil, detail: CarPlaySupport.unsupportedMessage)],
            actions: [])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    /// The store the car shows and the actions it takes, with the app
    /// started if no window did.
    private func connectConsole() -> (ConsoleStore, AgentActionService)? {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled {
                // The Chat Mode profile, so Blocked Agents have a prompt.
                let console = DemoScreenshotFixture.makeConsoleStore(opensChat: true)
                console.setHosts(DemoScreenshotFixture.hosts)
                Task { await console.resume() }
                return (console, AgentActionService(console: console))
            }
        #endif
        guard let model = AppModelRegistry.shared.appModel else { return nil }
        appModel = model
        model.start()
        return (model.console, model.agentActions)
    }
}

/// Whether this device runs Waycar's CarPlay app: only an iPhone connects to
/// CarPlay, so an iPad shows no CarPlay UI at all, and the voice-based
/// conversational category and
/// `CPVoiceControlState.actionButtons` need iOS 26.4.
enum CarPlaySupport {
    @MainActor static var isAvailable: Bool {
        isAvailable(
            idiom: UIDevice.current.userInterfaceIdiom,
            system: ProcessInfo.processInfo.operatingSystemVersion)
    }

    nonisolated static func isAvailable(
        idiom: UIUserInterfaceIdiom, system: OperatingSystemVersion
    ) -> Bool {
        idiom == .phone
            && (system.majorVersion, system.minorVersion) >= (26, 4)
    }

    static let unsupportedMessage = "Waycar in CarPlay needs iOS 26.4 or later."
}
