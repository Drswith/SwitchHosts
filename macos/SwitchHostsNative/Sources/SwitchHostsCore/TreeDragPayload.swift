import AppKit
import Foundation
import UniformTypeIdentifiers

/// The payload of a sidebar drag: the dragged entry's id. Reading the id from
/// the drop itself means no drag state outlives the drag.
public enum TreeDragPayload {
    /// A type only this app reads. Plain text would also drop into the editor
    /// (writing the id into an entry), and other apps' text would drop onto rows.
    public static let type = UTType(exportedAs: "net.oldj.switchhosts.native.entry-id")

    /// The dragged id carried by `provider`, or nil when it carries none.
    public static func id(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    /// The provider a sidebar row offers when it is dragged.
    public static func provider(for id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }
}
