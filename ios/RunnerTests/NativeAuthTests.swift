import Flutter
import Security
import UIKit
import XCTest

@testable import Runner

// Synthetic, reserved test names only.
private let issuer = "https://app.example.test"
private let clientID = "openmettle-ios"
private let redirect = "https://links.example.test/native/complete"
private let encodedRedirect = "https%3A%2F%2Flinks.example.test%2Fnative%2Fcomplete"
private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
private let state = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private let callback = "\(redirect)?code=\(challenge)&state=\(state)&iss=\(issuer)"

private let configuration: [String: Any] = [
  NativeAuthConfig.issuerKey: issuer,
  NativeAuthConfig.clientIDKey: clientID,
  NativeAuthConfig.redirectKey: redirect,
]

private func authorize(
  base: String = "\(issuer)/auth/native/authorize",
  client: String = clientID,
  redirect: String = encodedRedirect,
  challenge: String = challenge,
  state: String = state,
  extra: String = ""
) -> String {
  "\(base)?response_type=code&client_id=\(client)&redirect_uri=\(redirect)"
    + "&code_challenge_method=S256&code_challenge=\(challenge)&state=\(state)\(extra)"
}

final class NativeAuthConfigTests: XCTestCase {
  private let config = NativeAuthConfig(issuer: issuer, clientID: clientID, redirect: redirect)!

  func testUnconfiguredAndInvalidSettingsDisableSignIn() {
    XCTAssertNil(NativeAuthConfig(configuration: [:]))
    XCTAssertNil(NativeAuthConfig(issuer: "", clientID: "", redirect: ""))
    XCTAssertNil(
      NativeAuthConfig(configuration: configuration.merging([NativeAuthConfig.issuerKey: 1]) { $1 }))
    XCTAssertNotNil(NativeAuthConfig(configuration: configuration))
    let refused: [(String, String, String)] = [
      (issuer, clientID, ""),
      ("", clientID, redirect),
      (issuer, "", redirect),
      (issuer, "bad id", redirect),
      (issuer, String(repeating: "a", count: 129), redirect),
      ("http://app.example.test", clientID, redirect),
      ("https://app.example.test/", clientID, redirect),
      ("https://APP.example.test", clientID, redirect),
      ("https://app.example.test:443", clientID, redirect),
      ("https://app.example.test:0", clientID, redirect),
      ("https://app.example.test:08443", clientID, redirect),
      ("https://app.example.test:65536", clientID, redirect),
      ("https://user@app.example.test", clientID, redirect),
      ("https://192.0.2.1", clientID, redirect),
      ("https://localhost", clientID, redirect),
      ("https://app.example.test\n", clientID, redirect),
      ("https://äpp.example.test", clientID, redirect),
      (issuer, clientID, "https://links.example.test"),
      (issuer, clientID, "https://links.example.test/"),
      (issuer, clientID, "https://links.example.test/native/"),
      (issuer, clientID, "https://links.example.test//native"),
      (issuer, clientID, "https://links.example.test/native/../x"),
      (issuer, clientID, "https://links.example.test/./x"),
      (issuer, clientID, "https://links.example.test:8443/native"),
      (issuer, clientID, "https://links.example.test/native?x=1"),
      (issuer, clientID, "https://links.example.test/native#x"),
      (issuer, clientID, "https://links.example.test/na%2Ftive"),
      (issuer, clientID, "http://links.example.test/native"),
      (issuer, clientID, "\(redirect)\n"),
    ]
    for (issuer, clientID, redirect) in refused {
      XCTAssertNil(
        NativeAuthConfig(issuer: issuer, clientID: clientID, redirect: redirect),
        "\(issuer) \(clientID) \(redirect)")
    }
    let ported = NativeAuthConfig(
      issuer: "https://app.example.test:8443", clientID: clientID, redirect: redirect)
    XCTAssertNotNil(ported)
    XCTAssertEqual(config.redirectHost, "links.example.test")
    XCTAssertEqual(config.redirectPath, "/native/complete")
  }

  func testCallbackMustMatchTheRegisteredLinkExactly() {
    XCTAssertTrue(config.isCallback(callback))
    let refused = [
      redirect,
      "\(redirect)?",
      "\(redirect)?code=a#",
      "\(redirect)?code=a#frag",
      "\(redirect)?code=a b",
      "\(redirect)?code=\u{e9}",
      "HTTPS://links.example.test/native/complete?code=a",
      "http://links.example.test/native/complete?code=a",
      "https://LINKS.example.test/native/complete?code=a",
      "https://links.example.test:443/native/complete?code=a",
      "https://user@links.example.test/native/complete?code=a",
      "https://links.example.test/native/complete/?code=a",
      "https://links.example.test/native/complete/x?code=a",
      "https://links.example.test/native/Complete?code=a",
      "https://links.example.test/native/%63omplete?code=a",
      "https://links.example.test.evil.test/native/complete?code=a",
      "https://app.example.test/native/complete?code=a",
      "\(redirect)?code=\(String(repeating: "a", count: 8192))",
    ]
    for link in refused {
      XCTAssertFalse(config.isCallback(link), link)
    }
  }

  func testAuthorizeRequestMustCarryExactlyThisRegistration() {
    XCTAssertTrue(config.isAuthorizeRequest(authorize()))
    let token = String(repeating: "B", count: 42) + "w"
    XCTAssertTrue(config.isAuthorizeRequest(authorize(challenge: token, state: token)))
    let refused = [
      authorize(base: "http://app.example.test/auth/native/authorize"),
      authorize(base: "https://app.example.test:8443/auth/native/authorize"),
      authorize(base: "https://APP.example.test/auth/native/authorize"),
      authorize(base: "https://other.example.test/auth/native/authorize"),
      authorize(base: "\(issuer)/auth/native/authorize/"),
      authorize(base: "\(issuer)/auth/login"),
      authorize(client: "openmettle-android"),
      authorize(redirect: "https%3A%2F%2Flinks.example.test%2Fnative%2Fother"),
      authorize(redirect: "https%3A%2F%2Fevil.example.test%2Fnative%2Fcomplete"),
      authorize(redirect: "https%3A%2F%2Flinks.example.test%2Fnative%2Fcomplete%3F"),
      authorize(challenge: "short"),
      authorize(challenge: challenge + "A"),
      authorize(state: String(repeating: "A", count: 42) + "B"),
      authorize(state: "%ZZ"),
      authorize(extra: "&state=\(state)"),
      authorize(extra: "&prompt=login"),
      authorize(extra: "&"),
      authorize(extra: "#frag"),
      authorize().replacingOccurrences(of: "&state=\(state)", with: ""),
      authorize().replacingOccurrences(of: "S256", with: "plain"),
      authorize().replacingOccurrences(of: "response_type=code", with: "response_type=token"),
      authorize().replacingOccurrences(of: "response_type=code", with: "response_type"),
      authorize(extra: "&x=" + String(repeating: "a", count: 8192)),
      "\(issuer)/auth/native/authorize",
    ]
    for url in refused {
      XCTAssertFalse(config.isAuthorizeRequest(url), url)
    }
  }
}

final class PkceTests: XCTestCase {
  func testChallengeMatchesRfc7636Vector() {
    XCTAssertEqual(Pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), challenge)
  }

  func testAttemptUsesIndependentDrawsAndCanonicalTokens() throws {
    var draw: UInt8 = 0
    let attempt = try XCTUnwrap(
      Pkce.newAttempt { bytes in
        draw += 1
        bytes = [UInt8](repeating: draw, count: bytes.count)
        return true
      })
    XCTAssertEqual(draw, 2)
    XCTAssertEqual(attempt["state"], Pkce.base64URL([UInt8](repeating: 1, count: 32)))
    XCTAssertEqual(attempt["verifier"], Pkce.base64URL([UInt8](repeating: 2, count: 32)))
    XCTAssertEqual(attempt["challenge"], Pkce.challenge(attempt["verifier"]!))
    XCTAssertEqual(Set(attempt.keys), ["state", "verifier", "challenge"])

    let config = NativeAuthConfig(issuer: issuer, clientID: clientID, redirect: redirect)!
    let system = try XCTUnwrap(Pkce.newAttempt())
    XCTAssertNotEqual(system["state"], system["verifier"])
    XCTAssertTrue(
      config.isAuthorizeRequest(authorize(challenge: system["challenge"]!, state: system["state"]!)))
    XCTAssertTrue(config.isAuthorizeRequest(authorize(challenge: system["verifier"]!)))
  }

  func testRandomFailureYieldsNoAttempt() {
    XCTAssertNil(Pkce.newAttempt { _ in false })
  }
}

final class PendingLinkTests: XCTestCase {
  func testLinkIsReturnedOnceReplacedAndExpired() {
    var now = ContinuousClock.now
    let links = PendingLink(now: { now })
    XCTAssertNil(links.take())
    links.offer("first")
    links.offer("second")
    XCTAssertEqual(links.take(), "second")
    XCTAssertNil(links.take())

    links.offer("late")
    now += .milliseconds(60_500)
    XCTAssertNil(links.take())

    links.offer("skewed")
    now -= .seconds(1)
    XCTAssertNil(links.take())
  }
}

/// Exercises the real Keychain in the hosted simulator test process, with a unique service per
/// test so nothing touches the app's own items.
final class KeychainStoreTests: XCTestCase {
  private var service = ""
  private var store: KeychainStore!

  override func setUp() {
    super.setUp()
    service = "org.openmettle.app.native_auth.test.\(UUID().uuidString)"
    store = KeychainStore(service: service)
  }

  override func tearDown() {
    SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        as CFDictionary)
    super.tearDown()
  }

  func testCreateReadUpdateDeleteLifecycle() throws {
    XCTAssertNil(try store.read("attempt"))
    try store.write("attempt", "{\"state\":\"one\"}")
    XCTAssertEqual(try store.read("attempt"), "{\"state\":\"one\"}")
    try store.write("attempt", "{\"state\":\"two\"}")
    XCTAssertEqual(try store.read("attempt"), "{\"state\":\"two\"}")
    XCTAssertNil(try store.read("session"))
    try store.write("session", "bearer")

    try store.write("attempt", nil)
    XCTAssertNil(try store.read("attempt"))
    try store.write("attempt", nil)
    XCTAssertEqual(try store.read("session"), "bearer")

    // A second store on the same service sees the same items, as after an app restart.
    XCTAssertEqual(try KeychainStore(service: service).read("session"), "bearer")
    XCTAssertNil(try KeychainStore(service: service + ".other").read("session"))
  }

  func testItemsAreThisDeviceOnlyWhenUnlockedAndNotSynchronised() throws {
    try store.write("session", "first")
    try store.write("session", "second")
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
      ] as CFDictionary, &result)
    XCTAssertEqual(status, errSecSuccess)
    let items = try XCTUnwrap(result as? [[String: Any]])
    XCTAssertEqual(items.count, 1)
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item[kSecAttrAccount as String] as? String, "session")
    XCTAssertEqual(
      item[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    XCTAssertNotEqual(item[kSecAttrSynchronizable as String] as? Bool, true)
  }

  func testOversizedWriteFailsAndKeepsTheStoredValue() throws {
    try store.write("attempt", "kept")
    XCTAssertThrowsError(
      try store.write("attempt", String(repeating: "x", count: KeychainStore.maxValueBytes + 1)))
    XCTAssertEqual(try store.read("attempt"), "kept")
    try store.write("attempt", String(repeating: "x", count: KeychainStore.maxValueBytes))
  }

  func testMalformedItemIsDiscarded() throws {
    let status = SecItemAdd(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "session",
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecValueData as String: Data([0xFF, 0xFE]),
      ] as CFDictionary, nil)
    XCTAssertEqual(status, errSecSuccess)
    XCTAssertNil(try store.read("session"))
    try store.write("session", "fresh")
    XCTAssertEqual(try store.read("session"), "fresh")
  }

  func testRestartKeepsRecordsAndReinstallDiscardsBothRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = KeychainStore(service: service, installationDirectory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try first.write("session", "old session")
    try first.write("attempt", "old attempt")
    let restarted = KeychainStore(service: service, installationDirectory: directory)
    XCTAssertEqual(try restarted.read("session"), "old session")
    XCTAssertEqual(try restarted.read("attempt"), "old attempt")
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    // Simulate removal of this installation's sandbox while its Keychain items survive.
    try FileManager.default.removeItem(at: directory)
    let reinstalled = KeychainStore(service: service, installationDirectory: directory)
    XCTAssertNil(try reinstalled.read("session"))
    XCTAssertNil(try reinstalled.read("attempt"))
  }

  func testInaccessibleInstallationMarkerPreservesKeychainRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A directory at the marker path is an error, not evidence of a new installation.
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("installed"), withIntermediateDirectories: false)
    try store.write("session", "kept")
    let reopened = KeychainStore(service: service, installationDirectory: directory)
    XCTAssertThrowsError(try reopened.read("session"))
    XCTAssertEqual(try store.read("session"), "kept")
  }
}

final class NativeAuthChannelTests: XCTestCase {
  private var service = ""
  private var messenger: FakeMessenger!
  private var launches: [FakeLaunch] = []
  private var launcherReturnsSession = true
  private var channel: NativeAuthChannel!

  override func setUp() {
    super.setUp()
    service = "org.openmettle.app.native_auth.test.\(UUID().uuidString)"
    messenger = FakeMessenger()
    launches = []
    launcherReturnsSession = true
    channel = makeChannel(configuration)
  }

  override func tearDown() {
    channel = nil
    SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        as CFDictionary)
    super.tearDown()
  }

  private func makeChannel(_ configuration: [String: Any]) -> NativeAuthChannel {
    NativeAuthChannel(
      messenger: messenger,
      presentationAnchor: { nil },
      configuration: configuration,
      store: KeychainStore(service: service),
      links: PendingLink(),
      launcher: { [unowned self] url, config, _, completion in
        let launch = FakeLaunch(
          url: url, host: config.redirectHost, path: config.redirectPath, completion: completion)
        self.launches.append(launch)
        return self.launcherReturnsSession ? launch : nil
      })
  }

  private func invoke(_ method: String, _ arguments: Any? = nil) -> Reply {
    let done = expectation(description: method)
    var reply = Reply.notImplemented
    let message = FlutterStandardMethodCodec.sharedInstance().encode(
      FlutterMethodCall(methodName: method, arguments: arguments))
    messenger.receive(message) { data in
      reply = Reply(data)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return reply
  }

  /// Runs every main-queue block queued so far, such as a session completion.
  private func drainMain() {
    let done = expectation(description: "main queue")
    DispatchQueue.main.async { done.fulfill() }
    wait(for: [done], timeout: 5)
  }

  func testAttemptAndArgumentShapes() throws {
    var value: Any?
    channel.handle(FlutterMethodCall(methodName: "newAttempt", arguments: nil)) { value = $0 }
    let attempt = try XCTUnwrap(value as? [String: String])
    XCTAssertEqual(attempt["challenge"], Pkce.challenge(attempt["verifier"]!))
    XCTAssertEqual(invoke("newAttempt", ["x": 1]), .error("invalid_argument"))
    XCTAssertEqual(invoke("takeLink", ["x": 1]), .error("invalid_argument"))
    XCTAssertEqual(invoke("readSecret", ["key": "other"]), .error("invalid_argument"))
    XCTAssertEqual(invoke("readSecret", ["key": "session", "x": 1]), .error("invalid_argument"))
    XCTAssertEqual(invoke("writeSecret", ["key": "session", "value": 1]), .error("invalid_argument"))
    XCTAssertEqual(
      invoke(
        "writeSecret",
        ["key": "session", "value": String(repeating: "x", count: KeychainStore.maxValueBytes + 1)]),
      .error("invalid_argument"))
    XCTAssertEqual(invoke("launchBrowser", "url"), .error("invalid_argument"))
    XCTAssertEqual(invoke("unknown"), .notImplemented)
  }

  func testSecretsRoundTripThroughTheKeychain() {
    XCTAssertEqual(invoke("readSecret", ["key": "attempt"]), .success(nil))
    XCTAssertEqual(invoke("writeSecret", ["key": "attempt", "value": "record"]), .success(nil))
    XCTAssertEqual(invoke("writeSecret", ["key": "attempt"]), .error("invalid_argument"))
    XCTAssertEqual(invoke("readSecret", ["key": "attempt"]), .success("record"))
    XCTAssertEqual(invoke("writeSecret", ["key": "attempt", "value": NSNull()]), .success(nil))
    XCTAssertEqual(invoke("readSecret", ["key": "attempt"]), .success(nil))
  }

  func testUnlockAlwaysRequestsASerialSessionRecheck() {
    NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    XCTAssertEqual(messenger.sent, ["linkAvailable"])
  }

  func testUnconfiguredBuildRefusesSignIn() {
    channel = makeChannel([:])
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .error("not_configured"))
    XCTAssertTrue(launches.isEmpty)
  }

  func testInvalidAuthorizationRequestNeverLaunches() {
    XCTAssertEqual(
      invoke("launchBrowser", ["url": authorize(client: "other")]), .error("invalid_argument"))
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize(), "x": 1]), .error("invalid_argument"))
    XCTAssertTrue(launches.isEmpty)
  }

  func testUnavailableBrowserIsReported() {
    launcherReturnsSession = false
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .error("browser_unavailable"))
    launches[0].completion(URL(string: callback))
    drainMain()
    XCTAssertTrue(messenger.sent.isEmpty)
  }

  func testLaunchReturnsBeforeCompletionAndCallbackIsTakenOnce() {
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    XCTAssertEqual(launches.count, 1)
    XCTAssertEqual(launches[0].url.absoluteString, authorize())
    XCTAssertEqual(launches[0].host, "links.example.test")
    XCTAssertEqual(launches[0].path, "/native/complete")
    XCTAssertTrue(messenger.sent.isEmpty)

    launches[0].completion(URL(string: callback))
    drainMain()
    XCTAssertEqual(messenger.sent, ["linkAvailable"])
    XCTAssertEqual(invoke("takeLink"), .success(callback))
    XCTAssertEqual(invoke("takeLink"), .success(nil))

    // A duplicate completion of a finished sheet is ignored.
    launches[0].completion(URL(string: callback))
    drainMain()
    XCTAssertEqual(messenger.sent, ["linkAvailable"])
    XCTAssertEqual(invoke("takeLink"), .success(nil))
  }

  func testCancellationAndForeignCallbackSignalWithoutALink() {
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    launches[0].completion(nil)
    drainMain()
    XCTAssertEqual(messenger.sent, ["linkAvailable"])
    XCTAssertEqual(invoke("takeLink"), .success(nil))

    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    launches[1].completion(
      URL(string: "https://evil.example.test/native/complete?code=\(challenge)&state=\(state)"))
    drainMain()
    XCTAssertEqual(messenger.sent, ["linkAvailable", "linkAvailable"])
    XCTAssertEqual(invoke("takeLink"), .success(nil))
  }

  func testNewLaunchSupersedesAnEarlierSheet() {
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    XCTAssertTrue(launches[0].cancelled)
    XCTAssertFalse(launches[1].cancelled)

    launches[0].completion(URL(string: callback))
    drainMain()
    XCTAssertTrue(messenger.sent.isEmpty)
    XCTAssertEqual(invoke("takeLink"), .success(nil))

    launches[1].completion(URL(string: callback))
    drainMain()
    XCTAssertEqual(messenger.sent, ["linkAvailable"])
    XCTAssertEqual(invoke("takeLink"), .success(callback))
  }

  func testCompletionAfterTheChannelIsReleasedIsIgnored() {
    XCTAssertEqual(invoke("launchBrowser", ["url": authorize()]), .success(nil))
    let launch = launches[0]
    channel = nil
    XCTAssertTrue(launch.cancelled)
    launch.completion(URL(string: callback))
    drainMain()
    XCTAssertTrue(messenger.sent.isEmpty)
  }
}

private enum Reply: Equatable {
  case success(String?)
  case error(String)
  case notImplemented

  init(_ data: Data?) {
    guard let data, !data.isEmpty else {
      self = .notImplemented
      return
    }
    let decoded = FlutterStandardMethodCodec.sharedInstance().decodeEnvelope(data)
    if let error = decoded as? FlutterError {
      self = .error(error.code)
    } else if decoded == nil || decoded is NSNull {
      self = .success(nil)
    } else if let text = decoded as? String {
      self = .success(text)
    } else {
      self = .success(String(describing: decoded!))
    }
  }

  static func == (lhs: Reply, rhs: Reply) -> Bool {
    switch (lhs, rhs) {
    case (.success(let a), .success(let b)): return a == b
    case (.error(let a), .error(let b)): return a == b
    case (.notImplemented, .notImplemented): return true
    default: return false
    }
  }
}

private final class FakeLaunch: NativeAuthBrowserSession {
  let url: URL
  let host: String
  let path: String
  let completion: (URL?) -> Void
  private(set) var cancelled = false

  init(url: URL, host: String, path: String, completion: @escaping (URL?) -> Void) {
    self.url = url
    self.host = host
    self.path = path
    self.completion = completion
  }

  func cancel() {
    cancelled = true
  }
}

/// Records method calls the host sends and delivers encoded calls to the registered handler.
private final class FakeMessenger: NSObject, FlutterBinaryMessenger {
  private var handler: FlutterBinaryMessageHandler?
  private(set) var sent: [String] = []

  func receive(_ message: Data, reply: @escaping FlutterBinaryReply) {
    guard let handler else { return reply(nil) }
    handler(message, reply)
  }

  func send(onChannel channel: String, message: Data?) {
    send(onChannel: channel, message: message, binaryReply: nil)
  }

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    XCTAssertEqual(channel, NativeAuthChannel.name)
    guard let message else { return }
    let call = FlutterStandardMethodCodec.sharedInstance().decodeMethodCall(message)
    XCTAssertNil(call.arguments)
    sent.append(call.method)
  }

  func setMessageHandlerOnChannel(
    _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
  ) -> FlutterBinaryMessengerConnection {
    XCTAssertEqual(channel, NativeAuthChannel.name)
    self.handler = handler
    return 1
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
