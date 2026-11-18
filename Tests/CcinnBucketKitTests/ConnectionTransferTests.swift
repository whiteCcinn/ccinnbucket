import CcinnBucketKit
import Foundation
import StorageKit
import Testing

@Suite("Connection export and import")
struct ConnectionTransferTests {
    /// Few PBKDF2 rounds keep the tests fast; production uses `defaultIterations`.
    private static let rounds = 1_000

    private static func account(_ name: String, kind: AccountKind = .alibabaOSS, key: String = "LTAI-test", region: String = "ap-southeast-1") -> StorageAccount {
        var account = StorageAccount(kind: kind, name: name, accessKeyID: key, color: .green)
        account.region = region
        account.defaultBucket = "sg-bucket"
        account.isFavorite = true
        account.mcpAccess = .readOnly
        return account
    }

    @Test("without a passphrase: accounts and preferences round-trip in the clear, no secrets are written")
    func roundTripWithoutSecrets() throws {
        let accounts = [Self.account("OSS SG"), Self.account("MinIO", kind: .minio, key: "minio", region: "us-east-1")]
        let secrets = [accounts[0].id: ConnectionTransfer.Secrets(secretAccessKey: "s3cr3t-value", sessionToken: nil)]
        let data = try ConnectionTransfer.export(accounts, secrets: secrets, passphrase: nil, preferences: ["browserViewStyle": "columns"],
                                                 appVersion: "1.3.0", iterations: Self.rounds)
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cr3t-value"))
        let file = try ConnectionTransfer.read(data)
        #expect(!file.isEncrypted && file.connectionCount == 2 && file.appVersion == "1.3.0")
        let unlocked = try ConnectionTransfer.unlock(file, passphrase: nil)
        #expect(unlocked.accounts == accounts)
        #expect(unlocked.preferences == ["browserViewStyle": "columns"])
        #expect(unlocked.secrets.isEmpty)
    }

    @Test("with a passphrase: connections, preferences and secrets are all sealed; only the right passphrase opens them")
    func encryptedEverything() throws {
        let accounts = [Self.account("OSS SG"), Self.account("Other")]
        let secrets = [accounts[0].id: ConnectionTransfer.Secrets(secretAccessKey: "s3cr3t-value", sessionToken: "sts-token"),
                       accounts[1].id: ConnectionTransfer.Secrets(secretAccessKey: "another", sessionToken: nil)]
        let data = try ConnectionTransfer.export(accounts, secrets: secrets, passphrase: "correct horse", preferences: ["appearance": "Dark"],
                                                 appVersion: "1.3.0", iterations: Self.rounds)
        let text = String(decoding: data, as: UTF8.self)
        for hidden in ["s3cr3t-value", "sts-token", "another", "OSS SG", "LTAI-test", "sg-bucket", "Dark"] {
            #expect(!text.contains(hidden), "\(hidden) must not be readable without the passphrase")
        }
        let file = try ConnectionTransfer.read(data)
        #expect(file.isEncrypted && file.connectionCount == 2 && file.accounts.isEmpty)
        let unlocked = try ConnectionTransfer.unlock(file, passphrase: "correct horse")
        #expect(unlocked.accounts == accounts && unlocked.secrets == secrets && unlocked.preferences == ["appearance": "Dark"])
        #expect(throws: ConnectionTransfer.TransferError.wrongPassphrase) { try ConnectionTransfer.unlock(file, passphrase: "wrong horse") }
        #expect(throws: ConnectionTransfer.TransferError.wrongPassphrase) { try ConnectionTransfer.unlock(file, passphrase: nil) }
    }

    @Test("secrets of accounts that are not exported are left out")
    func onlyExportedSecrets() throws {
        let account = Self.account("A")
        let data = try ConnectionTransfer.export([account], secrets: [account.id: .init(secretAccessKey: "a", sessionToken: nil),
                                                                       UUID(): .init(secretAccessKey: "b", sessionToken: nil)],
                                                 passphrase: "long enough", preferences: [:], appVersion: "1", iterations: Self.rounds)
        let unlocked = try ConnectionTransfer.unlock(ConnectionTransfer.read(data), passphrase: "long enough")
        #expect(Set(unlocked.secrets.keys) == [account.id])
    }

    @Test("a changed byte anywhere in the sealed part is detected")
    func tampering() throws {
        let account = Self.account("A")
        let data = try ConnectionTransfer.export([account], secrets: [account.id: .init(secretAccessKey: "a", sessionToken: nil)],
                                                 passphrase: "long enough", preferences: [:], appVersion: "1", iterations: Self.rounds)
        var file = try ConnectionTransfer.read(data)
        var sealed = try #require(file.sealed)
        sealed.sealed[sealed.sealed.count / 2] ^= 0x01
        file.sealed = sealed
        #expect(throws: ConnectionTransfer.TransferError.wrongPassphrase) { try ConnectionTransfer.unlock(file, passphrase: "long enough") }
    }

    @Test("short passphrases are refused")
    func weakPassphrase() {
        #expect(throws: ConnectionTransfer.TransferError.weakPassphrase) {
            try ConnectionTransfer.export([Self.account("A")], secrets: [:], passphrase: "short", preferences: [:], appVersion: "1", iterations: Self.rounds)
        }
    }

    @Test("files that are not connection exports, from a newer version, too large or hostile are refused")
    func validation() throws {
        #expect(throws: ConnectionTransfer.TransferError.notAConnectionsFile) { try ConnectionTransfer.read(Data("{}".utf8)) }
        #expect(throws: ConnectionTransfer.TransferError.notAConnectionsFile) { try ConnectionTransfer.read(Data("not json".utf8)) }
        #expect(throws: ConnectionTransfer.TransferError.fileTooLarge) { try ConnectionTransfer.read(Data(count: ConnectionTransfer.maximumFileSize + 1)) }

        let good = try ConnectionTransfer.export([Self.account("A")], secrets: [:], passphrase: "long enough", preferences: [:], appVersion: "1",
                                                 iterations: Self.rounds)
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        object["version"] = 99
        #expect(throws: ConnectionTransfer.TransferError.unsupportedVersion(99)) {
            try ConnectionTransfer.read(JSONSerialization.data(withJSONObject: object))
        }
        object["version"] = 1
        var sealed = try #require(object["sealed"] as? [String: Any])
        sealed["iterations"] = 2_000_000_000
        object["sealed"] = sealed
        let hostile = try ConnectionTransfer.read(JSONSerialization.data(withJSONObject: object))
        #expect(throws: ConnectionTransfer.TransferError.invalidKeyDerivation, "a crafted round count must not hang the app") {
            try ConnectionTransfer.unlock(hostile, passphrase: "long enough")
        }
    }

    @Test("import plan: same id updates (with the changed fields), same connection under another id is skipped, the rest is added")
    func plan() throws {
        let existing = Self.account("Mine")
        var renamed = existing
        renamed.name = "Mine (renamed on the old Mac)"
        var sameConnection = Self.account("Twin")
        sameConnection.endpoint = existing.endpoint.uppercased()
        let new = Self.account("New", key: "another-key")
        let plan = ConnectionTransfer.plan([renamed, sameConnection, new], existing: [existing])
        #expect(plan.updated.map(\.account.name) == ["Mine (renamed on the old Mac)"])
        let update = try #require(plan.updated.first)
        #expect(update.changes == ["name"] && !update.isSensitive)
        #expect(plan.skipped.map(\.name) == ["Twin"])
        #expect(plan.added.map(\.name) == ["New"])
    }

    @Test("updates that redirect a connection or widen its access are sensitive")
    func sensitiveUpdates() throws {
        var existing = Self.account("Mine")
        existing.isReadOnly = true
        existing.mcpAccess = .disabled
        var redirected = existing
        redirected.endpoint = "https://attacker.example.com"
        var widened = existing
        widened.isReadOnly = false
        widened.mcpAccess = .readWrite
        var narrowed = existing
        narrowed.color = .red
        for (incoming, sensitive) in [(redirected, true), (widened, true), (narrowed, false)] {
            let update = try #require(ConnectionTransfer.plan([incoming], existing: [existing]).updated.first)
            #expect(update.isSensitive == sensitive, "\(update.changes)")
        }
        let widenedChanges = try #require(ConnectionTransfer.plan([widened], existing: [existing]).updated.first).changes
        #expect(widenedChanges == ["read-only", "AI access"])
    }
}
