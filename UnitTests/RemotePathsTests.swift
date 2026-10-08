import XCTest

/// Paths, permissions, folder order and the transfer queue of the file
/// browser (Termoak/Model/RemotePaths.swift, compiled into the target).
final class RemotePathsTests: XCTestCase {
    func testParentAndChild() {
        XCTAssertEqual(RemotePaths.parent("/"), "/")
        XCTAssertEqual(RemotePaths.parent("/etc"), "/")
        XCTAssertEqual(RemotePaths.parent("/etc/nginx/"), "/etc")
        XCTAssertEqual(RemotePaths.parent("/home/ana/notes.txt"), "/home/ana")
        XCTAssertEqual(RemotePaths.child("/", "a"), "/a")
        XCTAssertEqual(RemotePaths.child("/home/ana", "a b.txt"), "/home/ana/a b.txt")
    }

    func testInvalidNames() {
        for name in ["", "  ", ".", "..", "a/b", "a\u{0}b"] {
            XCTAssertTrue(RemotePaths.invalidName(name), name)
        }
        for name in ["a", ".bashrc", "notes (1).txt", "..."] {
            XCTAssertFalse(RemotePaths.invalidName(name), name)
        }
        XCTAssertEqual(RemotePaths.uploadName("photo.jpg"), "photo.jpg")
        XCTAssertEqual(RemotePaths.uploadName("dir/photo.jpg"), "photo.jpg")
        XCTAssertEqual(RemotePaths.uploadName(".."), "file")
    }

    /// The setuid, setgid and sticky bits are kept, and typed octal is read.
    func testSpecialBitsAreKept() {
        XCTAssertEqual(RemotePaths.editableMode(0o104755), 0o4755)
        XCTAssertEqual(RemotePaths.editableMode(0o041777), 0o1777)
        XCTAssertEqual(RemotePaths.editableMode(nil), 0o644)
        XCTAssertEqual(RemotePaths.octal(0o104755), "4755")
        XCTAssertEqual(RemotePaths.octal(0o100644), "644")
        XCTAssertEqual(RemotePaths.parseOctal("4755"), 0o4755)
        XCTAssertEqual(RemotePaths.parseOctal(" 0644 "), 0o644)
        XCTAssertEqual(RemotePaths.parseOctal("7"), 0o7)
        XCTAssertNil(RemotePaths.parseOctal(""))
        XCTAssertNil(RemotePaths.parseOctal("888"))
        XCTAssertNil(RemotePaths.parseOctal("17777"))
        XCTAssertNil(RemotePaths.parseOctal("rwx"))
    }

    func testFreeName() {
        XCTAssertEqual(RemotePaths.freeName("a.txt", taken: []), "a.txt")
        XCTAssertEqual(RemotePaths.freeName("a.txt", taken: ["a.txt"]), "a (1).txt")
        XCTAssertEqual(RemotePaths.freeName("a.txt", taken: ["a.txt", "a (1).txt"]), "a (2).txt")
        XCTAssertEqual(RemotePaths.freeName("archive.tar.gz", taken: ["archive.tar.gz"]), "archive.tar (1).gz")
        XCTAssertEqual(RemotePaths.freeName("Makefile", taken: ["Makefile"]), "Makefile (1)")
        XCTAssertEqual(RemotePaths.freeName(".bashrc", taken: [".bashrc"]), ".bashrc (1)")
    }

    private struct Entry { let name: String; let dir: Bool; let size: UInt64; let modified: Int64? }

    private func arrange(_ e: [Entry], _ sort: FileSort, descending: Bool = false, hidden: Bool = false, query: String = "") -> [String] {
        FileListing.arrange(e, item: { FileListingItem(name: $0.name, dir: $0.dir, size: $0.size, modified: $0.modified) },
                            sort: sort, descending: descending, showHidden: hidden, query: query).map(\.name)
    }

    func testFolderOrder() {
        let e = [
            Entry(name: "b.log", dir: false, size: 10, modified: 300),
            Entry(name: "A.txt", dir: false, size: 30, modified: 100),
            Entry(name: "src", dir: true, size: 4096, modified: 50),
            Entry(name: ".git", dir: true, size: 4096, modified: 400),
            Entry(name: "c.bin", dir: false, size: 20, modified: nil),
        ]
        XCTAssertEqual(arrange(e, .name), ["src", "A.txt", "b.log", "c.bin"])
        XCTAssertEqual(arrange(e, .name, descending: true), ["src", "c.bin", "b.log", "A.txt"])
        XCTAssertEqual(arrange(e, .size, descending: true), ["src", "A.txt", "c.bin", "b.log"])
        XCTAssertEqual(arrange(e, .date, descending: true), ["src", "b.log", "A.txt", "c.bin"])
        XCTAssertEqual(arrange(e, .name, hidden: true), [".git", "src", "A.txt", "b.log", "c.bin"])
        XCTAssertEqual(arrange(e, .name, query: " A. "), ["A.txt"])
    }

    func testChoosingTheSortAgainTurnsItAround() {
        XCTAssertTrue(FileListing.nextSort(current: .name, descending: false, chosen: .name) == (.name, true))
        XCTAssertTrue(FileListing.nextSort(current: .name, descending: true, chosen: .size) == (.size, true))
        XCTAssertTrue(FileListing.nextSort(current: .size, descending: true, chosen: .size) == (.size, false))
        XCTAssertTrue(FileListing.nextSort(current: .date, descending: false, chosen: .name) == (.name, false))
    }

    /// Two transfers at once; the others wait in order, and a cancelled
    /// waiting one never starts.
    func testTransferSlots() {
        var slots = TransferSlots(limit: 2)
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertTrue(slots.enqueue(ids[0]))
        XCTAssertTrue(slots.enqueue(ids[1]))
        XCTAssertFalse(slots.enqueue(ids[2]))
        XCTAssertFalse(slots.enqueue(ids[3]))
        XCTAssertFalse(slots.enqueue(ids[4]))
        XCTAssertEqual(slots.finish(ids[3]), [])
        XCTAssertEqual(slots.finish(ids[0]), [ids[2]])
        XCTAssertEqual(slots.finish(ids[1]), [ids[4]])
        XCTAssertEqual(slots.finish(ids[2]), [])
        XCTAssertEqual(slots.running, [ids[4]])
        XCTAssertTrue(slots.enqueue(ids[0]))
    }
}
