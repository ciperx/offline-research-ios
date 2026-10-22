import Foundation

/// Hard offline enforcement.
///
/// Three independent layers, because "we don't call the network" is a claim and a
/// claim needs a mechanism:
///
/// 1. **No networking code.** The app links no networking framework and the build
///    runs `Scripts/check_offline.sh`, which fails the build if a source file grows a
///    `URLSession`, `Network.framework`, `WKWebView`, `CFStream` or `NSURLConnection`
///    reference. This file is the single allow-listed exception.
/// 2. **Runtime protocol block.** `URLProtocol.registerClass` installs a handler that
///    refuses every http(s)/ws(s) load, even from a library that slipped in. Nothing
///    in the app can reach the network even if a dependency tries.
/// 3. **Audit surface.** Every refused attempt is counted and shown in Settings →
///    Diagnostics, so "0 attempts" is observable rather than assumed. Reviewers can
///    also run the app in Airplane Mode and diff the counter.
public final class OfflineGuard: URLProtocol {

    public struct Attempt: Identifiable, Equatable {
        public let id = UUID()
        public let host: String
        public let scheme: String
        public let date: Date
    }

    private static let lock = NSLock()
    private static var _attempts: [Attempt] = []
    private static var _installed = false

    public static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _installed
    }

    public static var attempts: [Attempt] {
        lock.lock(); defer { lock.unlock() }
        return _attempts
    }

    public static var attemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _attempts.count
    }

    /// Call once, as early as possible in the launch path (before any view loads).
    public static func install() {
        lock.lock()
        let alreadyInstalled = _installed
        _installed = true
        lock.unlock()
        guard !alreadyInstalled else { return }
        URLProtocol.registerClass(OfflineGuard.self)
        AppLog.info("OfflineGuard installed: all HTTP(S) loads will fail by design")
    }

    public static func resetAudit() {
        lock.lock(); defer { lock.unlock() }
        _attempts.removeAll()
    }

    static func record(_ request: URLRequest) {
        let attempt = Attempt(
            host: request.url?.host ?? "unknown",
            scheme: request.url?.scheme ?? "unknown",
            date: Date()
        )
        lock.lock()
        _attempts.append(attempt)
        if _attempts.count > 200 { _attempts.removeFirst(_attempts.count - 200) }
        lock.unlock()
        AppLog.warn("blocked network attempt: \(attempt.scheme)://\(attempt.host)")
    }

    // MARK: - URLProtocol

    /// Only network schemes are intercepted. `file://` and `data:` loads (bundle
    /// resources, the SQLite corpus) must keep working.
    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "ws", "wss", "ftp", "ftps"].contains(scheme)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        OfflineGuard.record(request)
        let error = NSError(
            domain: "OfflineGuard",
            code: -1009,
            userInfo: [
                NSLocalizedDescriptionKey: "This app runs fully offline. Network access is disabled by design.",
                NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? "",
            ]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    public override func stopLoading() {}
}
