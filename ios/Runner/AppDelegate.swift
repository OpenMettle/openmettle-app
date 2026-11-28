import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeAuth: NativeAuthChannel?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    nativeAuth = nil
    nativeAuth = NativeAuthChannel(
      messenger: engineBridge.applicationRegistrar.messenger(),
      presentationAnchor: {
        UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .filter { $0.activationState == .foregroundActive }
          .compactMap(\.keyWindow)
          .first
      },
      configuration: Bundle.main.infoDictionary ?? [:]
    )
  }
}
