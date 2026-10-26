import Testing
@testable import HogCore

@Test func versionIsSet() {
    #expect(!Hog.version.isEmpty)
    #expect(Hog.snapshotSchema == "hog.snapshot/1")
}
