//
//  SyncTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import CryptoKit
import XCTest

/// A device as sync sees it: its items, what it last knew, and its passphrase.
private struct Device {
    var machines: [RDMachine] = []
    var identities: [RDIdentity] = []
    var state = SyncState()
    var passphrase = "correct horse battery"
    var key: SyncCipher.Key?
    var syncsIdentities = true

    /// One round against `cloud`, applying what it says.
    @discardableResult
    mutating func sync(_ cloud: inout Data?, at now: Date, replacing: Bool = false) -> SyncOutcome {
        var input = SyncInput(
            machines: machines, identities: identities, state: state, passphrase: passphrase, remote: cloud,
            key: key
        )
        input.syncsIdentities = syncsIdentities
        input.replacesRemote = replacing
        input.now = now
        input.rounds = 1000
        input.minimumRounds = 1000
        let outcome = SyncSession.run(input)
        guard case let .done(done) = outcome else { return outcome }
        for change in done.machines {
            switch change {
            case let .put(value):
                machines.removeAll { $0.id == value.id }
                machines.append(value)
            case let .remove(id):
                machines.removeAll { $0.id == id }
            }
        }
        for change in done.identities {
            switch change {
            case let .put(value):
                identities.removeAll { $0.id == value.id }
                identities.append(value)
            case let .remove(id):
                identities.removeAll { $0.id == id }
            }
        }
        state = done.state
        key = done.key
        if let upload = done.upload { cloud = upload }
        return outcome
    }
}

private func uploaded(_ outcome: SyncOutcome) -> Bool {
    if case let .done(done) = outcome { return done.upload != nil }
    return false
}

final class SyncTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func machine(_ name: String) -> RDMachine {
        RDMachine(remoteAddress: "192.0.2.1", remotePort: "22", name: name)
    }

    func testASecondDeviceReceivesWhatTheFirstHas() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.identities = [RDIdentity(username: "root", password: "secret")]

        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(0))))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(10))), "nothing of its own to add")

        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(phone.identities.first?.password, "secret")
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(20))), "a round with no changes uploads nothing")
    }

    func testIdentitiesCarryTheirPasswordsAndPrivateKeys() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.identities = [RDIdentity(
            username: "root",
            password: "key passphrase",
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: "ssh-ed25519 AAAA"
        )]

        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(10))

        XCTAssertEqual(phone.identities.first?.password, "key passphrase")
        XCTAssertEqual(phone.identities.first?.privateKey, mac.identities.first?.privateKey)
        XCTAssertEqual(phone.identities.first?.publicKey, "ssh-ed25519 AAAA")
    }

    func testAChangedPassphraseStillMergesWhatTheOldOneOpened() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.passphrase = "the old passphrase"
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        // The phone changes its passphrase without a cached key: the old
        // passphrase alone has to open the server's file, or alpha is lost.
        phone.passphrase = "the new passphrase"
        phone.machines = [machine("beta")]
        var input = SyncInput(
            machines: phone.machines, identities: [], state: phone.state,
            passphrase: phone.passphrase, remote: cloud, key: nil
        )
        input.replacesRemote = true
        input.replacingPassphrase = "the old passphrase"
        input.now = time(10)
        input.rounds = 1000
        input.minimumRounds = 1000
        guard case let .done(done) = SyncSession.run(input) else {
            return XCTFail("the replacement round failed")
        }
        XCTAssertTrue(done.machines.contains { change in
            if case let .put(machine) = change {
                return machine.name == "alpha"
            }
            return false
        }, "what the old passphrase opened is merged, not replaced away")
        XCTAssertTrue(done.upload != nil)
    }

    func testBothDevicesKeepWhatEachAdded() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        phone.machines = [machine("beta")]

        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))

        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta"])
    }

    func testTheLaterEditWins() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].name = "from the Mac"
        phone.machines[0].name = "from the phone"
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))

        XCTAssertEqual(mac.machines.map(\.name), ["from the phone"])
        XCTAssertEqual(phone.machines.map(\.name), ["from the phone"])
    }

    func testADeletionReachesTheOtherDevice() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        phone.machines.removeAll { $0.name == "alpha" }
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))
        XCTAssertEqual(mac.machines.map(\.name), ["beta"])

        // And is not brought back by a round that changes nothing.
        phone.sync(&cloud, at: time(30))
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testAnEditAfterADeletionBringsTheItemBack() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        phone.machines = []
        phone.sync(&cloud, at: time(10))
        mac.machines[0].comment = "still needed"
        mac.sync(&cloud, at: time(20))
        phone.sync(&cloud, at: time(30))

        XCTAssertEqual(phone.machines.map(\.comment), ["still needed"])
    }

    func testConnectingDoesNotCountAsAnEdit() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].lastConnection = time(5)
        mac.machines[0].lastBanner = "Welcome"
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(10))))

        // Another device's edit leaves this device's own record of use alone.
        phone.machines[0].name = "renamed"
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(mac.machines[0].name, "renamed")
        XCTAssertEqual(mac.machines[0].lastBanner, "Welcome")
    }

    func testEditsAtTheSameInstantSettleOnOne() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].name = "one"
        phone.machines[0].name = "two"
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(10))
        XCTAssertEqual(mac.machines.map(\.name), phone.machines.map(\.name))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(11))))
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(12))))
    }

    func testAWrongPassphraseReadsNothingAndWritesNothing() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        let stored = cloud

        phone.passphrase = "something else"
        phone.machines = [machine("beta")]
        guard case .locked = phone.sync(&cloud, at: time(10)) else { return XCTFail("expected locked") }
        XCTAssertEqual(cloud, stored)
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testReplacingPutsThisDevicesDataUnderANewKey() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        phone.passphrase = "a new passphrase"
        phone.machines = [machine("beta")]
        phone.sync(&cloud, at: time(10), replacing: true)

        guard case .locked = mac.sync(&cloud, at: time(20)) else { return XCTFail("expected locked") }
        mac.passphrase = "a new passphrase"
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
    }

    func testChangingThePassphraseKeepsWhatAnotherDeviceStored() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone deletes one and adds one; the Mac has not synced since.
        phone.machines.removeAll { $0.name == "alpha" }
        phone.machines.append(machine("gamma"))
        phone.sync(&cloud, at: time(10))

        mac.passphrase = "a new passphrase"
        mac.sync(&cloud, at: time(20), replacing: true)
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["beta", "gamma"])

        guard case .locked = phone.sync(&cloud, at: time(30)) else { return XCTFail("expected locked") }
        phone.passphrase = "a new passphrase"
        phone.sync(&cloud, at: time(40))
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["beta", "gamma"])
    }

    func testTurningSyncOffAndOnDoesNotUndoWhatHappenedMeanwhile() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone stops syncing; the Mac renames one server and deletes the other.
        phone.state = SyncState()
        mac.machines.removeAll { $0.name == "beta" }
        mac.machines[0].name = "renamed"
        mac.sync(&cloud, at: time(10))

        phone.machines.append(machine("gamma"))
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["renamed", "gamma"])
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["renamed", "gamma"])
    }

    func testAClockThatRunsAheadDoesNotUndoALaterEdit() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone's clock is an hour ahead.
        phone.machines[0].name = "from the phone"
        phone.sync(&cloud, at: time(3600 + 10))
        mac.sync(&cloud, at: time(20))
        mac.machines[0].name = "later, from the Mac"
        mac.sync(&cloud, at: time(30))
        phone.sync(&cloud, at: time(3600 + 40))
        XCTAssertEqual(mac.machines.map(\.name), ["later, from the Mac"])
        XCTAssertEqual(phone.machines.map(\.name), ["later, from the Mac"])
    }

    func testAnExpiredDeletionIsNotPassedBackAndForth() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))
        mac.machines.removeAll { $0.name == "alpha" }
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(20))

        // The Mac forgets the deletion; the phone, whose clock is behind, has not yet.
        let later = 10 + SyncMerge.tombstoneLifetime + 1
        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(later))))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(later - 3600))))
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(later + 10))))
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testAKindThatIsNotSyncedIsLeftAlone() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.identities = [RDIdentity(username: "root", password: "secret")]
        mac.sync(&cloud, at: time(0))

        phone.syncsIdentities = false
        phone.identities = [RDIdentity(username: "local", password: "stays here")]
        phone.machines = [machine("beta")]
        phone.sync(&cloud, at: time(10))
        XCTAssertEqual(phone.identities.map(\.username), ["local"])

        // The identities stored by the Mac are still there for a third device.
        var pad = Device()
        pad.sync(&cloud, at: time(20))
        XCTAssertEqual(pad.identities.map(\.username), ["root"])
        XCTAssertEqual(Set(pad.machines.map(\.name)), ["alpha", "beta"])
    }

    func testWhatIsStoredDoesNotShowItsContents() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha-server-name")]
        mac.identities = [RDIdentity(username: "root", password: "a-very-secret-password")]
        mac.sync(&cloud, at: time(0))

        let stored = try XCTUnwrap(cloud)
        let text = String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(text.contains("alpha-server-name"))
        XCTAssertFalse(text.contains("a-very-secret-password"))
        XCTAssertFalse(text.contains("192.0.2.1"))
    }

    func testTamperedOrForeignDataIsRefused() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        var envelope = try JSONDecoder().decode(SyncEnvelope.self, from: XCTUnwrap(cloud))
        envelope.sealed[envelope.sealed.count - 1] ^= 1
        var tampered: Data? = try JSONEncoder().encode(envelope)
        guard case .locked = mac.sync(&tampered, at: time(10)) else { return XCTFail("expected locked") }

        // Fewer rounds than allowed: not derived, not written under.
        envelope.rounds = 1
        var weak: Data? = try JSONEncoder().encode(envelope)
        guard case .unreadable = mac.sync(&weak, at: time(20)) else { return XCTFail("expected unreadable") }

        envelope.version = SyncEnvelope.currentVersion + 1
        var newer: Data? = try JSONEncoder().encode(envelope)
        guard case .newer = mac.sync(&newer, at: time(30)) else { return XCTFail("expected newer") }

        var garbage: Data? = Data("not an envelope".utf8)
        guard case .unreadable = mac.sync(&garbage, at: time(40)) else { return XCTFail("expected unreadable") }
    }

    func testOpenTellsAWrongPassphraseFromDamagedData() throws {
        let plain = Data("the document".utf8)
        let key = SyncCipher.key(passphrase: "the passphrase", salt: SyncCipher.newSalt(), rounds: 1000)
        let sealed = try SyncCipher.seal(plain, with: key)
        let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: sealed)
        XCTAssertEqual(try SyncCipher.open(envelope, with: key), plain)

        let wrong = SyncCipher.key(passphrase: "another passphrase", salt: envelope.salt, rounds: envelope.rounds)
        XCTAssertThrowsError(try SyncCipher.open(envelope, with: wrong)) {
            XCTAssertEqual($0 as? SyncCipher.OpenError, .wrongPassphrase)
        }

        // Sealed under the right key, but what is inside is not a document:
        // it opens and then fails to decompress.
        var damaged = envelope
        damaged.sealed = try XCTUnwrap(CryptoKit.AES.GCM.seal(
            Data("not compressed".utf8), using: key.key, authenticating: SyncCipher.context
        ).combined)
        XCTAssertThrowsError(try SyncCipher.open(damaged, with: key)) {
            XCTAssertEqual($0 as? SyncCipher.OpenError, .corruptedData)
        }
    }

    func testDamagedStoredDataIsUnreadableNotLocked() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        var envelope = try JSONDecoder().decode(SyncEnvelope.self, from: XCTUnwrap(cloud))
        let key = try XCTUnwrap(mac.key)
        envelope.sealed = try XCTUnwrap(CryptoKit.AES.GCM.seal(
            Data("not compressed".utf8), using: key.key, authenticating: SyncCipher.context
        ).combined)
        var damaged: Data? = try JSONEncoder().encode(envelope)
        guard case .unreadable = mac.sync(&damaged, at: time(10)) else {
            return XCTFail("expected unreadable, not locked: another passphrase cannot help")
        }
    }

    func testAnOldDeletionIsForgotten() {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        mac.machines = []
        mac.sync(&cloud, at: time(10))
        XCTAssertEqual(mac.state.machines.count, 1)
        mac.sync(&cloud, at: time(10 + SyncMerge.tombstoneLifetime + 1))
        XCTAssertTrue(mac.state.machines.isEmpty)
    }
}
