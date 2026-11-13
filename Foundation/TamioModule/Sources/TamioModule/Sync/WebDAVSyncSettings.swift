//
//  WebDAVSyncSettings.swift
//  TamioModule
//
//  The rows of Settings › General › WebDAV Sync, the same on the Mac and on iOS.
//

import SwiftUI
import TamioDesign
#if canImport(UIKit)
    import UIKit
#endif

public struct WebDAVSyncSettings: View {
    @ObservedObject private var sync = WebDAVSync.shared
    @State private var askingPassphrase = false
    @State private var sheetPurpose = WebDAVPassphraseSheet.Purpose.set
    @State private var confirmsDelete = false
    /// The passphrase, while the user has it showing.
    @State private var shown: String?

    public init() {}

    public var body: some View {
        RXDividedStack {
            RXFormRow("Sync with WebDAV", description: "\(sync.isOn ? description : (sync.setupProblem ?? description))") {
                Toggle("Sync with WebDAV", isOn: Binding(
                    get: { sync.isOn },
                    set: { on in
                        if on {
                            sync.turnOn()
                        } else {
                            sync.turnOff()
                        }
                    }
                ))
                .labelsHidden()
                .rxSwitchToggle()
                .tint(.rxAccent)
                #if os(macOS) || targetEnvironment(macCatalyst)
                    .controlSize(.small)
                #endif
                    .disabled(!sync.isOn && sync.setupProblem != nil)
            }

            RXFormRow("Sync", description: "\(actionsDescription)") {
                HStack(spacing: RX.Space.s2) {
                    if sync.connectionTest == .testing || sync.status == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Test Connection") { sync.testConnection() }
                        .buttonStyle(.rx(size: .small))
                        .disabled(sync.connectionProblem != nil || sync.connectionTest == .testing)
                    Button("Sync Now") { sync.sync() }
                        .buttonStyle(.rx(size: .small))
                        .disabled(!sync.isOn || sync.status == .syncing)
                        .help(sync.isOn ? Text("Sync Now") : Text("Turn on sync first."))
                }
            }

            RXFormRow("File", description: "The file's full address on your WebDAV server. Tamio creates its folder if the server allows it.") {
                TextField("https://dav.example.com/tamio/sync.bin", text: $sync.serverURL)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                #endif
            }
            RXFormRow("User name", description: "The WebDAV account's user name. Leave both empty for a server that needs no sign-in.") {
                TextField("", text: $sync.username)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            }
            RXFormRow("Password", description: "Kept encrypted on this device. Sent to the server over https://; a local http:// address sends it unencrypted.") {
                SecureField("", text: $sync.password)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
            }
            RXFormRow("Encryption passphrase", description: "\(encryptionDescription)") {
                HStack(spacing: RX.Space.s2) {
                    if let passphrase = sync.currentPassphrase {
                        Button(shown == nil ? String(localized: "Show") : String(localized: "Hide")) {
                            shown = shown == nil ? passphrase : nil
                        }
                        .buttonStyle(.rx(size: .small))
                        #if canImport(UIKit)
                            if shown != nil {
                                Button("Copy") { UIPasteboard.general.string = passphrase }
                                    .buttonStyle(.rx(size: .small))
                            }
                        #endif
                    }
                    Button(passphraseButtonTitle) {
                        sheetPurpose = intendedPassphrasePurpose
                        askingPassphrase = true
                    }
                    .buttonStyle(.rx(size: .small))
                }
            }

            if sync.isOn {
                RXFormRow("Status", description: "\(statusText)") {
                    if sync.status == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                SwitchRow("Servers", description: "Addresses, names, groups and comments.", isOn: $sync.syncsServers)
                SwitchRow(
                    "Identities",
                    description: "User names, passwords and private keys.",
                    isOn: $sync.syncsIdentities
                )
                SwitchRow("Snippets", description: "Saved commands and their groups.", isOn: $sync.syncsSnippets)
                SwitchRow("Port forwards", description: "Local and remote forwards, and the server each uses.", isOn: $sync.syncsPortForwards)
                SwitchRow(
                    "Known hosts",
                    description: "The servers' keys: one trusted on a device is trusted on the others.",
                    isOn: $sync.syncsKnownHosts
                )
                SwitchRow(
                    "Settings",
                    description: "Appearance, the terminal's configuration, sessions, hidden files, the connection timeout and live status.",
                    isOn: $sync.syncsSettings
                )
                SwitchRow(
                    "Agent activity",
                    description: "What agents did on each server, so agents on other devices know.",
                    isOn: $sync.syncsActivity
                )
                RXFormRow("Data on the server", description: "Delete the encrypted file and stop syncing here.") {
                    Button("Delete…") { confirmsDelete = true }
                        .buttonStyle(.rx(size: .small))
                }
            }
        }
        .sheet(isPresented: $askingPassphrase) {
            WebDAVPassphraseSheet(purpose: sheetPurpose) { passphrase in
                if sheetPurpose == .unlock {
                    sync.enterPassphrase(passphrase)
                } else {
                    sync.setPassphrase(passphrase)
                }
            }
        }
        .alert("Delete what Tamio keeps on the server?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { sync.deleteStoredData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Your servers and identities stay on this device. A device that still syncs \
            will store its own again, so turn sync off there too.
            """)
        }
    }

    private var fieldWidth: CGFloat {
        #if os(macOS) || targetEnvironment(macCatalyst)
            320
        #else
            260
        #endif
    }

    private var intendedPassphrasePurpose: WebDAVPassphraseSheet.Purpose {
        if sync.status == .locked {
            return .unlock
        }
        return sync.currentPassphrase == nil ? .set : .change
    }

    private var passphraseButtonTitle: String {
        switch intendedPassphrasePurpose {
        case .set: String(localized: "Set…")
        case .change: String(localized: "Change…")
        case .unlock: String(localized: "Enter…")
        }
    }

    private var description: String {
        String(localized: """
        Your servers, identities and settings in one file on your WebDAV server, sealed on this \
        device before they leave it. Passwords and private keys travel inside the sealed file. \
        The server holds only ciphertext.
        """)
    }

    private var encryptionDescription: String {
        if let shown {
            return String(localized: "\(shown) — type it on your other devices.")
        }
        if sync.currentPassphrase == nil {
            return String(localized: "Choose a passphrase. It is the only key to what is on the server, and cannot be recovered if you forget it.")
        }
        return String(localized: "It opens the file on the server. Use the same one on your other devices.")
    }

    private var actionsDescription: String {
        if let problem = sync.connectionProblem {
            return problem
        }
        switch sync.connectionTest {
        case .idle:
            let minutes = Int(WebDAVSync.pollInterval / 60_000_000_000)
            return String(localized: "Test the address and password, or sync now. While on, Tamio checks the server every \(minutes) minutes, after each change, and when the app becomes active.")
        case .testing:
            return String(localized: "Checking the server…")
        case .ok:
            return String(localized: "Connected. The server answered.")
        case let .failed(reason):
            return reason
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: ""
        case let .needsSetup(reason): reason
        case .syncing: String(localized: "Syncing…")
        case let .synced(date):
            String(localized: "Up to date. Last synced at \(date.formatted(date: .omitted, time: .shortened)).")
        case .locked:
            String(localized: "The passphrase here does not open what is on the server. Enter the one your other devices use.")
        case .unreadable:
            String(localized: "What is on the server cannot be read. Replace it with this device's data to go on.")
        case let .failed(reason): reason
        }
    }
}

private struct WebDAVPassphraseSheet: View {
    enum Purpose: Equatable {
        /// The first passphrase for this device.
        case set
        /// Choose a new one and re-seal what is on the server under it.
        case change
        /// The server already holds data: enter the passphrase that opens it.
        case unlock
    }

    let purpose: Purpose
    let done: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var again = ""
    @FocusState private var focused: Bool

    private var lengthProblem: String? {
        guard !passphrase.isEmpty, passphrase.count < WebDAVSync.minimumPassphraseLength else { return nil }
        return String(localized: "At least \(WebDAVSync.minimumPassphraseLength) characters.")
    }

    private var againProblem: String? {
        guard purpose != .unlock, !again.isEmpty, again != passphrase else { return nil }
        return String(localized: "The two do not match.")
    }

    private var ready: Bool {
        passphrase.count >= WebDAVSync.minimumPassphraseLength && (purpose == .unlock || again == passphrase)
    }

    private var title: String {
        switch purpose {
        case .set: String(localized: "Choose a Passphrase")
        case .change: String(localized: "Change the Passphrase")
        case .unlock: String(localized: "Enter Your Passphrase")
        }
    }

    private var lead: String {
        switch purpose {
        case .set:
            String(localized: """
            It encrypts your servers, identities, passwords and private keys before they leave this \
            device. Type the same one on your other devices. It cannot be recovered if you forget it.
            """)
        case .change:
            String(localized: """
            What is on the server is sealed under the new passphrase. Your other devices will need it \
            before they can sync again. If this device cannot open what is there with the old one, \
            what it has takes its place.
            """)
        case .unlock:
            String(localized: "What is on the server is sealed with a passphrase from one of your other devices. Enter it here.")
        }
    }

    var body: some View {
        SheetScaffold(title, lead: "\(lead)") {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                RXField("Passphrase", error: lengthProblem) {
                    SecureField("", text: $passphrase)
                        .textFieldStyle(.rx)
                        .focused($focused)
                        .onSubmit(submit)
                }
                if purpose != .unlock {
                    RXField("Again", error: againProblem) {
                        SecureField("", text: $again)
                            .textFieldStyle(.rx)
                            .onSubmit(submit)
                    }
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(actionTitle, action: submit)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { focused = true }
    }

    private var actionTitle: String {
        switch purpose {
        case .set: String(localized: "Set")
        case .change: String(localized: "Change")
        case .unlock: String(localized: "Unlock")
        }
    }

    private func submit() {
        guard ready else { return }
        done(passphrase)
        dismiss()
    }
}
