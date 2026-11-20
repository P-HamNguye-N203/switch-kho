import Foundation
import Testing
@testable import KhoCore

@Suite struct KhoIdentityTests {
    @Test func confirmAndReasons() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let vol = makeVolume(sb.kho.path, name: "Kho", uuid: "U1", isInternal: false)
        let (_, token) = try KhoIdentity.adopt(vol, linkRoot: sb.khoLink)
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(KhoIdentity.confirm(volumes: [vol], savedUUID: "U1", savedToken: token, linkRoot: sb.khoLink) != nil)

        // Same drive mounted elsewhere still counts.
        let moved = sb.root.appendingPathComponent("Kho 1")
        try FileManager.default.moveItem(at: sb.kho, to: moved)
        let vol2 = makeVolume(moved.path, name: "Kho", uuid: "U1", isInternal: false)
        #expect(KhoIdentity.confirm(volumes: [vol2], savedUUID: "U1", savedToken: token, linkRoot: sb.khoLink)?
            .layout.khoRoot.path == moved.path)

        let wrongUUID = makeVolume(moved.path, name: "Kho", uuid: "OTHER", isInternal: false)
        #expect(KhoIdentity.confirm(volumes: [wrongUUID], savedUUID: "U1", savedToken: token, linkRoot: sb.khoLink) == nil)
        #expect(KhoIdentity.mismatchReason(volumes: [wrongUUID], savedUUID: "U1", savedToken: token) != nil)

        #expect(KhoIdentity.confirm(volumes: [vol2], savedUUID: "U1", savedToken: "sai", linkRoot: sb.khoLink) == nil)
        #expect(KhoIdentity.mismatchReason(volumes: [vol2], savedUUID: "U1", savedToken: "sai") != nil)

        let image = makeVolume(moved.path, name: "Kho", uuid: "U1", isInternal: false, image: true)
        #expect(KhoIdentity.confirm(volumes: [image], savedUUID: "U1", savedToken: token, linkRoot: sb.khoLink) == nil)

        // Adopting the same drive again returns the same token.
        #expect(try KhoIdentity.adopt(vol2, linkRoot: sb.khoLink).token == token)

        try FileManager.default.removeItem(at: moved.appendingPathComponent("SwitchKho/.kho-id"))
        #expect(KhoIdentity.confirm(volumes: [vol2], savedUUID: "U1", savedToken: token, linkRoot: sb.khoLink) == nil)
    }
}
