import Flutter
import UIKit

/// Bridges Dart ↔ the native vault over `MethodChannel("ai.xend/secure")`. This is the
/// only code that touches both Flutter and `SecureSigner`. It parses channel arguments,
/// dispatches to the four vault methods OFF the main thread (keychain / future biometric
/// work must never freeze the UI), and maps `SecureSignerError` → `FlutterError` codes
/// that line up 1:1 with the SDK's typed Dart errors.
public class XendSecurePlugin: NSObject, FlutterPlugin {
    private let signer = SecureSigner()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "ai.xend/secure",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(XendSecurePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<Any?, Error>
            do { outcome = .success(try self.dispatch(call)) } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let value): result(value)
                case .failure(let error): result(self.flutterError(error))
                }
            }
        }
    }

    private func dispatch(_ call: FlutterMethodCall) throws -> Any? {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "generateKeyPair":
            return try signer.generateKeyPair(walletId: try string(args, "walletId"))

        case "getPublicKey":
            return try signer.getPublicKey(walletId: try string(args, "walletId"))

        case "signMessage":
            let walletId = try string(args, "walletId")
            guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else {
                throw SecureSignerError.badArguments("bytes")
            }
            let reason = args["reason"] as? String ?? "Approve transaction"
            let sig = try signer.signMessage(walletId: walletId, message: bytes, reason: reason)
            return FlutterStandardTypedData(bytes: sig)

        case "deleteKey":
            try signer.deleteKey(walletId: try string(args, "walletId"))
            return nil

        default:
            return FlutterMethodNotImplemented
        }
    }

    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw SecureSignerError.badArguments(key) }
        return value
    }

    /// Map vault errors → stable channel codes. The Dart side switches on these to build
    /// the corresponding `XendError` variant.
    private func flutterError(_ error: Error) -> FlutterError {
        guard let e = error as? SecureSignerError else {
            return FlutterError(code: "unknown", message: "\(error)", details: nil)
        }
        switch e {
        case .authenticationCancelled:
            return FlutterError(code: "user_cancelled_auth", message: "Authentication cancelled", details: nil)
        case .biometricsUnavailable:
            return FlutterError(code: "biometrics_unavailable", message: "Biometrics unavailable", details: nil)
        case .keyNotFound:
            return FlutterError(code: "key_not_found", message: "No key for wallet", details: nil)
        case .badArguments(let k):
            return FlutterError(code: "bad_arguments", message: "Missing/invalid argument: \(k)", details: nil)
        case .badPublicKeyData:
            return FlutterError(code: "bad_public_key", message: "Stored public key is corrupt", details: nil)
        case .keychain(let status):
            return FlutterError(code: "keychain_error", message: "Keychain error \(status)", details: nil)
        case .notImplemented(let what):
            return FlutterError(code: "not_implemented", message: what, details: nil)
        }
    }
}
