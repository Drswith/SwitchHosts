import CSwhFFI
import Foundation

/// An event pushed by the Rust core, such as `system_hosts_updated`.
/// `payload` is the raw JSON the core sent, including the `_args` envelope.
public struct SwhEvent: Sendable {
    public let name: String
    public let payload: Data
}

public enum SwhError: LocalizedError {
    case openFailed(String)
    case command(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return CoreText.localized(message)
        case .command(let message): return CoreText.localized(message)
        case .malformedResponse: return NSLocalizedString("The core returned an unexpected response.", comment: "")
        }
    }
}

/// One open hosts data root, backed by the Rust core.
///
/// `call` and `send` block a background thread while the core works, which
/// can be a long time when an apply is waiting for the OS authorization
/// prompt. They are safe to call from any task.
public final class SwhCore: @unchecked Sendable {
    /// Events from the core. Delivered in the order the core emits them.
    public let events: AsyncStream<SwhEvent>

    private let bridge: EventBridge
    private var handle: OpaquePointer?

    /// Opens `root`, or the default `~/.SwitchHosts` (honouring the data-dir
    /// pointer) when `root` is nil.
    public init(root: String? = nil) throws {
        let stream = AsyncStream.makeStream(of: SwhEvent.self)
        events = stream.stream
        bridge = EventBridge(continuation: stream.continuation)

        let user = Unmanaged.passUnretained(bridge).toOpaque()
        var errorText: UnsafeMutablePointer<CChar>?
        let opened: OpaquePointer?
        if let root {
            opened = root.withCString { swh_open($0, swhEventCallback, user, &errorText) }
        } else {
            opened = swh_open(nil, swhEventCallback, user, &errorText)
        }

        guard let opened else {
            let message = errorText.map { String(cString: $0) } ?? "Could not open the hosts data."
            if let errorText { swh_free_string(errorText) }
            stream.continuation.finish()
            throw SwhError.openFailed(message)
        }
        handle = opened
    }

    deinit {
        close()
    }

    /// Stops event delivery and frees the core. Call only when no command is
    /// in flight. Calls made afterwards throw.
    public func close() {
        guard let handle else { return }
        self.handle = nil
        swh_close(handle)
        bridge.continuation.finish()
    }

    /// Runs `command` and decodes its value. A `null` result throws.
    public func call<T: Decodable>(_ type: T.Type, _ command: String, _ args: [Any] = []) async throws -> T {
        let data = try await perform(command, args)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if !envelope.ok {
            throw SwhError.command(envelope.error ?? "Unknown error")
        }
        guard let value = envelope.value else {
            throw SwhError.malformedResponse
        }
        return value
    }

    /// Runs `command` and returns its value as untyped JSON. Used where the
    /// caller edits the tree and must keep fields this app does not model.
    public func json(_ command: String, _ args: [Any] = []) async throws -> Any {
        let data = try await perform(command, args)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let envelope = object as? [String: Any] else {
            throw SwhError.malformedResponse
        }
        if envelope["ok"] as? Bool != true {
            throw SwhError.command(envelope["error"] as? String ?? "Unknown error")
        }
        return envelope["value"] ?? NSNull()
    }

    /// Runs `command` for its side effects and ignores the result.
    public func send(_ command: String, _ args: [Any] = []) async throws {
        let data = try await perform(command, args)
        let envelope = try JSONDecoder().decode(Envelope<Discarded>.self, from: data)
        if !envelope.ok {
            throw SwhError.command(envelope.error ?? "Unknown error")
        }
    }

    // ---- internals ---------------------------------------------------------

    private func perform(_ command: String, _ args: [Any]) async throws -> Data {
        guard let handle else {
            throw SwhError.command("The hosts core is closed.")
        }
        let argsData = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
        let argsText = String(decoding: argsData, as: UTF8.self)
        let box = HandleBox(raw: handle)

        return try await Task.detached(priority: .userInitiated) { () -> Data in
            guard let raw = swh_invoke(box.raw, command, argsText) else {
                throw SwhError.malformedResponse
            }
            let text = String(cString: raw)
            swh_free_string(raw)
            return Data(text.utf8)
        }.value
    }
}

// ---- C callback bridge -----------------------------------------------------

/// Holds the continuation the C callback yields into. Kept alive by `SwhCore`.
private final class EventBridge: @unchecked Sendable {
    let continuation: AsyncStream<SwhEvent>.Continuation

    init(continuation: AsyncStream<SwhEvent>.Continuation) {
        self.continuation = continuation
    }
}

/// Carries the raw handle into the detached task. The core is thread-safe
/// for `swh_invoke`, and `SwhCore` only frees it after calls have finished.
private struct HandleBox: @unchecked Sendable {
    let raw: OpaquePointer
}

private let swhEventCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = {
    user, event, payload in
    guard let user, let event, let payload else { return }
    let bridge = Unmanaged<EventBridge>.fromOpaque(user).takeUnretainedValue()
    bridge.continuation.yield(
        SwhEvent(name: String(cString: event), payload: Data(String(cString: payload).utf8))
    )
}

// ---- envelope --------------------------------------------------------------

private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let value: T?
    let error: String?
}

/// Decodes any JSON value and throws it away.
private struct Discarded: Decodable {
    init(from decoder: Decoder) throws {}
}
