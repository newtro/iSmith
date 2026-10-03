import BraveImport
import XCTest

final class ProfileDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempDirectory("ProfileDiscoveryTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProfile(_ name: String, files: [String]) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(file))
        }
    }

    private func writeLocalState(_ json: String) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent("Local State"))
    }

    func testFindsProfilesWithNamesAndOrder() throws {
        try makeProfile("Default", files: ["Bookmarks", "Login Data"])
        try makeProfile("Profile 1", files: ["Login Data For Account"])
        try makeProfile("Profile 3", files: ["Bookmarks"]) // on disk but not in Local State
        try makeProfile("Profile 10", files: ["Bookmarks"])
        try makeProfile("Profile 4", files: ["Preferences"]) // nothing to import
        try makeProfile("System Profile", files: ["Bookmarks"])
        try makeProfile("Guest Profile", files: ["Bookmarks"])
        try makeProfile("Crashpad", files: ["Bookmarks"]) // not a profile folder
        try writeLocalState("""
            {"profile": {"info_cache": {
                "Default": {"name": "Personal ✨", "is_using_default_name": false},
                "Profile 1": {"name": "Contoso"},
                "Profile 2": {"name": "Deleted folder"},
                "Profile 10": {"name": ""}},
              "profiles_order": ["Profile 1", "Default"]}}
            """)

        let profiles = try BraveProfiles.discover(root: root)
        XCTAssertEqual(profiles.map(\.directoryName), ["Profile 1", "Default", "Profile 3", "Profile 10"])
        XCTAssertEqual(profiles.map(\.displayName), ["Contoso", "Personal ✨", "Profile 3", "Profile 10"])
        XCTAssertEqual(profiles[0].url, root.appendingPathComponent("Profile 1", isDirectory: true))
        XCTAssertTrue(profiles[0].hasPasswords)
        XCTAssertFalse(profiles[0].hasBookmarks)
        XCTAssertTrue(profiles[1].hasBookmarks && profiles[1].hasPasswords)
    }

    func testWithoutLocalStateUsesFolderNames() throws {
        try makeProfile("Profile 2", files: ["Bookmarks"])
        try makeProfile("Default", files: ["Bookmarks"])
        try writeLocalState("{ not json")
        let profiles = try BraveProfiles.discover(root: root)
        XCTAssertEqual(profiles.map(\.directoryName), ["Default", "Profile 2"])
        XCTAssertEqual(profiles.map(\.displayName), ["Default", "Profile 2"])
    }

    func testNoBraveInstall() throws {
        XCTAssertEqual(try BraveProfiles.discover(root: root.appendingPathComponent("missing")), [])
    }

    /// A folder the process may not read (as macOS does for another app's data) is reported as a
    /// permission problem the app can explain, for discovery, bookmarks and passwords alike.
    func testUnreadableDataIsReportedAsPermissionDenied() throws {
        try makeProfile("Default", files: ["Bookmarks", "Login Data"])
        let profileDir = root.appendingPathComponent("Default")
        let bookmarks = profileDir.appendingPathComponent("Bookmarks")
        let loginData = profileDir.appendingPathComponent("Login Data")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bookmarks.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: loginData.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookmarks.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: loginData.path)
        }
        XCTAssertThrowsError(try BraveProfiles.discover(root: root)) { error in
            XCTAssertEqual(error as? BraveAccessError, .permissionDenied(path: self.root.path))
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let profile = BraveProfile(directoryName: "Default", displayName: "Default", url: profileDir)
        XCTAssertThrowsError(try BookmarksReader.read(profile: profile)) { error in
            XCTAssertEqual(error as? BraveAccessError, .permissionDenied(path: bookmarks.path))
        }
        let temp = try makeTempDirectory("ProfileDiscoveryTests-temp")
        defer { try? fm.removeItem(at: temp) }
        let reader = BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: temp)
        XCTAssertThrowsError(try reader.read(profile: profile)) { error in
            XCTAssertEqual(error as? BraveAccessError, .permissionDenied(path: loginData.path))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: temp.path), [], "work folder wiped on failure")
    }
}
