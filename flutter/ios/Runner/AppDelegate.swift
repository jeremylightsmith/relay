import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channel: FlutterMethodChannel?
  private var tokenCompletion: ((String?) -> Void)?
  private var launchNotification: [String: Any]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self

    // Cold start from a notification tap: stash the payload for
    // `initialNotification` (RLY-81 §12).
    if let remote = launchOptions?[.remoteNotification] as? [String: Any] {
      launchNotification = remote
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "relay/push", binaryMessenger: messenger)
    self.channel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "requestPermissionAndToken":
        self?.requestPermissionAndToken(result: result)
      case "initialNotification":
        result(self?.launchNotification)
        self?.launchNotification = nil
      case "authorizationStatus":
        self?.authorizationStatus(result: result)
      case "tokenIfAuthorized":
        self?.tokenIfAuthorized(result: result)
      case "primingDeferredAt":
        let stored = UserDefaults.standard.object(forKey: Self.primingDeferredAtKey) as? NSNumber
        result(stored?.int64Value)
      case "setPrimingDeferredAt":
        guard let args = call.arguments as? [String: Any],
              let epochMs = args["epochMs"] as? NSNumber else {
          result(FlutterError(code: "bad_args", message: "epochMs is required", details: nil))
          return
        }
        UserDefaults.standard.set(epochMs.int64Value, forKey: Self.primingDeferredAtKey)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// When the user last tapped "Not now" on AUTH-03, as epoch milliseconds (UTC).
  /// UserDefaults rather than a new Flutter dependency — see RLY-84's PushPrefs.
  private static let primingDeferredAtKey = "relay.push.primingDeferredAt"

  /// What iOS currently thinks about notification permission (RLY-84 §1). Returns
  /// nil for an @unknown future status: Dart turns "unavailable" into a safe skip,
  /// which beats guessing a status that every gate decision hangs off.
  private func authorizationStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let name: String?
      switch settings.authorizationStatus {
      case .notDetermined: name = "notDetermined"
      case .denied: name = "denied"
      case .authorized: name = "authorized"
      case .provisional: name = "provisional"
      case .ephemeral: name = "ephemeral"
      @unknown default: name = nil
      }
      DispatchQueue.main.async { result(name) }
    }
  }

  /// Registers for remote notifications **without** requestAuthorization — no
  /// prompt — and resolves the token through the existing delegate callback
  /// (RLY-84 §2). Only meaningful when already authorized; iOS will not prompt.
  private func tokenIfAuthorized(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      self.tokenCompletion = { token in result(token) }
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  private func requestPermissionAndToken(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
      guard granted else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      DispatchQueue.main.async {
        self.tokenCompletion = { token in result(token) }
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    tokenCompletion?(hex)
    tokenCompletion = nil
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    tokenCompletion?(nil)
    tokenCompletion = nil
  }

  // A tap while the app is running (foreground or background).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let payload = response.notification.request.content.userInfo
    channel?.invokeMethod("onNotificationTap", arguments: payload)
    completionHandler()
  }
}
