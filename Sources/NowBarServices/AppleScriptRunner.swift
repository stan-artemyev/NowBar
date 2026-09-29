import Foundation

/// A `Sendable` copy of an Apple event descriptor's value, so results can leave the script queue.
enum ScriptValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case text(String)
    case data(Data)
    case list([ScriptValue])
}

extension ScriptValue {
    /// Converts a descriptor by its type. Numbers are read as doubles and booleans as booleans, never through
    /// text, so the user's decimal separator can't matter.
    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
        case typeNull:
            self = .null
        case typeType:
            // `missing value` inside a list or as a return value is the type constant 'msng'.
            self = descriptor.typeCodeValue == fourCharCode("msng") ? .null : .data(descriptor.data)
        case typeBoolean, typeTrue, typeFalse:
            self = .bool(descriptor.booleanValue)
        case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint,
             typeSInt16, typeSInt32, typeSInt64, typeUInt16, typeUInt32, typeUInt64:
            self = .number(descriptor.doubleValue)
        case typeUnicodeText, typeUTF8Text, typeChar:
            self = .text(descriptor.stringValue ?? "")
        case typeAEList:
            let items = stride(from: 1, through: descriptor.numberOfItems, by: 1).map { index in
                descriptor.atIndex(index).map(ScriptValue.init) ?? .null
            }
            self = .list(items)
        default:
            // Pictures and raw data: the payload is the image file's bytes.
            self = .data(descriptor.data)
        }
    }
}

/// An argument for a handler, converted to a typed descriptor on the script queue.
enum ScriptArgument: Sendable, Equatable {
    case number(Double)
    case bool(Bool)
    case text(String)

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .number(let value): return NSAppleEventDescriptor(double: value)
        case .bool(let value): return NSAppleEventDescriptor(boolean: value)
        case .text(let value): return NSAppleEventDescriptor(string: value)
        }
    }
}

struct ScriptError: Error, Sendable, Equatable {
    var number: Int
    var message: String

    init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    /// Reads NSAppleScript's error dictionary.
    init(info: NSDictionary?) {
        let raw = info?[NSAppleScript.errorNumber]
        number = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? "") ?? -1
        message = info?[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
    }
}

struct ScriptResult: Sendable {
    /// What the handler returned (`.null` for `missing value` or no return value, and after a failure).
    var value: ScriptValue
    var error: ScriptError?
    /// When the script finished, on the script queue (closer to when Music was read than the moment the
    /// result reaches the main actor).
    var finishedAt: Date
}

/// Runs AppleScript handlers on one private serial queue, never on the main thread: Music can stall.
///
/// The queue is shared by every runner in the process: in tests, scripts run from several queues at once
/// failed with "invalid script ID" (error -1751), so the AppleScript engine is only ever driven from this one.
///
/// Scripts are compiled on first use and cached by source text. Handlers are called with a subroutine
/// event, so arguments travel as typed descriptors (a real stays a real) instead of being formatted into
/// script text, which would depend on the locale and force a recompile for every call.
final class AppleScriptRunner: @unchecked Sendable {
    private static let sharedQueue = DispatchQueue(label: "com.nowbar.services.applescript", qos: .userInitiated)

    private let queue = AppleScriptRunner.sharedQueue
    /// Compiled scripts keyed by source. Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    init() {}

    /// Runs `work` on the script queue and resumes with its result. Used for anything that may block for a
    /// while, such as the Automation permission prompt.
    func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Calls `handler` of the script `source` with `arguments`.
    func call(_ handler: String, in source: String, arguments: [ScriptArgument] = []) async -> ScriptResult {
        await perform { self.execute(handler: handler, source: source, arguments: arguments) }
    }

    private func execute(handler: String, source: String, arguments: [ScriptArgument]) -> ScriptResult {
        dispatchPrecondition(condition: .onQueue(queue))

        func failure(_ error: ScriptError) -> ScriptResult {
            ScriptResult(value: .null, error: error, finishedAt: Date())
        }

        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return failure(ScriptError(number: -2700, message: "The script could not be created."))
            }
            var info: NSDictionary?
            guard fresh.compileAndReturnError(&info) else { return failure(ScriptError(info: info)) }
            compiled[source] = fresh
            script = fresh
        }

        var info: NSDictionary?
        let descriptor = script.executeAppleEvent(Self.subroutineEvent(handler, arguments), error: &info)
        let finishedAt = Date()
        if info != nil { return failure(ScriptError(info: info)) }
        return ScriptResult(value: ScriptValue(descriptor), error: nil, finishedAt: finishedAt)
    }

    /// The event AppleScript uses to call a handler: class 'ascr', ID 'psbr', the handler's name (lowercase)
    /// in 'snam' and the arguments as the direct-object list.
    static func subroutineEvent(_ handler: String, _ arguments: [ScriptArgument]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: fourCharCode("ascr"),
            eventID: fourCharCode("psbr"),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: fourCharCode("snam"))
        let list = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            list.insert(argument.descriptor, at: offset + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }
}

func fourCharCode(_ string: String) -> FourCharCode {
    precondition(string.utf8.count == 4, "a four-character code has exactly four characters")
    return string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
