import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Small files wrapped by the Secure Enclave, shared by the vault key store and the cloud storage connection blob.
///
/// Why not the Keychain: see `SecureEnclaveVaultKeyStore` (ad-hoc builds cannot use the data protection Keychain). How it works:
/// a P-256 key is generated in the enclave (the caller supplies the access control) and data is wrapped ECIES-style: ECDH between
/// an ephemeral P-256 key and the enclave public key -> HKDF-SHA256 (`info` separates purposes) -> AES-256-GCM. Only the
/// enclave-exported key handle (usable only by this Mac's enclave), the ephemeral public key and the ciphertext are written to
/// disk, with mode 0600; other processes or other Macs cannot open the file.
enum SecureEnclaveSealing {
    struct File: Codable {
        var version: Int
        var enclaveKey: Data
        var ephemeralPublicKey: Data
        var ciphertext: Data
        var createdAt: Date
        var updatedAt: Date
    }

    enum Failure: Error {
        case unavailable
        case accessControl
        case sealing
        case io
        case missing
        /// Corrupt file, wrong version, invalidated handle (for example after the enrolled fingerprints change) or failed decryption.
        case invalid
    }

    static func seal(_ data: Data, accessibility: CFString, flags: SecAccessControlCreateFlags, info: Data, createdAt: Date) throws -> File
    {
        guard SecureEnclave.isAvailable else { throw Failure.unavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, flags, &error) else { throw Failure.accessControl }
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
            guard let ciphertext = try AES.GCM.seal(data, using: wrappingKey(from: shared, info: info)).combined else {
                throw Failure.sealing
            }
            return File(
                version: 1, enclaveKey: enclaveKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                ciphertext: ciphertext, createdAt: createdAt, updatedAt: .now)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.sealing
        }
    }

    /// Unwraps the file. When the enclave key requires biometrics, the caller authenticates with `context` first and passes it in.
    static func open(_ file: File, info: Data, context: LAContext? = nil) throws -> Data {
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: file.enclaveKey, authenticationContext: context)
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(x963Representation: file.ephemeralPublicKey)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: file.ciphertext), using: wrappingKey(from: shared, info: info))
        } catch {
            throw Failure.invalid
        }
    }

    static func write(_ file: File, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.kakey.encode(file).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.io
        }
    }

    static func read(from url: URL) throws -> File {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
        do {
            let file = try JSONDecoder.kakey.decode(File.self, from: Data(contentsOf: url))
            guard file.version == 1 else { throw Failure.invalid }
            return file
        } catch {
            throw Failure.invalid
        }
    }

    private static func wrappingKey(from shared: SharedSecret, info: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }
}
