import XCTest

/// A host's groups from the nearest one up (Termoak/Model/GroupChain.swift).
final class GroupChainTests: XCTestCase {
    private let parents: [String: String?] = ["web": "prod", "prod": "all", "all": nil, "loop1": "loop2", "loop2": "loop1",
                                              "orphan": "gone"]

    private func chain(_ start: String?) -> [String] {
        GroupChain.ids(from: start) { parents[$0] }
    }

    func testNearestFirstUpToTheTop() {
        XCTAssertEqual(chain("web"), ["web", "prod", "all"])
        XCTAssertEqual(chain("all"), ["all"])
        XCTAssertEqual(chain(nil), [])
    }

    func testStopsAtLoopsAndMissingGroups() {
        XCTAssertEqual(chain("loop1"), ["loop1", "loop2"])
        XCTAssertEqual(chain("orphan"), ["orphan"])
        XCTAssertEqual(chain("gone"), [])
    }
}
