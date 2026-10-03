import Foundation

/// Brings sign-ins over from the spike (`iSmithSpike`) on iSmith's first launch. The spike's files
/// are only read, never changed or deleted.
public enum SpikeImport {
    /// Imports when iSmith has no config.json yet and the spike has one: the spike's plaintext
    /// vault.json goes into the encrypted vault, and its config.json is copied for `Config` to load
    /// (and migrate, if it's an older version). Returns whether the config was imported.
    @MainActor @discardableResult
    public static func runIfNeeded(from spikeDir: URL, configURL: URL, vault: Vault) -> Bool {
        let files = FileManager.default
        let spikeConfig = spikeDir.appendingPathComponent("config.json")
        guard !files.fileExists(atPath: configURL.path), files.fileExists(atPath: spikeConfig.path) else { return false }
        // The vault goes first: if the app stops before the config is copied, the next launch
        // finishes the import. A vault that already has entries is from that interrupted import.
        let spikeVault = spikeDir.appendingPathComponent("vault.json")
        var imported = 0
        if vault.entries.isEmpty, files.fileExists(atPath: spikeVault.path) {
            do {
                let entries = try JSONDecoder().decode([String: Vault.Entry].self, from: Data(contentsOf: spikeVault))
                vault.importEntries(entries)
                imported = entries.count
            } catch {
                NSLog("iSmith: the spike's vault.json could not be read (\(error)); sign-ins start empty")
            }
        }
        do {
            try SecureFile.prepareDirectory(configURL.deletingLastPathComponent())
            try SecureFile.write(Data(contentsOf: spikeConfig), to: configURL)
        } catch {
            NSLog("iSmith: the spike's config.json could not be copied: \(error)")
            return false
        }
        NSLog("iSmith: imported the spike's config and \(imported) saved sign-ins from \(spikeDir.path)")
        return true
    }
}
