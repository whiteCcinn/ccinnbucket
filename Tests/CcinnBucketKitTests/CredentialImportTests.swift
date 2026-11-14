import CcinnBucketKit
import Foundation
import StorageKit
import Testing

@Suite("Credential file import (read-only)")
struct CredentialImportTests {
    @Test("AWS credentials + config: profiles, regions, endpoint_url, nested s3 addressing style")
    func aws() {
        let credentials = """
        # comment
        [default]
        aws_access_key_id = AKIADEFAULT
        aws_secret_access_key = defaultSecret/+=

        [work]
        aws_access_key_id=AKIAWORK
        aws_secret_access_key=workSecret
        aws_session_token = FwoGZXIvYXdzEXAMPLE==
        ; another comment

        [no-secret]
        aws_access_key_id = AKIAONLYID
        """
        let config = """
        [default]
        region = us-west-2

        [profile work]
        region = eu-central-1
        s3 =
          addressing_style = path
        endpoint_url = http://127.0.0.1:19900

        [sso-session corp]
        sso_region = us-east-1
        """
        let imported = CredentialImport.parseAWS(credentials: credentials, config: config)
        #expect(imported.map(\.profileName) == ["default", "work"])
        let work = imported[1]
        #expect(work.provider == .s3)
        #expect(work.accessKeyID == "AKIAWORK")
        #expect(work.secretAccessKey == "workSecret")
        #expect(work.sessionToken == "FwoGZXIvYXdzEXAMPLE==")
        #expect(work.region == "eu-central-1")
        #expect(work.endpoint == "http://127.0.0.1:19900")
        #expect(work.addressing == .path)
        #expect(imported[0].region == "us-west-2")
        #expect(imported[0].secretAccessKey == "defaultSecret/+=")
    }

    @Test("Alibaba Cloud credentials file, ossutil config and aliyun CLI config")
    func alibaba() {
        let credentials = """
        [default]
        type = access_key
        access_key_id = LTAIdefault
        access_key_secret = aliSecret

        [sts]
        type = sts
        access_key_id = STS.abc
        access_key_secret = stsSecret
        security_token = CAIS==

        [ram]
        type = ram_role_arn
        access_key_id = LTAIram
        access_key_secret = ramSecret
        """
        let ali = CredentialImport.parseAlibabaCredentials(credentials)
        #expect(ali.map(\.profileName) == ["default", "sts"])
        #expect(ali[1].sessionToken == "CAIS==")
        #expect(ali.allSatisfy { $0.provider == .oss })

        let ossutil = """
        [Credentials]
        language=EN
        endpoint=oss-cn-shanghai.aliyuncs.com
        accessKeyID=LTAIossutil
        accessKeySecret=ossutilSecret
        stsToken=
        """
        let fromOSSUtil = CredentialImport.parseOSSUtilConfig(ossutil)
        #expect(fromOSSUtil.count == 1)
        #expect(fromOSSUtil.first?.region == "cn-shanghai")
        #expect(fromOSSUtil.first?.endpoint == "oss-cn-shanghai.aliyuncs.com")
        #expect(fromOSSUtil.first?.sessionToken == nil)

        let aliyun = #"""
        {"current":"default","profiles":[
          {"name":"default","mode":"AK","access_key_id":"LTAIcli","access_key_secret":"cliSecret","region_id":"cn-beijing"},
          {"name":"sso","mode":"CloudSSO","access_key_id":"","access_key_secret":""},
          {"name":"tmp","mode":"StsToken","access_key_id":"STS.x","access_key_secret":"s","sts_token":"tok","region_id":"ap-southeast-1"}
        ]}
        """#
        let fromCLI = CredentialImport.parseAliyunConfig(Data(aliyun.utf8))
        #expect(fromCLI.map(\.profileName) == ["default", "tmp"])
        #expect(fromCLI.first?.region == "cn-beijing")
        #expect(fromCLI.last?.sessionToken == "tok")
    }

    @Test("garbage input never crashes and yields nothing")
    func garbage() {
        for text in ["", "[", "=", "[unterminated\nkey=value", String(repeating: "[a]\n", count: 10_000), "\u{0}\u{1}\u{2}"] {
            _ = CredentialImport.parseAWS(credentials: text, config: text)
            _ = CredentialImport.parseAlibabaCredentials(text)
            _ = CredentialImport.parseOSSUtilConfig(text)
            _ = CredentialImport.parseAliyunConfig(Data(text.utf8))
        }
        #expect(CredentialImport.parseAliyunConfig(Data("{\"profiles\": 5}".utf8)).isEmpty)
    }

    @Test("scanning reads the files when present, never writes them, and skips oversized files")
    func scan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let credentialsURL = home.appendingPathComponent(".aws/credentials")
        try "[default]\naws_access_key_id=AKIA1\naws_secret_access_key=s1\n".write(to: credentialsURL, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)[.modificationDate] as? Date
        try Data(repeating: 0x41, count: 2 << 20).write(to: home.appendingPathComponent(".ossutilconfig"))
        let found = CredentialImport.scan(home: home)
        #expect(found.map(\.accessKeyID) == ["AKIA1"])
        #expect(found.first?.source == "~/.aws/credentials")
        let after = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("an imported credential becomes an account without its secret")
    func toAccount() {
        let credential = ImportedCredential(source: "~/.aws/credentials", profileName: "work", provider: .s3, accessKeyID: "AKIA",
                                            secretAccessKey: "secret", sessionToken: nil, region: "eu-west-1", endpoint: nil, addressing: nil)
        let account = credential.makeAccount()
        #expect(account.kind == .amazonS3)
        #expect(account.name == "work")
        #expect(account.region == "eu-west-1")
        let local = ImportedCredential(source: "x", profileName: "local", provider: .s3, accessKeyID: "a", secretAccessKey: "b", sessionToken: nil,
                                       region: nil, endpoint: "http://localhost:9000", addressing: .path)
        #expect(local.makeAccount().kind == .otherS3)
        #expect(local.makeAccount().endpoint == "http://localhost:9000")
    }
}
