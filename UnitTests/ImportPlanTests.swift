import XCTest

final class ImportPlanTests: XCTestCase {
    func testStatusFollowsThePolicy() {
        XCTAssertEqual(ImportPlan.status(.none, policy: .skip, included: true), .new)
        XCTAssertEqual(ImportPlan.status(.none, policy: .skip, included: false), .unchecked)
        XCTAssertEqual(ImportPlan.status(.existing(label: "web"), policy: .skip, included: true), .existingSkipped("web"))
        XCTAssertEqual(ImportPlan.status(.existing(label: "web"), policy: .update, included: true), .updates("web"))
        XCTAssertEqual(ImportPlan.status(.existing(label: "web"), policy: .copy, included: true), .copyOf("web"))
        // A repeat inside the file is only created with "copy".
        XCTAssertEqual(ImportPlan.status(.inFile, policy: .update, included: true), .repeatSkipped)
        XCTAssertEqual(ImportPlan.status(.inFile, policy: .skip, included: true), .repeatSkipped)
        XCTAssertEqual(ImportPlan.status(.inFile, policy: .copy, included: true), .repeatCopy)
        XCTAssertEqual(ImportPlan.status(.existing(label: "web"), policy: .update, included: false), .unchecked)
    }

    func testImportCount() {
        let s: [ImportRowStatus] = [.new, .unchecked, .updates("a"), .existingSkipped("b"), .repeatCopy, .repeatSkipped, .copyOf("c")]
        XCTAssertEqual(ImportPlan.importCount(s), 4)
    }

    func testAssignKeepsOneColumnPerField() {
        var m: [(field: String, column: Int)] = [("label", 0), ("address", 1)]
        m = ImportPlan.assign("address", toColumn: 2, in: m)
        XCTAssertEqual(m.map(\.field), ["label", "address"])
        XCTAssertEqual(m.map(\.column), [0, 2])
        m = ImportPlan.assign("user", toColumn: 0, in: m)
        XCTAssertEqual(m.map(\.field), ["user", "address"])
        m = ImportPlan.assign(nil, toColumn: 2, in: m)
        XCTAssertEqual(m.map(\.field), ["user"])
        XCTAssertFalse(ImportPlan.hasAddress(m))
        XCTAssertEqual(ImportPlan.field(ofColumn: 0, in: m), "user")
        XCTAssertNil(ImportPlan.field(ofColumn: 1, in: m))
    }

    func testExampleSkipsTheHeaderAndBlanks() {
        let sample = [["name", "ip"], ["", "10.0.0.1"], ["db", "10.0.0.2"]]
        XCTAssertEqual(ImportPlan.example(column: 0, sample: sample, hasHeader: true), "db")
        XCTAssertEqual(ImportPlan.example(column: 1, sample: sample, hasHeader: true), "10.0.0.1")
        XCTAssertEqual(ImportPlan.example(column: 0, sample: sample, hasHeader: false), "name")
        XCTAssertNil(ImportPlan.example(column: 5, sample: sample, hasHeader: true))
    }

    func testWarningsByCode() {
        let t = ImportPlan.warningText(code: "not_ssh", params: ["name": "desk", "protocol": "RDP"], fallback: "x")
        XCTAssertTrue(t.contains("desk") && t.contains("RDP"))
        XCTAssertEqual(ImportPlan.warningText(code: "something_new", params: [:], fallback: "English"), "English")
    }

    func testPassphrase() {
        XCTAssertEqual(ImportPlan.passphraseProblem("short", "short"), .short)
        XCTAssertEqual(ImportPlan.passphraseProblem("long enough", "long enougH"), .mismatch)
        XCTAssertNil(ImportPlan.passphraseProblem("long enough", "long enough"))
    }
}
