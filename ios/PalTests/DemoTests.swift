import XCTest
@testable import Pal

final class DemoTests: XCTestCase {
    private func demo(step: Int = 0, status: String = "ready", prompt: String? = "Exact server script.", generation: UUID = UUID(), startsAt: String = "2099-10-16T19:30:00Z") throws -> DemoState {
        var object: [String: Any] = ["generation": generation.uuidString, "step": step, "total": 6, "status": status, "starts_at": startsAt]
        if let prompt { object["next_prompt"] = prompt }
        return try JSONDecoder().decode(DemoState.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testNormalGroupsAndLegacyStateDoNotBecomeDemos() throws {
        let old = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "Friends"]))
        XCTAssertFalse(old.isDemo)
        let labeled = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "Demo", "is_demo": true]))
        XCTAssertTrue(labeled.isDemo)
        let legacy = Data("{\"members\":[],\"places\":[],\"sources\":[],\"polls\":[],\"plans\":[],\"memories\":[],\"reminders\":[],\"reactions\":[],\"settings\":null}".utf8)
        XCTAssertNil(try JSONDecoder().decode(GroupState.self, from: legacy).demo)
    }
    func testOnlyReadySceneWithExactServerPromptCanAdvance() throws {
        let prompt = "Friday at eight; preserve the server's exact wording."
        let ready = try demo(prompt: prompt)
        XCTAssertTrue(ready.canAdvance)
        XCTAssertEqual(ready.nextPrompt, prompt)
        for status in ["actors", "pal", "failed"] {
            let waiting = try demo(step: 1, status: status)
            XCTAssertFalse(waiting.canAdvance)
        }
        XCTAssertFalse(try demo(prompt: nil).canAdvance)
        XCTAssertFalse(try demo(prompt: "  \n ").canAdvance)
    }
    func testCompletedOrExpiredDemoCannotSendAnExtraScene() throws {
        let complete = try demo(step: 6)
        XCTAssertFalse(complete.canAdvance)
        XCTAssertFalse(try demo(startsAt: "2000-01-01T00:00:00Z").canAdvance)
        XCTAssertThrowsError(try demo(step: 7))
        XCTAssertThrowsError(try demo(step: -1))
    }
    private func suggest(_ composer: inout DemoComposerState, _ state: DemoState?, draft: String = "", editing: Bool = false,
                         pending: Bool = false, attachment: Bool = false, reply: Bool = false, isDemo: Bool = true) -> String? {
        composer.suggestion(for: state, isDemo: isDemo, draft: draft, isEditing: editing, hasPending: pending, hasAttachment: attachment, hasReply: reply)
    }
    func testPrefillPreservesTypedDraftAndLiveEditing() throws {
        let state = try demo(prompt: "Next exact prompt"), next = try demo(step: 1, generation: state.generation)
        var composer = DemoComposerState()
        XCTAssertNil(suggest(&composer, state, draft: "My unfinished thought"))
        XCTAssertNil(suggest(&composer, state, editing: true))
        XCTAssertEqual(suggest(&composer, state), state.nextPrompt)
        XCTAssertNil(suggest(&composer, next, draft: "Edited suggestion"))
        XCTAssertNil(suggest(&composer, next, editing: true))
        XCTAssertEqual(suggest(&composer, next), next.nextPrompt)
    }
    func testExactPrefillSubmissionCarriesStepAndGenerationOnlyOnce() throws {
        let prompt = "  Preserve exact server wording.\n", state = try demo(step: 2, prompt: prompt)
        var composer = DemoComposerState()
        XCTAssertEqual(suggest(&composer, state), prompt)
        let submission = try XCTUnwrap(composer.submission(for: prompt, demo: state, hasAttachment: false, hasReply: false))
        XCTAssertEqual(submission.body, prompt)
        XCTAssertEqual(submission.step, 2)
        XCTAssertEqual(submission.generation, state.generation)
        XCTAssertNil(composer.submission(for: prompt, demo: state, hasAttachment: false, hasReply: false))
        XCTAssertNil(suggest(&composer, state))
        XCTAssertNil(suggest(&composer, try demo(step: 3, status: "pal", generation: state.generation)))
        XCTAssertEqual(suggest(&composer, try demo(step: 3, generation: state.generation)), "Exact server script.")
    }
    func testEditedStaleAndMediaDraftsRemainOrdinaryMessages() throws {
        let state = try demo()
        for mode in ["edited", "stale", "media", "reply"] {
            var composer = DemoComposerState()
            _ = suggest(&composer, state)
            let current = mode == "stale" ? try demo(generation: UUID()) : state
            XCTAssertNil(composer.submission(for: mode == "edited" ? "My custom follow-up" : state.nextPrompt!, demo: current, hasAttachment: mode == "media", hasReply: mode == "reply"))
        }
    }
    func testManualSendCannotRefillTheCurrentSuggestionAfterTheInputClears() throws {
        let state = try demo(prompt: "Suggested message"), next = try demo(step: 1, prompt: "Next message", generation: state.generation)
        for body in ["My own message", "我改成自己的訊息", "First line\nSecond line"] {
            var composer = DemoComposerState()
            XCTAssertNil(suggest(&composer, state, draft: body), "Loading the room preserves typed text.")
            XCTAssertNil(composer.submission(for: body, demo: state, hasAttachment: false, hasReply: false))
            XCTAssertNil(suggest(&composer, state, pending: true))
            XCTAssertNil(suggest(&composer, state), "Acknowledgement or keyboard dismissal cannot restore the same suggestion.")
            XCTAssertNil(suggest(&composer, next, draft: "My new draft"), "A later step cannot replace text typed after sending.")
            XCTAssertEqual(suggest(&composer, next), "Next message", "The next step remains available when the composer is idle.")
        }
    }
    func testPhotoAndReplySendsDoNotRefillAnUnseenSuggestion() throws {
        let state = try demo()
        for hasAttachment in [false, true] {
            var composer = DemoComposerState()
            XCTAssertNil(composer.submission(for: "Photo or reply", demo: state, hasAttachment: hasAttachment, hasReply: !hasAttachment))
            XCTAssertNil(suggest(&composer, state))
        }
    }
    func testPrefillWaitsForOutboxAndDoesNotAffectNormalRooms() throws {
        let state = try demo()
        var composer = DemoComposerState()
        XCTAssertNil(suggest(&composer, state, isDemo: false))
        XCTAssertNil(suggest(&composer, state, pending: true))
        XCTAssertNil(suggest(&composer, state, attachment: true))
        XCTAssertNil(suggest(&composer, state, reply: true))
        XCTAssertNil(suggest(&composer, try demo(status: "actors")))
        XCTAssertEqual(suggest(&composer, state), state.nextPrompt)
        XCTAssertNil(suggest(&composer, state)) // Deleting a suggestion does not force it back.
        let reset = try demo(generation: UUID())
        XCTAssertEqual(suggest(&composer, reset), reset.nextPrompt)
    }
    func testResetRefreshesOnlyUntouchedPrefillAndUsesFreshGeneration() throws {
        let original = try demo(prompt: "Original Friday plan"), reset = try demo(prompt: "Fresh Friday plan")
        var composer = DemoComposerState()
        let oldDraft = try XCTUnwrap(suggest(&composer, original))
        XCTAssertNil(suggest(&composer, reset, draft: oldDraft, editing: true))
        XCTAssertNil(suggest(&composer, reset, draft: oldDraft, pending: true))
        XCTAssertNil(suggest(&composer, reset, draft: oldDraft, attachment: true))
        XCTAssertNil(suggest(&composer, reset, draft: oldDraft, reply: true))
        XCTAssertEqual(suggest(&composer, reset, draft: oldDraft), reset.nextPrompt)
        let submission = try XCTUnwrap(composer.submission(for: reset.nextPrompt!, demo: reset, hasAttachment: false, hasReply: false))
        XCTAssertEqual(submission.generation, reset.generation)
        XCTAssertEqual(submission.step, reset.step)
        XCTAssertNotEqual(submission.generation, original.generation)
        var edited = DemoComposerState()
        _ = suggest(&edited, original)
        XCTAssertNil(suggest(&edited, reset, draft: "Original Friday plan, with my own change"))
    }
    func testResetChangesSceneIdentityAndDurableRetryPreservesOriginalGeneration() throws {
        let generation = UUID(), groupID = UUID(), userID = UUID(), clientID = UUID()
        let original = try demo(generation: generation)
        XCTAssertNotEqual(original.sceneID, try demo(generation: UUID()).sceneID)
        XCTAssertNotEqual(original.sceneID, try demo(step: 1, generation: generation).sceneID)
        let outgoing = OutgoingMessage(groupID: groupID, userID: userID, clientID: clientID, body: "Exact server script.", replyToID: nil, failed: true, createdAt: "2026-10-11T20:00:00Z", demoStep: 0, demoGeneration: generation)
        let restored = try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(outgoing))
        XCTAssertEqual(restored.clientID, clientID)
        XCTAssertEqual(restored.demoStep, 0)
        XCTAssertEqual(restored.demoGeneration, generation)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outgoing)) as? [String: Any])
        legacy.removeValue(forKey: "demoStep"); legacy.removeValue(forKey: "demoGeneration")
        let normal = try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(normal.demoStep)
        XCTAssertNil(normal.demoGeneration)
    }
}
