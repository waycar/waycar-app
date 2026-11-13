import StoreKit

/// Updates Apple's own SKAdNetwork postback conversion value. The system
/// automatically mirrors this call into AdAttributionKit (Apple's
/// "Understanding AdAttributionKit and SKAdNetwork interoperability"), so
/// one call covers both frameworks and whichever one actually signed the ad.
///
/// This is not the consent-gated product-analytics stack in
/// `Sources/Waycar/Analytics/`, and it is not an attribution SDK: it calls
/// only Apple's own on-device StoreKit API. SKAdNetwork needs no App
/// Tracking Transparency prompt, reads no IDFA, and sends no identifier off
/// device — Apple signs and anonymizes the postback and delivers it to
/// whichever ad network (if any) signed the ad that led to this install or
/// reengagement; an organic install triggers no postback at all. A copy
/// also goes to Singular, Waycar's measurement vendor, through the
/// `NSAdvertisingAttributionReportEndpoint` and `AttributionCopyEndpoint`
/// keys in `project.yml` — one per framework, since each is a separate
/// opt-in. See PRIVACY.md "SKAdNetwork attribution".
@MainActor
enum SKANConversionReporting {
    /// Registers the install, once per launch (outside the unit-test host —
    /// see the `ICloudSync.runsInThisProcess` guard around this call in
    /// `WaycarAppModel.start()`). Waycar is free (ADR 0032), so there is no
    /// later conversion to report and the value is always the lowest.
    static func reportInstall() {
        Task {
            // A failed update is tried again on the next launch.
            try? await SKAdNetwork.updatePostbackConversionValue(
                0, coarseValue: .low, lockWindow: false)
        }
    }
}
