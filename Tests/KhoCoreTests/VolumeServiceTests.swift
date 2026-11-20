import Foundation
import Testing
@testable import KhoCore

func makeVolume(_ path: String, name: String, uuid: String?, isInternal: Bool, root: Bool = false,
                image: Bool = false, format: String? = "APFS") -> VolumeInfo {
    VolumeInfo(url: URL(fileURLWithPath: path), name: name, uuid: uuid, total: 100, available: 50,
               availableForImportant: 60, isInternal: isInternal, isRoot: root, isDiskImage: image, format: format)
}

@Suite struct VolumeServiceTests {
    @Test func filterKeepsRootAndRealExternal() {
        let all = [
            makeVolume("/", name: "Macintosh HD", uuid: "R", isInternal: true, root: true),
            makeVolume("/Volumes/Kho", name: "Kho", uuid: "K", isInternal: false),
            makeVolume("/Volumes/Kiri", name: "Kiri", uuid: "D", isInternal: false, image: true),
            makeVolume("/Volumes/Data2", name: "Data2", uuid: "I", isInternal: true),
            makeVolume("/Volumes/NoUUID", name: "NoUUID", uuid: nil, isInternal: false),
        ]
        #expect(VolumeService.filterUserVolumes(all).map(\.name) == ["Macintosh HD", "Kho"])
    }

    @Test func realMachineHasOneRoot() {
        #expect(VolumeService.mountedVolumes().filter(\.isRoot).count == 1)
    }
}
