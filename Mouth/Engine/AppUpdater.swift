import Foundation
import Security

extension Notification.Name {
    static let mouthUpdaterStatusChanged = Notification.Name("mouth.updater_status_changed")
}

enum MouthUpdaterStatus: String {
    case idle
    case checking
    case updateAvailable
    case upToDate
    case error
}

private enum UpdaterStatusKeys {
    static let status = "status"
    static let message = "message"
}

@MainActor
protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func checkForUpdates(_ sender: Any?)
}

@MainActor
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = false
    let unavailableReason: String?

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_: Any?) {
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.error.rawValue,
                UpdaterStatusKeys.message: unavailableReason ?? "Updates are unavailable in this build.",
            ]
        )
    }
}

#if canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    let isAvailable: Bool = true
    let unavailableReason: String? = nil

    init(savedAutoUpdate: Bool) {
        super.init()
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = savedAutoUpdate
        controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.checking.rawValue,
                UpdaterStatusKeys.message: "Checking for updates…",
            ]
        )
        controller.checkForUpdates(sender)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.upToDate.rawValue,
                UpdaterStatusKeys.message: "You're up to date.",
            ]
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Sparkle provides error context even for "no update"; keep messaging simple.
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.upToDate.rawValue,
                UpdaterStatusKeys.message: "You're up to date.",
            ]
        )
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.updateAvailable.rawValue,
                UpdaterStatusKeys.message: "Update available.",
            ]
        )
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NotificationCenter.default.post(
            name: .mouthUpdaterStatusChanged,
            object: self,
            userInfo: [
                UpdaterStatusKeys.status: MouthUpdaterStatus.error.rawValue,
                UpdaterStatusKeys.message: error.localizedDescription,
            ]
        )
    }
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}

@MainActor
func makeUpdaterController() -> UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"
    guard isBundledApp else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    // Avoid Sparkle UI in local/debug builds where code signing and feed URL are usually missing.
    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if (feed?.isEmpty ?? true) {
        return DisabledUpdaterController(unavailableReason: "Updates feed not configured.")
    }

    let defaults = UserDefaults.standard
    let autoUpdateKey = "mouth.auto_update_enabled"
    let savedAutoUpdate = (defaults.object(forKey: autoUpdateKey) as? Bool) ?? true
    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
}
#else
@MainActor
func makeUpdaterController() -> UpdaterProviding {
    DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
}
#endif
