import AppKit

/// Reads only a native drag pasteboard, never a path supplied over a channel.
/// Admission here does not open files; the shared store validates each URL and
/// rolls back the complete new batch if any item is not an ordinary file.
public enum NativeFileDrop {
    public static func urls(from pasteboard: NSPasteboard) throws -> [URL] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            throw SelectedFileError.unavailable
        }
        guard items.count <= SelectedFileStore.maximumFiles else { throw SelectedFileError.limit }
        guard items.allSatisfy({ $0.types.contains(.fileURL) }),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == items.count,
              urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") &&
                  $0.query == nil && $0.fragment == nil }) else {
            throw SelectedFileError.unavailable
        }
        return urls
    }
}
