import CcinnBucketKit
import Foundation
import StorageKit
import Testing

@Suite("Accounts, presets and secrets")
struct AccountTests {
    @Test("presets choose provider-appropriate defaults")
    func presets() throws {
        let minio = StorageAccount(kind: .minio)
        #expect(minio.addressing == .path)
        #expect(minio.region == "us-east-1")
        #expect(minio.validationErrors.contains("Enter the endpoint URL"))

        var oss = StorageAccount(kind: .alibabaOSS)
        oss.region = "cn-hangzhou"
        #expect(oss.kind.provider == .oss)
        #expect(oss.ossSignatureVersion == .v4)
        #expect(oss.effectiveEndpointDescription == "https://oss-cn-hangzhou.aliyuncs.com")
        oss.ossEndpointKind = .internal
        #expect(oss.effectiveEndpointDescription == "https://oss-cn-hangzhou-internal.aliyuncs.com")

        let aws = StorageAccount(kind: .amazonS3)
        #expect(aws.addressing == .virtualHosted)
        #expect(aws.endpoint.isEmpty)
        #expect(StorageAccount(kind: .cloudflareR2).region == "auto")
        #expect(StorageAccount(kind: .tencentCOS).addressing == .virtualHosted)
    }

    @Test("configuration maps every account field")
    func configuration() throws {
        var account = StorageAccount(kind: .minio, name: "Local", accessKeyID: "ak")
        account.endpoint = "http://127.0.0.1:19900"
        account.listAPIVersion = .v1
        let configuration = try account.storageConfiguration()
        #expect(configuration.provider == .s3)
        #expect(configuration.endpoint == StorageEndpoint(scheme: "http", host: "127.0.0.1", port: 19900))
        #expect(configuration.addressing == .path)
        #expect(configuration.listAPIVersion == .v1)

        account.endpoint = "not a url"
        #expect(throws: (any Error).self) { try account.storageConfiguration() }
        #expect(account.validationErrors.contains("The endpoint is not a valid http(s) URL"))
    }

    @Test("validation: access key, custom domain needs bucket, part size bounds")
    func validation() {
        var account = StorageAccount(kind: .amazonS3)
        #expect(account.validationErrors.contains("Enter the access key ID"))
        account.accessKeyID = "AKID"
        #expect(account.validationErrors.isEmpty)
        account.partSizeMiB = 2
        #expect(!account.validationErrors.isEmpty)
        account.partSizeMiB = 8
        var oss = StorageAccount(kind: .alibabaOSS, accessKeyID: "id")
        oss.endpoint = "https://cdn.example.com"
        oss.usesCustomDomain = true
        #expect(oss.validationErrors.contains("Enter the bucket bound to the custom domain"))
    }

    @Test("secrets live in the secret store and never in the account file")
    func secretsNeverOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let repository = AccountRepository(directory: directory, secrets: secrets)
        var account = StorageAccount(kind: .amazonS3, name: "Prod", accessKeyID: "AKIAEXAMPLE")
        account.region = "eu-west-1"
        try repository.save([account])
        try repository.storeSecrets(for: account, secretAccessKey: "wJalrXUtnFEMI/K7MDENG/SECRETVALUE", sessionToken: "SESSION-TOKEN-VALUE")

        let fileText = try String(contentsOf: directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!fileText.contains("SECRETVALUE"))
        #expect(!fileText.contains("SESSION-TOKEN-VALUE"))
        #expect(fileText.contains("AKIAEXAMPLE"))
        #expect(try repository.load() == [account])
        let loaded = repository.credentials(for: account)
        #expect(loaded?.secretAccessKey == "wJalrXUtnFEMI/K7MDENG/SECRETVALUE")
        #expect(loaded?.sessionToken == "SESSION-TOKEN-VALUE")

        try repository.delete(account)
        #expect(repository.credentials(for: account) == nil)
    }

    @Test("a corrupt account file fails loudly instead of silently dropping accounts")
    func corruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("accounts.json"))
        #expect(throws: (any Error).self) { try AccountRepository(directory: directory, secrets: InMemorySecretStore()).load() }
    }

    @Test("recents are ordered by last use")
    func recents() {
        var older = StorageAccount(kind: .minio, name: "a")
        older.lastConnectedAt = Date(timeIntervalSince1970: 100)
        var newer = StorageAccount(kind: .minio, name: "b")
        newer.lastConnectedAt = Date(timeIntervalSince1970: 200)
        let never = StorageAccount(kind: .minio, name: "c")
        #expect(StorageAccount.recents([older, never, newer]).map(\.name) == ["b", "a"])
    }

    @Test("decoding tolerates missing optional fields from older versions")
    func backwardCompatibleDecoding() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","kind":"minio","endpoint":"http://127.0.0.1:9000","region":"us-east-1","accessKeyID":"ak"}]"#
        let accounts = try JSONDecoder().decode([StorageAccount].self, from: Data(json.utf8))
        #expect(accounts.first?.addressing == .path)
        #expect(accounts.first?.isReadOnly == false)
        #expect(accounts.first?.partSizeMiB == StorageAccount.defaultPartSizeMiB)
    }
}
