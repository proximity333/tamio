//
//  WebDAVSync.swift
//  TamioModule
//
//  Keeps the servers, identities (their passwords and private keys included),
//  snippets, port forwards, known hosts and settings the same on every device,
//  through one file on a WebDAV server. The file is sealed here first, under a
//  passphrase the user chooses, so the server holds only ciphertext.
//

import Combine
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public final class WebDAVSync: ObservableObject {
    public static let shared = WebDAVSync()

    public enum Status: Equatable {
        case off
        /// Not enough has been entered to sync; the sentence says what.
        case needsSetup(String)
        case syncing
        case synced(Date)
        /// The passphrase does not open what is on the server.
        case locked
        /// What is on the server cannot be read at all.
        case unreadable
        case failed(String)
    }

    /// The result of the Test Connection button, apart from the sync status.
    public enum ConnectionTest: Equatable {
        case idle
        case testing
        case ok
        case failed(String)
    }

    @Published public private(set) var status: Status = .off
    @Published public private(set) var connectionTest: ConnectionTest = .idle
    @Published public private(set) var isOn = false

    /// The file's address on the server, for example
    /// https://dav.example.com/tamio/sync.bin.
    @Published public var serverURL: String {
        didSet {
            guard serverURL != oldValue else { return }
            defaults.set(serverURL, forKey: Key.url)
            configureChanged()
        }
    }

    @Published public var username: String {
        didSet {
            guard username != oldValue else { return }
            defaults.set(username, forKey: Key.username)
            configureChanged()
        }
    }

    /// The WebDAV account's password. Kept encrypted with the app's key.
    @Published public var password: String {
        didSet {
            guard password != oldValue else { return }
            store.storeEncryptedDefault(to: .webDAVPassword, with: Secret(value: password))
            configureChanged()
        }
    }

    @Published public var syncsServers: Bool {
        didSet { kindChanged(syncsServers, oldValue, Key.servers) { $0.machines = [:] } }
    }

    @Published public var syncsIdentities: Bool {
        didSet { kindChanged(syncsIdentities, oldValue, Key.identities) { $0.identities = [:] } }
    }

    @Published public var syncsSnippets: Bool {
        didSet { kindChanged(syncsSnippets, oldValue, Key.snippets) { $0.snippets = [:] } }
    }

    @Published public var syncsPortForwards: Bool {
        didSet { kindChanged(syncsPortForwards, oldValue, Key.portForwards) { $0.portForwards = [:] } }
    }

    @Published public var syncsKnownHosts: Bool {
        didSet { kindChanged(syncsKnownHosts, oldValue, Key.knownHosts) { $0.knownHosts = [:] } }
    }

    @Published public var syncsActivity: Bool {
        didSet { kindChanged(syncsActivity, oldValue, Key.activity) { _ in } }
    }

    @Published public var syncsSettings: Bool {
        didSet { kindChanged(syncsSettings, oldValue, Key.settings) { $0.preferences = [:] } }
    }

    /// The preferences in Settings that sync, handed over by the app before
    /// `start`.
    public var preferences: [SyncedPreference] = [] {
        didSet { preferenceValues = readPreferences() }
    }

    public static let minimumPassphraseLength = 8
    /// No WebDAV server pushes changes, so while sync is on Tamio asks it this
    /// often; changes here are also sent two seconds after they settle, and on
    /// the app becoming active again.
    public static let pollInterval: UInt64 = 180_000_000_000

    /// A kind turned on or off: what this device knew of it is forgotten, so
    /// turned on again it starts from what is stored.
    private func kindChanged(_ value: Bool, _ old: Bool, _ key: String, forget: (inout SyncState) -> Void) {
        guard value != old else { return }
        defaults.set(value, forKey: key)
        forget(&state)
        generation += 1
        sync()
    }

    private enum Key {
        static let on = "sb.moe.tamio.webdav.enabled"
        static let url = "sb.moe.tamio.webdav.url"
        static let username = "sb.moe.tamio.webdav.username"
        static let servers = "sb.moe.tamio.webdav.servers"
        static let identities = "sb.moe.tamio.webdav.identities"
        static let snippets = "sb.moe.tamio.webdav.snippets"
        static let portForwards = "sb.moe.tamio.webdav.portForwards"
        static let knownHosts = "sb.moe.tamio.webdav.knownHosts"
        static let activity = "sb.moe.tamio.webdav.activity"
        static let settings = "sb.moe.tamio.webdav.settings"
    }

    private struct Secret: Codable {
        var value: String
    }

    private let store = TamioStore.shared
    private let defaults = UserDefaults.standard
    /// The passphrase that seals the document. Kept encrypted with the app's
    /// key, like the WebDAV password.
    @Published private(set) var passphrase: String?
    private var state = SyncState() {
        didSet {
            guard state != oldValue else { return }
            store.storeEncryptedDefault(to: .webDAVSyncState, with: state)
        }
    }

    /// What `preferences` read last, to tell a change to one of them from
    /// the many other changes to the defaults.
    private var preferenceValues: [PreferenceItem] = []
    private var key: SyncCipher.Key?
    private var running = false
    private var pending = false
    /// A delete of the server's file is under way; no round may put it back.
    private var deleting = false
    private var replacesNext = false
    /// The passphrase in use until a pending change of it, so that round can
    /// still open what is on the server when the key itself is not cached.
    private var replacingPassphrase: String?
    private var started = false
    /// Counts the changes to what a round reads, to tell a round that was
    /// overtaken by one.
    private var generation = 0
    private var observers: Set<AnyCancellable> = []
    private var poll: Task<Void, Never>?
    private var configureTask: Task<Void, Never>?
    private var roundTask: Task<Void, Never>?
    /// Tells the result of an older Test Connection from the current one.
    private var testToken = UUID()

    private init() {
        defaults.register(defaults: [
            Key.servers: true, Key.identities: true, Key.snippets: true,
            Key.portForwards: true, Key.knownHosts: true, Key.activity: true,
            Key.settings: true,
        ])
        isOn = defaults.bool(forKey: Key.on)
        serverURL = defaults.string(forKey: Key.url) ?? ""
        username = defaults.string(forKey: Key.username) ?? ""
        password = store.readEncryptedDefault(from: .webDAVPassword, Secret(value: ""))?.value ?? ""
        let savedPassphrase = store.readEncryptedDefault(from: .webDAVPassphrase, Secret(value: ""))?.value
        passphrase = savedPassphrase.flatMap { $0.isEmpty ? nil : $0 }
        syncsServers = defaults.bool(forKey: Key.servers)
        syncsIdentities = defaults.bool(forKey: Key.identities)
        syncsSnippets = defaults.bool(forKey: Key.snippets)
        syncsPortForwards = defaults.bool(forKey: Key.portForwards)
        syncsKnownHosts = defaults.bool(forKey: Key.knownHosts)
        syncsActivity = defaults.bool(forKey: Key.activity)
        syncsSettings = defaults.bool(forKey: Key.settings)
        if let saved = store.readEncryptedDefault(from: .webDAVSyncState, SyncState()) {
            state = saved
        }
    }

    /// Why the address and account cannot be used, in a sentence; nil when they
    /// can. The passphrase is not part of this: a connection test is only the
    /// server.
    public var connectionProblem: String? {
        if !TamioStore.savesChanges {
            return String(localized: "Tamio could not read its key from the keychain, so nothing is saved or synced.")
        }
        if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter the address of the file on your WebDAV server.")
        }
        guard let configuration else {
            return String(localized: "Enter a valid https:// address to the file.")
        }
        return configuration.problem
    }

    /// Why sync cannot be turned on yet, in a sentence; nil when it can.
    public var setupProblem: String? {
        if let problem = connectionProblem {
            return problem
        }
        if passphrase?.isEmpty ?? true {
            return String(localized: "Choose a passphrase to encrypt what is stored.")
        }
        return nil
    }

    // MARK: - Connection test

    /// Reads the file, or finds that it is not there yet, to tell whether the
    /// address and account work. It changes nothing.
    public func testConnection() {
        let token = UUID()
        testToken = token
        if let problem = connectionProblem {
            connectionTest = .failed(problem)
            return
        }
        guard let configuration else {
            connectionTest = .failed(String(localized: "Enter a valid https:// address to the file."))
            return
        }
        connectionTest = .testing
        Task { [weak self] in
            do {
                let data = try await WebDAVClient(configuration: configuration).read()
                guard let self, testToken == token else { return }
                if let data, (try? JSONDecoder().decode(SyncEnvelope.self, from: data)) == nil {
                    connectionTest = .failed(String(localized: "The server answered, but the file is not a Tamio sync file."))
                    return
                }
                connectionTest = .ok
            } catch {
                guard let self, testToken == token else { return }
                connectionTest = .failed(error.localizedDescription)
            }
        }
    }

    /// The passphrase in use, for the user to see or type on another device.
    public var currentPassphrase: String? {
        passphrase
    }

    // MARK: - Settings

    /// Turns sync on with the settings and passphrase entered.
    public func turnOn() {
        if let problem = setupProblem {
            status = .needsSetup(problem)
            return
        }
        guard !isOn else {
            sync()
            return
        }
        isOn = true
        defaults.set(true, forKey: Key.on)
        generation += 1
        startPolling()
        sync()
    }

    /// Stops syncing here. What is on the server, and on this device, stays.
    public func turnOff() {
        isOn = false
        defaults.set(false, forKey: Key.on)
        poll?.cancel()
        poll = nil
        configureTask?.cancel()
        configureTask = nil
        roundTask?.cancel()
        roundTask = nil
        running = false
        pending = false
        deleting = false
        replacesNext = false
        replacingPassphrase = nil
        status = .off
    }

    /// Sets or changes the passphrase that seals the document. Changing it
    /// while sync is on re-seals the server's file under the new one, after
    /// merging what is there if the old key is still known.
    public func setPassphrase(_ new: String) {
        guard new.count >= Self.minimumPassphraseLength, new != passphrase else { return }
        let old = key
        let oldPassphrase = passphrase
        passphrase = new
        store.storeEncryptedDefault(to: .webDAVPassphrase, with: Secret(value: new))
        if isOn {
            // The old key, or the old passphrase, reads the server's file one
            // last time in this round.
            key = old
            replacingPassphrase = oldPassphrase
            replacesNext = true
            generation += 1
            sync()
        } else {
            key = nil
        }
    }

    /// Enters the passphrase that opens the file already on the server. It
    /// does not replace that file: a wrong one is simply refused.
    public func enterPassphrase(_ new: String) {
        guard new.count >= Self.minimumPassphraseLength, new != passphrase else { return }
        passphrase = new
        key = nil
        replacesNext = false
        replacingPassphrase = nil
        store.storeEncryptedDefault(to: .webDAVPassphrase, with: Secret(value: new))
        if isOn {
            sync()
        }
    }

    /// Removes the file from the server and stops syncing here. The settings,
    /// passphrase and this device's data stay, so sync can be turned on again.
    public func deleteStoredData() {
        guard let configuration else {
            turnOff()
            return
        }
        roundTask?.cancel()
        roundTask = nil
        running = false
        deleting = true
        let client = WebDAVClient(configuration: configuration)
        Task { [weak self] in
            do {
                try await client.write(nil)
            } catch {
                self?.deleting = false
                self?.status = .failed(error.localizedDescription)
                return
            }
            self?.turnOff()
        }
    }

    // MARK: - Running

    /// Call once the app has launched.
    public func start() {
        guard !started else { return }
        started = true
        let changes = Publishers.MergeMany(
            store.$machineGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$identityGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$snippetGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$portForwardGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: KnownHosts.didChange).map { _ in () }.eraseToAnyPublisher(),
            AgentServer.shared.log.$entries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .filter { [weak self] _ in
                    MainActor.assumeIsolated { self?.preferencesChanged() ?? false }
                }
                .map { _ in () }
                .eraseToAnyPublisher()
        )
        .share()
        changes
            .sink { [weak self] in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.generation += 1 }
            }
            .store(in: &observers)
        changes
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.sync() }
            }
            .store(in: &observers)
        #if canImport(UIKit)
            let becameActive = UIApplication.didBecomeActiveNotification
        #else
            let becameActive = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: becameActive)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
            .store(in: &observers)
        if isOn {
            startPolling()
            sync()
        }
    }

    /// One round: read the server's file, merge, write it back if it changed.
    public func sync() {
        guard isOn else {
            status = .off
            return
        }
        guard !deleting else { return }
        if let problem = setupProblem {
            status = .needsSetup(problem)
            return
        }
        guard let configuration else {
            status = .needsSetup(setupProblem ?? String(localized: "Enter a valid https:// address to the file."))
            return
        }
        if let problem = configuration.problem {
            status = .failed(problem)
            return
        }
        guard let passphrase, !passphrase.isEmpty else {
            status = .needsSetup(String(localized: "Choose a passphrase to encrypt what is stored."))
            return
        }
        if running {
            pending = true
            return
        }
        running = true
        if case .synced = status {} else {
            status = .syncing
        }
        let read = generation
        let replacing = replacesNext
        let oldPassphrase = replacingPassphrase
        replacesNext = false
        replacingPassphrase = nil

        roundTask = Task { [weak self] in
            guard let self else { return }
            let client = WebDAVClient(configuration: configuration)
            let remote: Data?
            do {
                remote = try await client.read()
            } catch {
                running = false
                pending = false
                if isOn, !Task.isCancelled {
                    status = .failed(error.localizedDescription)
                }
                return
            }
            guard isOn, !Task.isCancelled else {
                running = false
                return
            }
            let input = makeInput(
                remote: remote, replacesRemote: replacing, replacingPassphrase: oldPassphrase
            )
            let outcome = await Task.detached(priority: .utility) { SyncSession.run(input) }.value
            guard isOn, !Task.isCancelled else {
                running = false
                return
            }
            if read == generation {
                await finish(outcome, client: client)
            } else {
                // Something was edited meanwhile: what the round worked out
                // is about data that is gone.
                replacesNext = replacesNext || replacing
                if replacingPassphrase == nil {
                    replacingPassphrase = oldPassphrase
                }
                pending = true
            }
            running = false
            if pending {
                pending = false
                sync()
            }
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.sync()
            }
        }
    }

    private func configureChanged() {
        guard isOn else {
            testToken = UUID()
            connectionTest = .idle
            return
        }
        // A round already reading an older address or password must not put
        // its result in place.
        generation += 1
        testToken = UUID()
        connectionTest = .idle
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private var configuration: WebDAVConfiguration? {
        let address = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme != nil else { return nil }
        return WebDAVConfiguration(url: url, username: username, password: password)
    }

    private func makeInput(
        remote: Data?, replacesRemote: Bool, replacingPassphrase: String?
    ) -> SyncInput {
        var input = SyncInput(
            machines: store.machineGroup.machines,
            identities: store.identityGroup.identities,
            state: state,
            passphrase: passphrase ?? "",
            remote: remote,
            key: key
        )
        input.snippets = store.snippetGroup.snippets
        input.portForwards = store.portForwardGroup.forwards
        input.knownHosts = KnownHosts.shared.syncEntries()
        input.preferences = readPreferences()
        input.preferenceKeys = Set(preferences.map(\.key))
        input.activity = AgentServer.shared.log.entries
        input.activityClearedAt = AgentServer.shared.log.clearedAt
        input.syncsMachines = syncsServers
        input.syncsIdentities = syncsIdentities
        input.syncsSnippets = syncsSnippets
        input.syncsPortForwards = syncsPortForwards
        input.syncsKnownHosts = syncsKnownHosts
        input.syncsPreferences = syncsSettings
        input.syncsActivity = syncsActivity
        input.replacesRemote = replacesRemote
        input.replacingPassphrase = replacingPassphrase
        return input
    }

    private func readPreferences() -> [PreferenceItem] {
        preferences.compactMap { preference in
            preference.read().map { PreferenceItem(key: preference.key, value: $0) }
        }
    }

    /// True when a synced preference changed since it was last read.
    private func preferencesChanged() -> Bool {
        let values = readPreferences()
        guard values != preferenceValues else { return false }
        preferenceValues = values
        return true
    }

    private func finish(_ outcome: SyncOutcome, client: WebDAVClient) async {
        guard isOn else { return }
        switch outcome {
        case .locked:
            status = .locked
        case .unreadable:
            status = .unreadable
        case .newer:
            status = .failed(String(localized: "What is on the server was written by a newer version of Tamio. Update Tamio on this device."))
        case let .done(done):
            key = done.key
            if !done.machines.isEmpty {
                var group = store.machineGroup
                for change in done.machines {
                    switch change {
                    case let .put(machine): group.insert(machine)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.machineGroup = group
            }
            if !done.identities.isEmpty {
                // Identities carry the user names, passwords and private
                // keys: they travel in the sealed document like everything else.
                var group = store.identityGroup
                for change in done.identities {
                    switch change {
                    case let .put(identity): group.insert(identity)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.identityGroup = group
            }
            if !done.snippets.isEmpty {
                var group = store.snippetGroup
                for change in done.snippets {
                    switch change {
                    case let .put(snippet): group.insert(snippet)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.snippetGroup = group
            }
            if !done.portForwards.isEmpty {
                var group = store.portForwardGroup
                for change in done.portForwards {
                    switch change {
                    case let .put(forward): group.insert(forward)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.portForwardGroup = group
            }
            if !done.knownHosts.isEmpty {
                var put: [KnownHostEntry] = []
                var removed: [UUID] = []
                for change in done.knownHosts {
                    switch change {
                    case let .put(entry): put.append(entry)
                    case let .remove(id): removed.append(id)
                    }
                }
                KnownHosts.shared.applySynced(put: put, remove: removed)
            }
            for change in done.preferences {
                // A preference reset elsewhere keeps its value here: a
                // device with no value has nothing better to offer.
                guard case let .put(item) = change,
                      let preference = preferences.first(where: { $0.key == item.key })
                else { continue }
                preference.write(item.value)
            }
            if !done.preferences.isEmpty {
                preferenceValues = readPreferences()
            }
            // Another device's activity is added, not recorded: it is not
            // sent on as this device's own.
            for entry in done.activity {
                AgentServer.shared.log.merge(entry)
            }
            state = done.state
            if let upload = done.upload {
                guard isOn else { return }
                do {
                    try await client.write(upload)
                } catch {
                    if isOn {
                        status = .failed(error.localizedDescription)
                    }
                    return
                }
            }
            status = .synced(Date())
        }
    }
}
