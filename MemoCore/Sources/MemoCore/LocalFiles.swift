import Foundation

/// Directory enumeration may return URLs relative to a base URL. Compare resolved
/// filesystem paths, not URL representations, before routing or removing a file.
public enum LocalFiles {
    public static func path(_ url: URL) -> String {
        var value = url.standardizedFileURL.resolvingSymlinksInPath().path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
    public static func contains(_ file: URL, in directory: URL, recursive: Bool = false) -> Bool {
        guard file.isFileURL, directory.isFileURL else { return false }
        let root = path(directory), target = path(file)
        if recursive { return target.hasPrefix(root.hasSuffix("/") ? root : root + "/") && target != root }
        return path(file.deletingLastPathComponent()) == root && target.hasPrefix(root + "/")
    }
    public static func remove(_ file: URL, in directory: URL, recursive: Bool = false) throws {
        guard contains(file, in:directory, recursive:recursive) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at:file)
    }
}
