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
    @State private var confirmation: Confirmation?
    /// The passphrase, while the user has it showing.
    @State private var shown: String?

    private enum Confirmation: String, Identifiable {
        case download
        case delete
        var id: String {
            rawValue
        }
    }

    public init() {}

    public var body: some View {
        RXDividedStack {
            RXFormRow("Automatic upload", description: "\(uploadDescription)") {
                Toggle("Automatic upload", isOn: Binding(
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

            RXFormRow("Address", description: "The WebDAV server's address, such as https://dav.example.com/.") {
                TextField("https://dav.example.com/", text: $sync.serverURL)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                #endif
            }
            RXFormRow("Remote path", description: "The file's path under that address. Tamio creates its folder if the server allows it.") {
                TextField("Tamio/sync.bin", text: $sync.remotePath)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
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
            SwitchRow(
                "Remember password",
                description: "Kept encrypted on this device with Tamio's key; without it, enter the password again after Tamio restarts.",
                isOn: $sync.remembersPassword
            )
            RXFormRow("User-Agent", description: "Optional. Some servers require a client they recognize; empty sends Tamio's own.") {
                TextField("", text: $sync.userAgent)
                    .textFieldStyle(.rx)
                    .frame(width: fieldWidth)
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
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
                RXFormRow("Every", description: "How often automatic upload runs.") {
                    HStack(spacing: RX.Space.s2) {
                        Picker("", selection: $sync.uploadInterval) {
                            ForEach(WebDAVSync.uploadIntervals, id: \.self) { minutes in
                                Text("\(minutes)").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Text("minutes")
                    }
                }
            }
            if sync.status != .off {
                RXFormRow("Status", description: "\(statusText)") {
                    if sync.status == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            RXFormRow("Last successful sync", description: "\(lastSyncText)") {
                EmptyView()
            }
            RXFormRow("Connection", description: "\(connectionDescription)") {
                EmptyView()
            }

            HStack(spacing: RX.Space.s2) {
                if sync.connectionTest == .testing || sync.status == .syncing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Test Connection") { sync.testConnection() }
                    .buttonStyle(.rx)
                    .disabled(sync.connectionProblem != nil || sync.connectionTest == .testing)
                Button("Download") { confirmation = .download }
                    .buttonStyle(.rx)
                    .disabled(sync.setupProblem != nil || sync.status == .syncing)
                Button("Upload") { sync.upload() }
                    .buttonStyle(.rxPrimary)
                    .disabled(sync.setupProblem != nil || sync.status == .syncing)
            }
            .padding(.vertical, RX.Space.s3)

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

            if sync.connectionProblem == nil {
                RXFormRow("Data on the server", description: "Delete the encrypted file and stop automatic upload.") {
                    Button("Delete…") { confirmation = .delete }
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
        .alert(item: $confirmation) { choice in
            switch choice {
            case .download:
                Alert(
                    title: Text("Download from the server?"),
                    message: Text("What is there is merged into this device. Items changed more recently there replace this device's copies; nothing here is uploaded."),
                    primaryButton: .destructive(Text("Download")) { sync.download() },
                    secondaryButton: .cancel()
                )
            case .delete:
                Alert(
                    title: Text("Delete what Tamio keeps on the server?"),
                    message: Text("""
                    Your servers and identities stay on this device. A device that still syncs \
                    will store its own again, so turn sync off there too.
                    """),
                    primaryButton: .destructive(Text("Delete")) { sync.deleteStoredData() },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var fieldWidth: CGFloat {
        #if os(macOS) || targetEnvironment(macCatalyst)
            320
        #else
            260
        #endif
    }

    private var uploadDescription: String {
        if let problem = sync.setupProblem {
            return problem
        }
        if sync.isOn {
            let minutes = sync.uploadInterval
            return String(localized: "Servers, identities (passwords and private keys), snippets and settings go to one sealed file on your WebDAV server, merging what is already there. It runs now and then every \(minutes) minutes while Tamio is open; Download is always manual.")
        }
        return String(localized: "Servers, identities (passwords and private keys), snippets and settings go to one sealed file on your WebDAV server, merging what is already there. Automatic upload is off; use Upload and Download below.")
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

    private var encryptionDescription: String {
        if let shown {
            return String(localized: "\(shown) — type it on your other devices.")
        }
        if sync.currentPassphrase == nil {
            return String(localized: "The file is sealed under this passphrase. If another device already uses this file, enter the passphrase it uses; otherwise choose one and keep it safe, as it cannot be recovered.")
        }
        return String(localized: "It opens the file on the server. Use the same one on your other devices.")
    }

    private var connectionDescription: String {
        if let problem = sync.connectionProblem {
            return problem
        }
        switch sync.connectionTest {
        case .idle:
            return String(localized: "Tests the address and account. It does not upload or download.")
        case .testing:
            return String(localized: "Checking the server…")
        case .ok:
            return String(localized: "Connected. The server answered.")
        case let .failed(reason):
            return reason
        }
    }

    private var lastSyncText: String {
        guard let date = sync.lastSynced else {
            return String(localized: "Never")
        }
        return date.formatted(date: .abbreviated, time: .standard)
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
            device. If this file already exists on your other devices, enter the passphrase they use; \
            otherwise choose one. It cannot be recovered if you forget it.
            """)
        case .change:
            String(localized: """
            The next upload seals what is on the server under the new passphrase. Your other devices \
            will need it before they can open the file. If this device cannot open what is there with \
            the old one, what it has takes its place.
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
