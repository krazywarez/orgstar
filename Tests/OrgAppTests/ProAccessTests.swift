import CryptoKit
import Foundation
import Testing
@testable import OrgApp

struct GrandfatheringTests {
    @Test func buildsBeforeTheFirstPaidOnePredatePro() {
        #expect(Grandfathering.predatesPro(originalBuild: "16", firstPaidBuild: 17))
        #expect(Grandfathering.predatesPro(originalBuild: "1", firstPaidBuild: 17))
        #expect(!Grandfathering.predatesPro(originalBuild: "17", firstPaidBuild: 17))
        #expect(!Grandfathering.predatesPro(originalBuild: "40", firstPaidBuild: 17))
    }

    @Test func unparseableBuildsDoNotPredatePro() {
        // Sandbox and Xcode report "1.0"; they must not unlock Pro.
        #expect(!Grandfathering.predatesPro(originalBuild: "1.0", firstPaidBuild: 17))
        #expect(!Grandfathering.predatesPro(originalBuild: "", firstPaidBuild: 17))
    }

    @Test func macDecidesOnceFromAnEarlierLaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        #expect(Grandfathering.macPredatesPro(defaults: defaults, marker: nil))
        defaults.removeObject(forKey: "SUHasLaunchedBefore")
        #expect(Grandfathering.macPredatesPro(defaults: defaults, marker: nil))
    }

    @Test func aNewMacDoesNotPredatePro() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(!Grandfathering.macPredatesPro(defaults: defaults, marker: missing))
        // A folder created after the first Pro launch doesn't change the answer.
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(!Grandfathering.macPredatesPro(defaults: defaults, marker: missing))
    }
}

struct ProFeatureTests {
    @Test func commandsNeedTheirFeature() {
        #expect(ProFeature.required(byCommand: "app.export.pdf") == .export)
        #expect(ProFeature.required(byCommand: "app.export.docx") == .export)
        #expect(ProFeature.required(byCommand: "app.publish-all") == .export)
        #expect(ProFeature.required(byCommand: "app.copy-rich-text") == .export)
        #expect(ProFeature.required(byCommand: "app.crypt.encrypt-entry") == .encryption)
        #expect(ProFeature.required(byCommand: "app.dailies.today") == .roam)
        #expect(ProFeature.required(byCommand: "app.node.find") == .roam)
        #expect(ProFeature.required(byCommand: "app.toggle-backlinks") == .roam)
    }

    @Test func freeCommandsStayFree() {
        for id in ["app.export.html", "app.export.html-open", "app.export.markdown", "app.crypt.open-entry",
                   "app.crypt.decrypt-entry", "app.crypt.forget-passphrase", "app.save", "app.refile", "app.clock.in"] {
            #expect(ProFeature.required(byCommand: id) == nil, "\(id)")
        }
    }
}

@MainActor
struct ProAccessTests {
    @Test func gatesUntilGrantedAndRemembers() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let access = ProAccess(defaults: defaults)
        #expect(!access.allows(.babel))
        #expect(access.paywall == .babel)
        access.set(.purchase)
        #expect(access.allows(.roam))
        #expect(ProAccess(defaults: defaults).grant == .purchase)
        access.set(nil)
        #expect(!ProAccess(defaults: defaults).isUnlocked)
    }
}

struct LicenseKeyTests {
    let signer = Curve25519.Signing.PrivateKey()
    var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }

    func key(_ json: String, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let payload = Data(json.utf8)
        let signature = try (signer ?? self.signer).signature(for: payload)
        return "ORGSTAR1-" + payload.base64URL + "." + signature.base64URL
    }

    @Test func verifiesASignedKey() throws {
        let text = try key(#"{"e":"a@example.com","t":"txn_01","i":1763000000}"#)
        let license = try LicenseKey.verify(text, publicKey: publicKey)
        #expect(license == LicenseKey(email: "a@example.com", transaction: "txn_01", issued: 1763000000))
    }

    @Test func ignoresWhitespaceFromPasting() throws {
        let text = try key(#"{"e":"a@example.com","t":"txn_01","i":1}"#)
        let wrapped = " " + text.prefix(30) + "\n" + text.dropFirst(30) + "\n"
        #expect(try LicenseKey.verify(wrapped, publicKey: publicKey).transaction == "txn_01")
    }

    @Test func rejectsAnotherSignerAndTampering() throws {
        let forged = try key(#"{"e":"a@example.com","t":"txn_01","i":1}"#, signedBy: Curve25519.Signing.PrivateKey())
        #expect(throws: LicenseKey.Failure.badSignature) { try LicenseKey.verify(forged, publicKey: publicKey) }

        let good = try key(#"{"e":"a@example.com","t":"txn_01","i":1}"#)
        let signature = good.split(separator: ".")[1]
        let other = Data(#"{"e":"b@example.com","t":"txn_01","i":1}"#.utf8).base64URL
        #expect(throws: LicenseKey.Failure.badSignature) {
            try LicenseKey.verify("ORGSTAR1-\(other).\(signature)", publicKey: publicKey)
        }
    }

    @Test func rejectsMalformedKeys() {
        for text in ["", "hello", "ORGSTAR1-", "ORGSTAR1-abc", "ORGSTAR2-abc.def", "ORGSTAR1-!!.??"] {
            #expect(throws: LicenseKey.Failure.malformed) { try LicenseKey.verify(text, publicKey: publicKey) }
        }
    }

    @Test func theShippedPublicKeyParses() throws {
        let raw = try #require(Data(base64Encoded: LicenseKey.publicKey))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    @Test func storesOnlyKeysThatVerify() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        #expect(throws: LicenseKey.Failure.malformed) { try LicenseStore.activate("nope", defaults: defaults) }
        #expect(LicenseStore.current(defaults: defaults) == nil)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
