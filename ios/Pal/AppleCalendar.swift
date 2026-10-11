import SwiftUI
import EventKit
import EventKitUI

// This receipt remembers a local save, not whether the Calendar copy still exists.
enum AppleCalendarReceipt {
    private static func key(userID: UUID, planID: UUID) -> String {
        "AppleCalendarCopy.\(userID.uuidString).\(planID.uuidString)"
    }
    static func savedVersion(userID: UUID, planID: UUID, defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: key(userID: userID, planID: planID)) as? Int
    }
    @discardableResult
    static func record(action: EKEventEditViewAction, userID: UUID, planID: UUID, version: Int, defaults: UserDefaults = .standard) -> Bool {
        guard action == .saved else { return false }
        defaults.set(version, forKey: key(userID: userID, planID: planID))
        return true
    }
}

@MainActor
final class AppleCalendarDraft: Identifiable {
    let id = UUID()
    let userID: UUID
    let planID: UUID
    let version: Int
    let eventStore: EKEventStore
    let event: EKEvent

    init(plan: GroupPlan, group: ChatGroup, state: GroupState, userID: UUID) throws {
        guard plan.status == "confirmed", plan.attendees.contains(where: { $0.userID == userID && $0.status == "going" }),
              let start = plan.startsAt.flatMap(PalDate.date) else {
            throw PalFailure(message: "Confirm the plan and RSVP Going before adding a Calendar copy.")
        }
        guard let end = plan.endsAt.flatMap(PalDate.date), end > start else { throw PalFailure(message: "Set a valid end time before adding a Calendar copy.") }
        self.userID = userID
        planID = plan.id
        version = plan.version ?? 1
        let store = EKEventStore()
        eventStore = store
        event = EKEvent(eventStore: store)
        event.title = plan.title
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone(identifier: state.settings?.timezone ?? TimeZone.current.identifier) ?? .current
        event.notes = [plan.notes, "Changes in Pal do not update this copy."].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        event.url = URL(string: "pal://group/\(group.id.uuidString)/plan/\(plan.id.uuidString)")
        if let place = state.places.first(where: { $0.id == plan.placeID }) {
            event.location = [place.name, place.address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}

struct AppleCalendarEditor: UIViewControllerRepresentable {
    let draft: AppleCalendarDraft
    let onCompletion: (EKEventEditViewAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = draft.eventStore
        controller.event = draft.event
        controller.editViewDelegate = context.coordinator
        controller.view.tintColor = .label
        return controller
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        private let onCompletion: (EKEventEditViewAction) -> Void
        init(onCompletion: @escaping (EKEventEditViewAction) -> Void) { self.onCompletion = onCompletion }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onCompletion(action)
        }
    }
}
