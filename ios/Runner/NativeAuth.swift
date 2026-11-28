import AuthenticationServices
import CryptoKit
import Flutter
import Foundation
import Security
import UIKit

/// The native sign-in registration compiled into this build (core ADRs 0023 and 0029).
///
/// The values come from `Info.plist`. Every check compares raw, undecoded ASCII exactly, using
/// the same rules as the Android host and the Dart profile. Nothing here logs or retains a value
/// it refuses.
struct NativeAuthConfig {
  static let issuerKey = "OpenMettleNativeIssuer"
  static let clientIDKey = "OpenMettleNativeClientID"
  static let redirectKey = "OpenMettleNativeRedirectURI"
  static let authorizePath = "/auth/native/authorize"

  let issuer: String
  let clientID: String
  let redirect: String
  let redirectHost: String
  let redirectPath: String

  /// Nil for an unconfigured build (all values empty) or any unacceptable value. Callers treat
  /// both as "native sign-in unavailable".
  init?(configuration: [String: Any]) {
    guard let issuer = configuration[Self.issuerKey] as? String,
      let clientID = configuration[Self.clientIDKey] as? String,
      let redirect = configuration[Self.redirectKey] as? String
    else { return nil }
    self.init(issuer: issuer, clientID: clientID, redirect: redirect)
  }

  init?(issuer: String, clientID: String, redirect: String) {
    guard issuer.utf8.count <= maxURLLength, redirect.utf8.count <= maxURLLength,
      let issuerParts = fullMatch(issuerPattern, issuer),
      let redirectParts = fullMatch(redirectPattern, redirect),
      fullMatch(clientIDPattern, clientID) != nil,
      let issuerHost = issuerParts[1], let redirectHost = redirectParts[1],
      let redirectPath = redirectParts[2],
      issuerHost.utf8.count <= 253, redirectHost.utf8.count <= 253,
      !redirectPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return nil }
    if let port = issuerParts[2] {
      guard let value = Int(port), value <= 65535, value != 443 else { return nil }
    }
    self.issuer = issuer
    self.clientID = clientID
    self.redirect = redirect
    self.redirectHost = redirectHost
    self.redirectPath = redirectPath
  }

  /// True for exactly the registered HTTPS app link followed by a non-empty query and no
  /// fragment. Dart checks the query members against its attempt.
  func isCallback(_ raw: String) -> Bool {
    guard raw.utf8.count <= maxLinkLength, isVisibleASCII(raw), !raw.contains("#") else {
      return false
    }
    let prefix = redirect + "?"
    return raw.utf8.starts(with: prefix.utf8) && raw.utf8.count > prefix.utf8.count
  }

  /// True for the issuer's authorization URL carrying exactly the six ADR 0023 parameters, once
  /// each, for this registration's client ID and app link.
  func isAuthorizeRequest(_ raw: String) -> Bool {
    guard raw.utf8.count <= maxLinkLength, isVisibleASCII(raw), !raw.contains("#") else {
      return false
    }
    let prefix = issuer + Self.authorizePath + "?"
    guard raw.utf8.starts(with: prefix.utf8) else { return false }
    var params: [String: String] = [:]
    for pair in raw.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false) {
      guard let separator = pair.firstIndex(of: "=") else { return false }
      let name = String(pair[..<separator])
      guard authorizeParameters.contains(name),
        let value = String(pair[pair.index(after: separator)...]).removingPercentEncoding,
        params.updateValue(value, forKey: name) == nil
      else { return false }
    }
    return params.count == authorizeParameters.count
      && params["response_type"] == "code"
      && params["code_challenge_method"] == "S256"
      && params["client_id"] == clientID
      && params["redirect_uri"] == redirect
      && isProtocolToken(params["code_challenge"])
      && isProtocolToken(params["state"])
  }
}

/// PKCE and state values for one sign-in attempt (RFC 7636, S256).
enum Pkce {
  typealias RandomSource = (inout [UInt8]) -> Bool

  static let systemRandom: RandomSource = { bytes in
    SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
  }

  /// Independent 32-byte state and verifier and the verifier's S256 challenge, or nil when the
  /// random source fails.
  static func newAttempt(random: RandomSource = systemRandom) -> [String: String]? {
    var state = [UInt8](repeating: 0, count: 32)
    var verifier = [UInt8](repeating: 0, count: 32)
    guard random(&state), random(&verifier) else { return nil }
    let encodedVerifier = base64URL(verifier)
    return [
      "state": base64URL(state),
      "verifier": encodedVerifier,
      "challenge": challenge(encodedVerifier),
    ]
  }

  static func challenge(_ verifier: String) -> String {
    base64URL(SHA256.hash(data: Data(verifier.utf8)))
  }

  static func base64URL<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// At most one received callback link, held in memory only. A newer link replaces an older one,
/// a link is returned once, and a link older than `maxAge` seconds is discarded: the server's
/// code lasts at most 30 seconds (ADR 0023). `now` is a monotonic clock.
final class PendingLink {
  private let now: () -> ContinuousClock.Instant
  private let maxAge: Duration
  private let lock = NSLock()
  private var link: (raw: String, receivedAt: ContinuousClock.Instant)?

  init(
    now: @escaping () -> ContinuousClock.Instant = { .now },
    maxAge: Duration = .seconds(60)
  ) {
    self.now = now
    self.maxAge = maxAge
  }

  func offer(_ raw: String) {
    lock.lock()
    defer { lock.unlock() }
    link = (raw, now())
  }

  func take() -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let received = link else { return nil }
    link = nil
    let age = received.receivedAt.duration(to: now())
    return age >= .zero && age <= maxAge ? received.raw : nil
  }
}

/// The two native sign-in records, `attempt` and `session`, as private generic-password
/// Keychain items: available only while the device is unlocked, never synchronised and never
/// migrated to another device.
///
/// A stored value that is oversized or not UTF-8 is deleted and reads as absent. Every other
/// failure, including a locked device (`errSecInteractionNotAllowed`), throws and changes
/// nothing. Callers serialise access.
final class KeychainStore {
  static let names: Set<String> = ["attempt", "session"]
  static let maxValueBytes = 64 * 1024

  struct Failure: Error {
    let status: OSStatus
  }

  private let service: String
  private let installationDirectory: URL?
  private var installationReady = false

  convenience init() {
    self.init(
      service: "org.openmettle.app.native_auth.v1",
      installationDirectory: URL.applicationSupportDirectory.appendingPathComponent("NativeAuth")
    )
  }

  init(service: String, installationDirectory: URL? = nil) {
    self.service = service
    self.installationDirectory = installationDirectory
  }

  // Keychain items can outlive the app sandbox. Publish the non-backed-up marker only
  // after both old items are gone, so an interrupted first launch can retry safely.
  private func prepareInstallation() throws {
    guard !installationReady, var directory = installationDirectory else { return }
    let marker = directory.appendingPathComponent("installed")
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw CocoaError(.fileReadCorruptFile)
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      for name in Self.names { try delete(name) }
      try Data().write(to: marker, options: .atomic)
    }
    installationReady = true
  }

  func read(_ name: String) throws -> String? {
    try prepareInstallation()
    var query = baseQuery(name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = item as? Data, data.count <= Self.maxValueBytes,
      let value = String(data: data, encoding: .utf8)
    else {
      try write(name, nil)
      return nil
    }
    return value
  }

  /// Stores `value` under `name`, or deletes the record when `value` is nil.
  func write(_ name: String, _ value: String?) throws {
    try prepareInstallation()
    let query = baseQuery(name)
    guard let value else {
      return try delete(name)
    }
    let data = Data(value.utf8)
    guard data.count <= Self.maxValueBytes else { throw Failure(status: errSecParam) }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  private func delete(_ name: String) throws {
    let status = SecItemDelete(baseQuery(name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }

  private func baseQuery(_ name: String) -> [String: Any] {
    precondition(Self.names.contains(name))
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}

/// One presented browser sign-in that the channel can cancel.
protocol NativeAuthBrowserSession: AnyObject {
  func cancel()
}

/// Starts a browser sign-in for a validated authorization URL. Returns nil when no browser
/// session can be presented. `completion` receives the callback URL, or nil when the session
/// ended without one (cancelled, failed or dismissed), on any thread.
typealias NativeAuthBrowserLauncher = (
  _ url: URL,
  _ config: NativeAuthConfig,
  _ anchor: @escaping () -> UIWindow?,
  _ completion: @escaping (URL?) -> Void
) -> NativeAuthBrowserSession?

/// The `org.openmettle.app/native_auth` channel, the iOS counterpart of the Android host.
///
/// Errors carry fixed codes and messages and no details, so no secret, URL or system error text
/// reaches Dart or the log. `launchBrowser` returns once the system sign-in sheet is presented;
/// the outcome arrives later as `linkAvailable`. The channel is used on the main thread only.
final class NativeAuthChannel {
  static let name = "org.openmettle.app/native_auth"

  private let channel: FlutterMethodChannel
  private let presentationAnchor: () -> UIWindow?
  private let config: NativeAuthConfig?
  private let store: KeychainStore
  private let links: PendingLink
  private let launcher: NativeAuthBrowserLauncher
  private let storageQueue = DispatchQueue(label: "org.openmettle.app.native_auth.storage")
  private var active: (id: UInt64, session: NativeAuthBrowserSession)?
  private var generation: UInt64 = 0
  private var protectedDataObserver: NSObjectProtocol?

  convenience init(
    messenger: FlutterBinaryMessenger,
    presentationAnchor: @escaping () -> UIWindow?,
    configuration: [String: Any]
  ) {
    self.init(
      messenger: messenger,
      presentationAnchor: presentationAnchor,
      configuration: configuration,
      store: KeychainStore(),
      links: PendingLink(),
      launcher: systemBrowserLauncher
    )
  }

  init(
    messenger: FlutterBinaryMessenger,
    presentationAnchor: @escaping () -> UIWindow?,
    configuration: [String: Any],
    store: KeychainStore,
    links: PendingLink,
    launcher: @escaping NativeAuthBrowserLauncher
  ) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    self.presentationAnchor = presentationAnchor
    config = NativeAuthConfig(configuration: configuration)
    self.store = store
    self.links = links
    self.launcher = launcher
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
    // Dart serialises rechecks behind any pending call, including a Keychain failure
    // whose reply is still in flight at the instant the device unlocks.
    protectedDataObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.channel.invokeMethod("linkAvailable", arguments: nil)
    }
  }

  deinit {
    if let protectedDataObserver {
      NotificationCenter.default.removeObserver(protectedDataObserver)
    }
    channel.setMethodCallHandler(nil)
    active?.session.cancel()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "newAttempt":
      guard isEmpty(call.arguments) else { return refuse(result) }
      guard let attempt = Pkce.newAttempt() else {
        return result(FlutterError(code: "random_unavailable", message: randomText, details: nil))
      }
      result(attempt)
    case "readSecret":
      guard let args = arguments(call, allowed: ["key"]), let key = args["key"] as? String,
        KeychainStore.names.contains(key)
      else { return refuse(result) }
      storage(result) { try $0.read(key) }
    case "writeSecret":
      guard let args = arguments(call, allowed: ["key", "value"]),
        let key = args["key"] as? String, KeychainStore.names.contains(key)
      else { return refuse(result) }
      let value: String?
      switch args["value"] {
      case nil, is NSNull: value = nil
      case let text as String where text.utf8.count <= KeychainStore.maxValueBytes: value = text
      default: return refuse(result)
      }
      storage(result) {
        try $0.write(key, value)
        return nil
      }
    case "launchBrowser":
      launchBrowser(arguments(call, allowed: ["url"])?["url"], result: result)
    case "takeLink":
      guard isEmpty(call.arguments) else { return refuse(result) }
      result(links.take())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func launchBrowser(_ value: Any?, result: @escaping FlutterResult) {
    guard let config else {
      return result(FlutterError(code: "not_configured", message: notConfiguredText, details: nil))
    }
    guard let raw = value as? String, config.isAuthorizeRequest(raw), let url = URL(string: raw)
    else { return refuse(result) }
    // Dart serialises sign-in, so a new launch supersedes any earlier sheet. Forget it first so
    // its cancellation completes as stale and signals nothing.
    let previous = active
    active = nil
    previous?.session.cancel()
    generation &+= 1
    let id = generation
    let session = launcher(url, config, presentationAnchor) { [weak self] callback in
      let raw = callback?.absoluteString
      DispatchQueue.main.async { self?.finish(id, raw) }
    }
    guard let session else {
      return result(FlutterError(code: "browser_unavailable", message: noBrowserText, details: nil))
    }
    active = (id, session)
    result(nil)
  }

  /// Ends the current sheet. A valid callback is kept in memory for `takeLink`; every outcome
  /// of the current sheet signals Dart, which rechecks and leaves the screen signed out when no
  /// usable link arrived. A superseded sheet is ignored.
  private func finish(_ id: UInt64, _ raw: String?) {
    guard active?.id == id else { return }
    active = nil
    if let raw, let config, config.isCallback(raw) {
      links.offer(raw)
    }
    channel.invokeMethod("linkAvailable", arguments: nil)
  }

  private func storage(
    _ result: @escaping FlutterResult,
    _ operation: @escaping (KeychainStore) throws -> String?
  ) {
    let store = store
    storageQueue.async {
      let outcome = Result { try operation(store) }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let value):
          result(value)
        case .failure:
          result(FlutterError(code: "storage_unavailable", message: storageText, details: nil))
        }
      }
    }
  }

  private func refuse(_ result: FlutterResult) {
    result(FlutterError(code: "invalid_argument", message: invalidText, details: nil))
  }

  /// The argument map when it contains every required key exactly once.
  private func arguments(_ call: FlutterMethodCall, allowed: Set<String>) -> [String: Any]? {
    guard let args = call.arguments as? [String: Any],
      Set(args.keys) == allowed
    else { return nil }
    return args
  }

  private func isEmpty(_ arguments: Any?) -> Bool {
    arguments == nil || arguments is NSNull
  }
}

/// Presents `ASWebAuthenticationSession` with an HTTPS callback the system matches against the
/// app's associated domain (iOS 17.4 and later). There is no custom-scheme or embedded-view
/// fallback: older systems and a missing window refuse.
private let systemBrowserLauncher: NativeAuthBrowserLauncher = { url, config, anchor, completion in
  guard #available(iOS 17.4, *), let window = anchor() else { return nil }
  let provider = PresentationProvider(window: window)
  let session = ASWebAuthenticationSession(
    url: url,
    callback: .https(host: config.redirectHost, path: config.redirectPath)
  ) { callback, _ in
    completion(callback)
  }
  session.presentationContextProvider = provider
  // Share the system browser's state, as the Android host does, so provider single sign-on and
  // the user's saved credentials work.
  session.prefersEphemeralWebBrowserSession = false
  guard session.start() else { return nil }
  return SystemBrowserSession(session: session, provider: provider)
}

/// Keeps the presentation provider alive: the system session holds it weakly.
private final class SystemBrowserSession: NativeAuthBrowserSession {
  private let session: ASWebAuthenticationSession
  private let provider: PresentationProvider

  init(session: ASWebAuthenticationSession, provider: PresentationProvider) {
    self.session = session
    self.provider = provider
  }

  func cancel() {
    session.cancel()
  }
}

private final class PresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
  private let window: UIWindow

  init(window: UIWindow) {
    self.window = window
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window
  }
}

private let maxURLLength = 2048
private let maxLinkLength = 8192
private let invalidText = "native sign-in request refused"
private let notConfiguredText = "native sign-in is not configured"
private let noBrowserText = "no web browser is available"
private let storageText = "secure storage is unavailable"
private let randomText = "secure random source is unavailable"

private let authorizeParameters: Set<String> = [
  "response_type", "client_id", "redirect_uri", "code_challenge_method", "code_challenge", "state",
]

// These rules match the Android host and android/app/build.gradle.kts. Keep them in step.
private let dnsLabel = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
private let dnsHost = "\(dnsLabel)(?:\\.\(dnsLabel))*\\.[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
private let issuerPattern = regex("https://(\(dnsHost))(?::([1-9][0-9]{0,4}))?")
private let redirectPattern = regex("https://(\(dnsHost))((?:/[A-Za-z0-9._~-]+)+)")
private let clientIDPattern = regex("[A-Za-z0-9._-]{1,128}")
/// A canonical unpadded base64url encoding of exactly 32 bytes, as Dart requires.
private let protocolTokenPattern = regex("[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]")

private func regex(_ pattern: String) -> NSRegularExpression {
  // The patterns are constants; a failure is a programming error.
  try! NSRegularExpression(pattern: pattern)
}

/// The capture groups when `pattern` matches the whole of `value`, otherwise nil.
private func fullMatch(_ pattern: NSRegularExpression, _ value: String) -> [String?]? {
  guard isVisibleASCII(value) else { return nil }
  let whole = NSRange(value.startIndex..., in: value)
  guard let match = pattern.firstMatch(in: value, options: [.anchored], range: whole),
    match.range == whole
  else { return nil }
  return (0..<match.numberOfRanges).map { index in
    Range(match.range(at: index), in: value).map { String(value[$0]) }
  }
}

private func isProtocolToken(_ value: String?) -> Bool {
  guard let value, value.utf8.count == 43 else { return false }
  return fullMatch(protocolTokenPattern, value) != nil
}

private func isVisibleASCII(_ value: String) -> Bool {
  value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
}
