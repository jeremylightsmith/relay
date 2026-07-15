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
      default:
        result(FlutterMethodNotImplemented)
      }
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
