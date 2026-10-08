import XCTest

/// AI tasks of server 0.6 through the generic API (Termoak/Model/AiTaskJson.swift).
final class AiTaskJsonTests: XCTestCase {
    func testNewTaskBody() {
        let plain = NewAiTask(prompt: "  check disk \n", mode: "ask").body
        XCTAssertEqual(plain["prompt"] as? String, "check disk")
        XCTAssertEqual(plain["mode"] as? String, "ask")
        for key in ["provider", "effort", "host_ids", "group_id", "tag", "fan_out", "plan_first"] { XCTAssertNil(plain[key], key) }

        var t = NewAiTask(prompt: "update", mode: "confirm")
        t.provider = NewAiTask.provider("claude", model: "opus")
        t.effort = "high"
        t.groupId = "g1"
        t.tag = " web "
        t.fanOut = true
        t.planFirst = true
        t.hostIds = ["h1"]
        let b = AiJson.object(AiJson.encode(t.body))
        XCTAssertEqual(b["provider"] as? String, "claude::opus")
        XCTAssertEqual(b["effort"] as? String, "high")
        XCTAssertEqual(b["group_id"] as? String, "g1")
        XCTAssertEqual(b["tag"] as? String, "web")
        XCTAssertEqual(b["fan_out"] as? Bool, true)
        XCTAssertEqual(b["plan_first"] as? Bool, true)
        XCTAssertEqual(b["host_ids"] as? [String], ["h1"])
        XCTAssertEqual(NewAiTask.provider("gpt", model: nil), "gpt")
        XCTAssertNil(NewAiTask.provider(nil, model: "x"))
    }

    func testProviders() {
        let list = AiProviderList.parse("""
        {"default":"claude","fallback":null,"default_mode":"ask","providers":[
          {"key":"claude","label":"Claude","available":true,"hidden":false,"default_model":"sonnet","models":["sonnet","opus"]},
          {"key":"gpt","label":"GPT","available":false,"hidden":false,"models":[],"reason":"not available on this server"},
          {"key":"x","label":"X","available":true,"hidden":true,"models":[]}]}
        """)
        XCTAssertEqual(list.defaultProvider?.label, "Claude")
        XCTAssertEqual(list.shown.map(\.key), ["claude", "gpt"])
        XCTAssertEqual(list.providers[0].models, ["sonnet", "opus"])
        XCTAssertEqual(list.providers[1].available, false)
        XCTAssertEqual(list.providers[1].reason, "not available on this server")
        XCTAssertEqual(AiProviderList.parse("nope").providers, [])
    }

    func testTaskExtras() {
        let e = AiTaskExtras.parse("""
        {"id":"t","mode":"auto","fan_out":true,"tag":"web","plan_first":true,"plan":{"text":"1. a","approved":true},
         "steps":[{"call_id":"1"},{"call_id":"2"}],
         "hosts":[{"host_id":"h1","label":"web1","task_id":"c1","status":"completed","summary":"ok","duration_ms":65000,"cost_micros":1200,"pending_approvals":0},
                  {"host_id":"h2","label":"web2","task_id":"c2","status":"waiting_approval","cost_micros":0,"pending_approvals":2}]}
        """)
        XCTAssertEqual(e.mode, "auto")
        XCTAssertTrue(e.fanOut)
        XCTAssertEqual(e.tag, "web")
        XCTAssertEqual(e.plan, "1. a")
        XCTAssertTrue(e.planApproved)
        XCTAssertEqual(e.steps, 2)
        XCTAssertEqual(e.hosts.map(\.taskId), ["c1", "c2"])
        XCTAssertEqual(e.hosts[0].durationMs, 65000)
        XCTAssertEqual(e.hosts[1].pendingApprovals, 2)
        XCTAssertNil(e.parentId)
        XCTAssertEqual(AiTaskExtras.parse("{\"parent_id\":\"p\"}").parentId, "p")
    }

    func testRunbookAndDurations() {
        let r = AiRunbook.parse("{\"name\":\"Fix\",\"description\":\"d\",\"script\":\"df -h\",\"variables\":[\"host\"],\"steps\":1}")
        XCTAssertEqual(r.script, "df -h")
        XCTAssertEqual(r.steps, 1)
        XCTAssertEqual(r.variables, ["host"])
        XCTAssertTrue(AiRunbook.saveBody(name: "  ").isEmpty)
        XCTAssertEqual(AiRunbook.saveBody(name: " Disk ")["name"] as? String, "Disk")
        XCTAssertEqual(aiDuration(ms: 800), "800 ms")
        XCTAssertEqual(aiDuration(ms: 5_000), "5 s")
        XCTAssertEqual(aiDuration(ms: 65_000), "1 min 5 s")
        XCTAssertEqual(aiDuration(ms: 120_000), "2 min")
    }
}
