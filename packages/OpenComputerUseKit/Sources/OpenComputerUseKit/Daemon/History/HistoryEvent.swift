import Foundation

// CloudEvents 1.0 JSON envelopes for Computer History, following the upstream
// `urn:cua-driver:schema:history-event:v0` contract. Payloads are fixed-field
// and metadata-only: no screenshots, typed text, keystrokes, clipboard
// contents, tool arguments, accessibility trees, window titles, or URLs.

struct HistoryApplicationIdentity: Equatable, Sendable {
    var bundleID: String?
    var displayName: String?

    var isEmpty: Bool {
        bundleID == nil && displayName == nil
    }
}

enum HistoryEventPayload: Equatable, Sendable {
    /// User lifecycle operation: enable, disable, pause, resume, delete_requested.
    case control(operation: String)
    /// A Cua-mediated state-changing action began.
    case actionStarted
    /// The validated action outcome.
    case actionCompleted(effect: String, route: String?, deliveredCount: Int)
    /// Daemon lifecycle session boundary: started or ended.
    case session(phase: String)
    /// A local CLI or agent query returned events.
    case access(operation: String, returnedCount: Int)
    /// Fixed writer-health or dropped-event marker.
    case health(category: String, droppedEvents: Int)

    var kind: String {
        switch self {
        case .control: return "control"
        case .actionStarted: return "action_started"
        case .actionCompleted: return "action_completed"
        case .session: return "session"
        case .access: return "access"
        case .health: return "health"
        }
    }

    var eventType: String {
        switch self {
        case .control: return "cua-driver.history.control.v0"
        case .actionStarted: return "cua-driver.history.action_started.v0"
        case .actionCompleted: return "cua-driver.history.action_completed.v0"
        case let .session(phase):
            return phase == "started"
                ? "cua-driver.history.session_started.v0"
                : "cua-driver.history.session_ended.v0"
        case .access: return "cua-driver.history.access.v0"
        case .health: return "cua-driver.history.health.v0"
        }
    }
}

struct HistoryEvent: Equatable, Sendable {
    var id: String
    var streamID: String
    var sessionID: String
    var actionID: String?
    var sequence: UInt64
    var time: Date
    var capability: String?
    var application: HistoryApplicationIdentity
    var payload: HistoryEventPayload

    static let dataSchema = "urn:cua-driver:schema:history-event:v0"

    private static func formatTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    var subject: String {
        if let actionID {
            return "action/\(actionID)"
        }
        return "session/\(sessionID)"
    }

    func jsonObject() -> [String: Any] {
        var data: [String: Any] = [
            "session_id": sessionID,
            "sequence": Int(sequence),
            "platform": "macos",
            "process_model": "in_daemon",
            "caller_category": "cua_runtime",
        ]
        if let actionID {
            data["action_id"] = actionID
        }
        if let capability {
            data["capability"] = capability
        }
        if !application.isEmpty {
            var app: [String: Any] = [:]
            if let bundleID = application.bundleID {
                app["bundle_id"] = bundleID
            }
            if let displayName = application.displayName {
                app["display_name"] = displayName
            }
            data["application"] = app
        }

        var payloadObject: [String: Any] = ["kind": payload.kind]
        switch payload {
        case let .control(operation):
            payloadObject["operation"] = operation
        case .actionStarted:
            break
        case let .actionCompleted(effect, route, deliveredCount):
            payloadObject["effect"] = effect
            if let route {
                payloadObject["route"] = route
            }
            payloadObject["delivery"] = "foreground"
            payloadObject["delivered_count"] = deliveredCount
        case let .session(phase):
            payloadObject["phase"] = phase
        case let .access(operation, returnedCount):
            payloadObject["operation"] = operation
            payloadObject["returned_count"] = returnedCount
        case let .health(category, droppedEvents):
            payloadObject["category"] = category
            payloadObject["dropped_events"] = droppedEvents
        }
        data["payload"] = payloadObject

        return [
            "specversion": "1.0",
            "id": id,
            "source": "urn:cua-driver:history:\(streamID)",
            "type": payload.eventType,
            "subject": subject,
            "time": Self.formatTime(time),
            "datacontenttype": "application/json",
            "dataschema": Self.dataSchema,
            "data": data,
        ]
    }

    func encodedJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(), options: [.sortedKeys])
    }

    static func decode(from data: Data) throws -> HistoryEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HistoryStoreError.storageCorrupt("event payload is not a JSON object")
        }
        guard object["specversion"] as? String == "1.0",
              object["dataschema"] as? String == dataSchema,
              let id = object["id"] as? String,
              let source = object["source"] as? String,
              source.hasPrefix("urn:cua-driver:history:"),
              let type = object["type"] as? String,
              let timeText = object["time"] as? String,
              let time = parseTime(timeText),
              let dataObject = object["data"] as? [String: Any],
              let sessionID = dataObject["session_id"] as? String,
              let sequenceNumber = dataObject["sequence"] as? NSNumber,
              sequenceNumber.int64Value >= 0,
              let payloadObject = dataObject["payload"] as? [String: Any],
              let kind = payloadObject["kind"] as? String
        else {
            throw HistoryStoreError.storageCorrupt("event fields failed validation")
        }

        let streamID = String(source.dropFirst("urn:cua-driver:history:".count))

        let payload: HistoryEventPayload
        switch kind {
        case "control":
            guard type == "cua-driver.history.control.v0",
                  let operation = payloadObject["operation"] as? String else {
                throw HistoryStoreError.storageCorrupt("control payload failed validation")
            }
            payload = .control(operation: operation)
        case "action_started":
            guard type == "cua-driver.history.action_started.v0" else {
                throw HistoryStoreError.storageCorrupt("action_started payload failed validation")
            }
            payload = .actionStarted
        case "action_completed":
            guard type == "cua-driver.history.action_completed.v0",
                  let effect = payloadObject["effect"] as? String,
                  let deliveredCount = payloadObject["delivered_count"] as? NSNumber else {
                throw HistoryStoreError.storageCorrupt("action_completed payload failed validation")
            }
            payload = .actionCompleted(
                effect: effect,
                route: payloadObject["route"] as? String,
                deliveredCount: deliveredCount.intValue
            )
        case "session":
            guard let phase = payloadObject["phase"] as? String,
                  type == (phase == "started"
                      ? "cua-driver.history.session_started.v0"
                      : "cua-driver.history.session_ended.v0") else {
                throw HistoryStoreError.storageCorrupt("session payload failed validation")
            }
            payload = .session(phase: phase)
        case "access":
            guard type == "cua-driver.history.access.v0",
                  let operation = payloadObject["operation"] as? String,
                  let returnedCount = payloadObject["returned_count"] as? NSNumber else {
                throw HistoryStoreError.storageCorrupt("access payload failed validation")
            }
            payload = .access(operation: operation, returnedCount: returnedCount.intValue)
        case "health":
            guard type == "cua-driver.history.health.v0",
                  let category = payloadObject["category"] as? String,
                  let dropped = payloadObject["dropped_events"] as? NSNumber else {
                throw HistoryStoreError.storageCorrupt("health payload failed validation")
            }
            payload = .health(category: category, droppedEvents: dropped.intValue)
        default:
            throw HistoryStoreError.storageCorrupt("unknown payload kind \(kind)")
        }

        var application = HistoryApplicationIdentity()
        if let appObject = dataObject["application"] as? [String: Any] {
            application.bundleID = appObject["bundle_id"] as? String
            application.displayName = appObject["display_name"] as? String
        }

        return HistoryEvent(
            id: id,
            streamID: streamID,
            sessionID: sessionID,
            actionID: dataObject["action_id"] as? String,
            sequence: sequenceNumber.uint64Value,
            time: time,
            capability: dataObject["capability"] as? String,
            application: application,
            payload: payload
        )
    }
}
