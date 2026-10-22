import Foundation

/// Minimal logging that stays out of the hot path when disabled.
///
/// Deliberately dependency-free: no `os`, no `oslog`, so the same file compiles
/// in the Linux type-check harness (`Scripts/dev/verify_core.sh`).
public enum AppLog {
    public enum Level: String { case debug, info, warn, error }

    public static var minimumLevel: Level = .info
    private static let queue = DispatchQueue(label: "app.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func debug(_ message: @autoclosure () -> String, _ file: String = #fileID, _ line: Int = #line) {
        emit(.debug, message(), file, line)
    }

    public static func info(_ message: @autoclosure () -> String, _ file: String = #fileID, _ line: Int = #line) {
        emit(.info, message(), file, line)
    }

    public static func warn(_ message: @autoclosure () -> String, _ file: String = #fileID, _ line: Int = #line) {
        emit(.warn, message(), file, line)
    }

    public static func error(_ message: @autoclosure () -> String, _ file: String = #fileID, _ line: Int = #line) {
        emit(.error, message(), file, line)
    }

    private static let order: [Level] = [.debug, .info, .warn, .error]

    private static func emit(_ level: Level, _ message: String, _ file: String, _ line: Int) {
        guard let minIndex = order.firstIndex(of: minimumLevel),
              let levelIndex = order.firstIndex(of: level),
              levelIndex >= minIndex else { return }
        let stamp = formatter.string(from: Date())
        let name = file.split(separator: "/").last.map(String.init) ?? file
        queue.async {
            FileHandle.standardError.write(Data("[\(stamp)] \(level.rawValue.uppercased()) \(name):\(line) \(message)\n".utf8))
        }
    }
}
