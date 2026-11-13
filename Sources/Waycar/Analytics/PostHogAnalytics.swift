import Foundation
@preconcurrency import PostHog

/// The PostHog SDK behind `GatedAnalytics`, configured for anonymous event
/// counts only (PRIVACY.md): no session replay, autocapture, screen views,
/// lifecycle events, crash reports, surveys, feature flags or person
/// profiles, and swizzling off so the SDK never hooks the app's views or its
/// notification delegate. Events carry the device context PostHog adds
/// (OS, app version, device model, locale), the `env` super property, and
/// the synced anonymous distinct id passed with each capture.
///
/// The SDK is set up only once the user's choice allows analytics, so an
/// undecided or opted-out install never contacts PostHog at all.
///
/// posthog-ios 3.85.0 has no public switch for its remote config request:
/// setup always fetches the project's `/config` (`remoteConfig` is a
/// deprecated no-op). `preloadFeatureFlags` off is the only flags control.
@MainActor
final class PostHogAnalyticsSink: AnalyticsSink {
    /// Public, write-only project key; safe to ship.
    static let projectToken = "phc_DmYrhynP2Ly3k9pdY8bkbQH3isw4PzLovDsDXRbbQsQV"
    static let host = "https://us.i.posthog.com"

    /// `env` on every event: Debug builds are kept apart from shipped ones.
    static var environment: String {
        #if DEBUG
            "debug"
        #else
            "release"
        #endif
    }

    private var isSetUp = false
    /// Set by an opt-out; the next opt-in resets the SDK's identity first.
    private var needsReset = false

    func enable() {
        guard isSetUp else {
            setUp()
            return
        }
        PostHogSDK.shared.optIn()
        guard needsReset else { return }
        needsReset = false
        // A new SDK anonymous id and session, and no cached flags, for the
        // events after an opt-out. Done here rather than at the opt-out:
        // `reset()` also requests `/flags` even while opted out, and an
        // opted-out user's device must not contact PostHog. It clears
        // registered super properties, so `env` is registered again.
        PostHogSDK.shared.reset()
        registerSuperProperties()
    }

    func disable() {
        guard isSetUp else { return }
        PostHogSDK.shared.optOut()
        needsReset = true
    }

    func capture(_ name: String, properties: [String: String], distinctID: String) {
        guard isSetUp else { return }
        PostHogSDK.shared.capture(
            name, distinctId: distinctID, properties: properties, userProperties: nil,
            userPropertiesSetOnce: nil, groups: nil, timestamp: nil)
    }

    private func setUp() {
        let config = PostHogConfig(projectToken: Self.projectToken, host: Self.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        // Swizzling is what autocapture, screen views, replay, surveys and
        // the push hooks install through; none of them are wanted.
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.captureAutocaptureElementText = false
        config.rageClickConfig.enabled = false
        config.sessionReplay = false
        config.surveys = false
        config.errorTrackingConfig.autoCapture = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        PostHogSDK.shared.setup(config)
        // Clears an opt-out the SDK persisted in an earlier launch: this
        // layer's own setting is the source of truth.
        PostHogSDK.shared.optIn()
        registerSuperProperties()
        isSetUp = true
    }

    private func registerSuperProperties() {
        PostHogSDK.shared.register(["env": Self.environment])
    }
}
