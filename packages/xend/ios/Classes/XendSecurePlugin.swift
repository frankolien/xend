import Flutter
import UIKit

/// Bridges Dart and the native signer over the `ai.xend/secure` method channel. This is
/// the only code that touches both Flutter and `SecureSigner`. It parses channel
/// arguments, dispatches to the four signer methods off the main thread so that keychain
/// and biometric work never blocks the UI, and maps `SecureSignerError` values to stable
/// `FlutterError` codes that the Dart layer translates into typed errors.
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
            let result = try signer.generateKeyPair(walletId: try string(args, "walletId"))
            return ["address": result.address, "mnemonic": result.mnemonic]

        case "restore":
            let walletId = try string(args, "walletId")
            let mnemonic = try string(args, "mnemonic")
            return try signer.restore(walletId: walletId, mnemonic: mnemonic)

        case "loadOrRecover":
            return try signer.loadOrRecover(walletId: try string(args, "walletId"))

        case "revealMnemonic":
            let walletId = try string(args, "walletId")
            let reason = args["reason"] as? String ?? "Reveal your recovery phrase"
            return try signer.revealMnemonic(walletId: walletId, reason: reason)

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

    /// Maps signer errors to stable channel codes. The Dart layer switches on these
    /// codes to construct the corresponding typed error.
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
        case .enclave(let message):
            return FlutterError(code: "enclave_error", message: message, details: nil)
        case .invalidMnemonic:
            return FlutterError(code: "invalid_mnemonic", message: "Recovery phrase is not valid", details: nil)
        }
    }
}
