import Foundation
import Testing
@testable import KhoCore

@Suite struct KhoLayoutTests {
    let layout = KhoLayout(khoRoot: URL(fileURLWithPath: "/Volumes/Kho"),
                           linkRoot: URL(fileURLWithPath: "/Users/u/Library/Application Support/SwitchKho/KhoLink"))

    @Test func roundTripWithVietnameseAndSpaces() {
        let original = URL(fileURLWithPath: "/Users/u/Documents/Hồ sơ/Hoá đơn T3 (bản cuối).pdf")
        let archived = layout.archiveURL(forOriginal: original)
        #expect(archived.path == "/Volumes/Kho/SwitchKho/Archive/Users/u/Documents/Hồ sơ/Hoá đơn T3 (bản cuối).pdf")
        #expect(layout.originalURL(forArchived: archived)?.path == original.path)
        #expect(layout.relativePath(archived) == "SwitchKho/Archive/Users/u/Documents/Hồ sơ/Hoá đơn T3 (bản cuối).pdf")
    }

    @Test func outsideArchiveIsNil() {
        #expect(layout.originalURL(forArchived: URL(fileURLWithPath: "/Volumes/Kho/SwitchKho/Apps/x")) == nil)
        #expect(layout.originalURL(forArchived: URL(fileURLWithPath: "/Volumes/Other/x")) == nil)
    }

    @Test(arguments: ["../x", "/etc/x", "SwitchKho/../../x", "SwitchKho/Archive", "SwitchKho/ledger-backup.sqlite",
                      "SwitchKho/.kho-id", "", "SwitchKho/Archive//x", "SwitchKho/Other/x", "SwitchKho/Live/./x"])
    func absoluteURLRejects(_ rel: String) {
        #expect(throws: KhoError.self) { try layout.absoluteURL(relative: rel) }
    }

    @Test func absoluteURLAccepts() throws {
        #expect(try layout.absoluteURL(relative: "SwitchKho/Archive/Users/u/x").path
            == "/Volumes/Kho/SwitchKho/Archive/Users/u/x")
    }

    @Test func symlinkTargetGoesThroughLink() throws {
        let t = try layout.symlinkTarget(relative: "SwitchKho/Live/a/b")
        #expect(t.path == layout.linkRoot.path + "/Live/a/b")
        #expect(layout.isOurLinkTarget(t))
        #expect(!layout.isOurLinkTarget(URL(fileURLWithPath: "/Volumes/Kho/SwitchKho/Live/a/b")))
    }
}
