import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WordAiBackupFiles") {
      WordAiBackupFiles.register(with: registrar)
    }
  }
}

/// Exports an app-owned temporary copy through the system document picker.
/// A successful delegate callback confirms the picker export, not cloud sync.
private final class WordAiBackupFiles: NSObject, FlutterPlugin,
  FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
  private final class Request {
    let result: FlutterResult
    let directory: URL
    weak var scene: UIScene?
    var picker: UIDocumentPickerViewController?
    var deadline: DispatchWorkItem?

    init(result: @escaping FlutterResult, directory: URL, scene: UIScene?) {
      self.result = result
      self.directory = directory
      self.scene = scene
    }
  }

  private static let io = DispatchQueue(label: "org.wordai.backup-files", qos: .utility)
  // Accessed only on the main queue. A stalled preparation cannot queue another
  // payload on each retry or engine recreation.
  private static var preparationInFlight = false
  private weak var registrar: FlutterPluginRegistrar?
  private let channel: FlutterMethodChannel
  private var pending: Request?
  private var detached = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.wordai.community/backup_files", binaryMessenger: registrar.messenger())
    let instance = WordAiBackupFiles(registrar: registrar, channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
    // Flutter only delivers detachFromEngine to published plugin instances.
    registrar.publish(instance)
  }

  private init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
    self.registrar = registrar
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "save" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard !detached, let presenter = registrar?.viewController,
      let window = presenter.viewIfLoaded?.window
    else {
      result(Self.failure("unavailable"))
      return
    }
    guard pending == nil, !Self.preparationInFlight,
      presenter.presentedViewController == nil,
      !presenter.isBeingPresented, !presenter.isBeingDismissed
    else {
      result(Self.failure("busy"))
      return
    }
    guard let arguments = call.arguments as? [String: Any],
      let typedBytes = arguments["bytes"] as? FlutterStandardTypedData,
      !typedBytes.data.isEmpty, typedBytes.data.count <= 32 * 1024 * 1024
    else {
      result(Self.failure("invalid_data"))
      return
    }
    guard let name = arguments["suggestedName"] as? String, Self.validName(name) else {
      result(Self.failure("invalid_name"))
      return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wordai-backup-" + UUID().uuidString, isDirectory: true)
    let request = Request(result: result, directory: directory, scene: window.windowScene)
    let source = directory.appendingPathComponent(name, isDirectory: false)
    let bytes = typedBytes.data
    pending = request
    Self.preparationInFlight = true
    let expiresAt = DispatchTime.now() + 30
    let deadline = DispatchWorkItem { [weak self] in
      self?.finish(request, outcome: Self.failure("save_failed"))
    }
    request.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: expiresAt, execute: deadline)
    Self.io.async { [weak self] in
      let prepared: Bool
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false)
        try bytes.write(to: source, options: [.atomic, .completeFileProtection])
        prepared = true
      } catch {
        prepared = false
      }
      DispatchQueue.main.async {
        Self.preparationInFlight = false
        guard let self = self, self.pending === request else {
          Self.removeTemporaryDirectory(directory)
          return
        }
        request.deadline?.cancel()
        request.deadline = nil
        guard prepared, DispatchTime.now() < expiresAt else {
          self.finish(request, outcome: Self.failure("save_failed"))
          return
        }
        self.present(request, source: source)
      }
    }
  }

  private func present(_ request: Request, source: URL) {
    guard !detached, let presenter = registrar?.viewController,
      presenter.viewIfLoaded?.window?.windowScene === request.scene,
      presenter.viewIfLoaded?.window != nil,
      request.scene?.activationState == .foregroundActive,
      presenter.presentedViewController == nil,
      !presenter.isBeingPresented, !presenter.isBeingDismissed
    else {
      finish(request, outcome: Self.failure("unavailable"))
      return
    }
    let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    picker.delegate = self
    request.picker = picker
    picker.presentationController?.delegate = self
    // Do not impose a deadline on the user's choice. Only a failed presentation
    // is bounded; provider errors remain visible in the system picker.
    let deadline = DispatchWorkItem { [weak self, weak picker] in
      guard let self = self, self.pending === request else { return }
      request.deadline = nil
      if picker?.presentingViewController == nil {
        self.finish(request, outcome: Self.failure("unavailable"))
      }
    }
    request.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
    presenter.present(picker, animated: true) { [weak self] in
      guard let self = self, self.pending === request else { return }
      request.deadline?.cancel()
      request.deadline = nil
      if picker.presentingViewController == nil {
        self.finish(request, outcome: Self.failure("unavailable"))
      }
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let request = pending, request.picker === controller else { return }
    if urls.count == 1 { finish(request, outcome: true) }
    else { finish(request, outcome: Self.failure("save_failed")) }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let request = pending, request.picker === controller else { return }
    finish(request, outcome: false)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard let request = pending,
      request.picker === presentationController.presentedViewController
    else { return }
    finish(request, outcome: false)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    guard let request = pending, request.scene === scene else { return }
    finish(request, outcome: Self.failure("unavailable"), dismiss: true)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    if let request = pending {
      finish(request, outcome: Self.failure("unavailable"), dismiss: true)
    }
    channel.setMethodCallHandler(nil)
  }

  private func finish(_ request: Request, outcome: Any, dismiss: Bool = false) {
    guard pending === request else { return }
    pending = nil
    request.deadline?.cancel()
    request.deadline = nil
    request.picker?.delegate = nil
    request.picker?.presentationController?.delegate = nil
    if dismiss { request.picker?.dismiss(animated: false) }
    request.result(outcome)
    Self.removeTemporaryDirectory(request.directory)
  }

  private static func removeTemporaryDirectory(_ directory: URL) {
    // This URL is created internally for one request. Never remove a picker URL.
    io.async { try? FileManager.default.removeItem(at: directory) }
  }

  private static func validName(_ name: String) -> Bool {
    guard name.utf8.count <= 128, !name.contains(".."),
      let match = name.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.json$", options: .regularExpression),
      match == name.startIndex..<name.endIndex
    else { return false }
    let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    return stem.range(
      of: "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$",
      options: [.regularExpression, .caseInsensitive]) == nil
  }

  private static func failure(_ code: String) -> FlutterError {
    FlutterError(
      code: code, message: "The backup was not confirmed saved. Try again.", details: nil)
  }
}
