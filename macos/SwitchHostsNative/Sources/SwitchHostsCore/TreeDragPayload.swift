import AppKit
import Foundation

/// The payload of a sidebar drag: the dragged entry's id as plain text. Reading
/// the id from the drop itself means no drag state outlives the drag.
public enum TreeDragPayload {
    /// The dragged id carried by `provider`, or nil when it carries no text.
    public static func id(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { String($0) })
            }
        }
    }

    /// The provider a sidebar row offers when it is dragged.
    public static func provider(for id: String) -> NSItemProvider {
        NSItemProvider(object: id as NSString)
    }
}
