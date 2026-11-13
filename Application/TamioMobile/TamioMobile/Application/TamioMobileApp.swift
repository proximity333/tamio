//
//  TamioMobileApp.swift
//  TamioMobile
//
//  Created by Lakr Aream on 2022/3/2.
//

import CodeEditorUI
import MachineStatusView
import SwiftUI
import TamioModule
import TamioTerminal

@main
struct TamioMobileApp: App {
    @StateObject private var store = TamioStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            NSLog("\nCommand Arguments:\n" + CommandLine.arguments.joined(separator: "\n"))
        #endif

        // Shared file-transfer core lives in TamioModule; register the
        // platform UI handler it delegates to.
        FileTransferInterface.uiHandler = IOSFileTransferUIHandler()

        _ = LogRedirect.shared
        _ = TamioStore.shared
        // iCloud sync is hidden while WebDAV is the offered backend; its
        // CloudSync code stays in TamioModule.
        WebDAVSync.shared.preferences = SyncedSettings.all
        WebDAVSync.shared.start()
        // Every server card shows live status without opening a monitor.
        LiveStatusCenter.shared.start()
        PortForwardBackend.shared.reportProblem = { UIBridge.presentError(with: $0) }

        #if DEBUG
            Self.addPreviewServer()
        #endif
        NSLog("static main completed")
    }

    #if DEBUG
        /// A debug build started with TAMIO_PREVIEW_SERVER=user@host:port and
        /// TAMIO_PREVIEW_KEY=<private key path> has that server, with that
        /// key, in its store: the simulator can then be run against a
        /// throwaway sshd without typing into it.
        private static func addPreviewServer() {
            let environment = ProcessInfo.processInfo.environment
            guard let server = environment["TAMIO_PREVIEW_SERVER"], let keyPath = environment["TAMIO_PREVIEW_KEY"],
                  let command = SSHCommandReader(command: "ssh \(server)")
            else { return }
            let store = TamioStore.shared
            guard !store.machineGroup.machines.contains(where: { $0.remoteAddress == command.remoteAddress && $0.remotePort == command.remotePort }),
                  let privateKey = try? String(contentsOfFile: keyPath, encoding: .utf8)
            else { return }
            let publicKey = (try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8)) ?? ""
            var identity = RDIdentity(privateKey: privateKey, publicKey: publicKey, authenticAutomatically: true)
            identity.name = "Preview key"
            var machine = RDMachine(remoteAddress: command.remoteAddress, remotePort: command.remotePort, name: "Preview server")
            machine.username = command.username
            machine.associatedIdentity = identity.id.uuidString
            store.identityGroup.insert(identity)
            store.machineGroup.insert(machine)
            // A snippet and a forward through it, so those pages have rows.
            if store.snippetGroup.snippets.isEmpty {
                var snippet = RDSnippet()
                snippet.name = "Disk usage"
                snippet.group = "Checks"
                snippet.comment = "Every mounted file system"
                snippet.code = "df -h"
                store.snippetGroup.insert(snippet)
            }
            if store.portForwardGroup.forwards.isEmpty {
                var forward = RDPortForward()
                forward.forwardOrientation = .listenLocal
                forward.bindPort = 8080
                forward.usingMachine = machine.id
                forward.targetHost = "127.0.0.1"
                forward.targetPort = 80
                store.portForwardGroup.insert(forward)
            }
            // TAMIO_PREVIEW_OPEN=terminal opens its terminal once the window is up.
            if environment["TAMIO_PREVIEW_OPEN"] == "terminal" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    TerminalManager.shared.begin(for: machine.id)
                }
            }
        }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // The shared server views (cards, table, inspector) act through these.
                .environment(\.serverActions, .ios)
                #if DEBUG
                .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.environment["TAMIO_PREVIEW_EDITOR"] != nil)) {
                    EditorPreviewScreen()
                }
                #endif
                .onAppear {
                    // Warm the shared WebKit process pool so the first
                    // editor (snippet or remote file) skips the cold
                    // start. SCodeEditor builds its web view lazily now,
                    // so nothing else pays this at launch; the hidden view
                    // gets a second to finish its page load before being
                    // released, or the load would be cancelled and the
                    // warm-up defeated.
                    let prewarm = CodeEditorView()
                    AppearancePreference.applyStored()
                    checkAgreement()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withExtendedLifetime(prewarm) {
                            debugPrint("editor \(prewarm) prewarm done")
                        }
                    }
                }
                .onChange(of: store.licenseAgreed) { _ in
                    checkAgreement()
                }
                // The quiet status sessions run only while the app is on
                // screen; in the background iOS would cut them off anyway.
                .onChange(of: scenePhase) { phase in
                    LiveStatusCenter.shared.setWindowVisible(phase == .active)
                }
        }
    }

    func checkAgreement() {
        guard !store.licenseAgreed else {
            return
        }
        let host = UIHostingController(rootView: AgreementView())
        host.preferredContentSize = preferredPopOverSize
        host.isModalInPresentation = true
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = .formSheet
        // At launch the window is not in the hierarchy yet; the queue
        // replays the present once it is.
        PresentationQueue.present(next: host)
    }
}
