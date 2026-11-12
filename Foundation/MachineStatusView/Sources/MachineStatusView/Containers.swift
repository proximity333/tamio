//
//  Containers.swift
//  MachineStatusView
//
//  A server's Docker containers, read over its monitor session: the reading
//  kept per server, the rows it draws, the inspector's Containers tab and the
//  monitor's Containers card. Both surfaces show the same rows and share one
//  reading, so moving between them shows the last one at once while a new one
//  is taken. Read only while one of them is on screen.
//

import MachineStatus
import SwiftUI
import TamioModule

// MARK: - The reading

/// A server's containers, as last read: kept while no surface shows them.
/// `docker ps` comes back at once and is shown; `docker stats`, which takes
/// a few seconds, fills in the figures after.
@MainActor
final class ContainerModel: ObservableObject {
    private static var models: [RDMachine.ID: ContainerModel] = [:]
    static func of(_ machine: RDMachine.ID) -> ContainerModel {
        if let model = models[machine] { return model }
        let model = ContainerModel(machine: machine)
        models[machine] = model
        return model
    }

    typealias Container = ContainerRow.Container

    let machine: RDMachine.ID
    @Published private(set) var containers: [Container] = []
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    /// Docker isn't installed at all. The monitor hides its card then: a
    /// server that runs no containers is not one to keep an empty box for.
    @Published private(set) var dockerAbsent = false
    private var reading = false

    init(machine: RDMachine.ID) {
        self.machine = machine
    }

    func refresh(_ session: MonitorSession) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let listing = """
        if ! command -v docker >/dev/null 2>&1; then echo 'TAMIO:NODOCKER'; \
        else docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}' 2>&1; fi
        """
        guard let output = await session.run(listing, timeout: 20) else { return }
        if output.contains("TAMIO:NODOCKER") {
            problem = String(localized: "Docker isn't installed on this server.")
            dockerAbsent = true
            loaded = true
            return
        }
        dockerAbsent = false
        if output.contains("permission denied") || output.contains("Got permission denied") {
            let server = TamioStore.shared.machineGroup[machine]
            let user = server.loginUsername(with: TamioStore.shared.associatedIdentity(for: server))
            problem = String(localized: "\(user) can't reach the Docker socket. Add the user to the docker group.")
            loaded = true
            return
        }
        // The figures last read stay with their containers until new ones come.
        let previous = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var list = output.split(separator: "\n").compactMap { line -> Container? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            var container = Container(id: fields[0], name: fields[1], state: fields[2], status: fields[3])
            if let old = previous[container.id], container.running {
                container.cpu = old.cpu
                container.memory = old.memory
                container.blockIO = old.blockIO
                container.netIO = old.netIO
            }
            return container
        }
        publish(list)
        guard list.contains(where: \.running) else { return }

        let stats = "docker stats --no-stream --format '{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}\t{{.NetIO}}' 2>/dev/null"
        guard let figures = await session.run(stats, timeout: 30) else { return }
        for line in figures.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let index = list.firstIndex(where: { fields[0].hasPrefix($0.id) || $0.id.hasPrefix(fields[0]) }) else { continue }
            list[index].cpu = fields[1]
            list[index].memory = fields[2]
            list[index].blockIO = fields[3]
            list[index].netIO = fields[4]
        }
        publish(list)
    }

    private func publish(_ list: [Container]) {
        problem = list.isEmpty ? String(localized: "No containers on this server.") : nil
        let sorted = list.sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running }
            let left = Double(lhs.cpu.dropLast()) ?? 0, right = Double(rhs.cpu.dropLast()) ?? 0
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if sorted != containers { containers = sorted }
        loaded = true
    }

    // MARK: What the containers add up to

    /// How many are up and how many are not: the states Docker answers with
    /// `created`, `exited`, `paused`, `dead` and `restarting` all count as
    /// stopped, so the two add up to the list's length.
    var running: Int { containers.filter(\.running).count }
    var stopped: Int { containers.count - running }
}

// MARK: - The rows

/// One container: its name and state with a menu of what to do with it, and a
/// ring for its CPU beside its memory, block and network figures.
struct ContainerRow: View {
    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let status: String
        var cpu = ""
        var memory = ""
        var blockIO = ""
        var netIO = ""
        var running: Bool { state == "running" }
        var unhealthy: Bool { status.contains("unhealthy") }
    }

    @ObservedObject var session: MonitorSession
    let container: Container
    @Environment(\.serverActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack {
                Text(container.name).font(.rxBodyStrong).lineLimit(1)
                Spacer()
                Text(container.status)
                    .font(.system(size: 11))
                    .foregroundStyle(container.running && !container.unhealthy ? Color.rxInkSecondary : Color.rxDanger)
                    .lineLimit(1)
                Menu {
                    if container.running {
                        Button("Restart") { act("restart", container) }
                        Button("Stop") { act("stop", container) }
                    } else {
                        Button("Start") { act("start", container) }
                    }
                    Divider()
                    Button("Logs") { openTerminal(running: "docker logs -f --tail 200 \(container.name)") }
                    Button("Shell") { openTerminal(running: "docker exec -it \(container.name) sh -c 'command -v bash >/dev/null && exec bash || exec sh'") }
                        .disabled(!container.running)
                    Button("Copy ID") { actions.copy(container.id) }
                } label: {
                    Label("Actions", rx: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .fixedSize()
            }
            HStack(alignment: .center, spacing: RX.Space.s3) {
                RingGauge(fraction: (Double(container.cpu.replacingOccurrences(of: "%", with: "")) ?? 0) / 100, empty: !container.running)
                    .scaleEffect(0.8)
                    .frame(width: 38, height: 38)
                column("Mem", container.memory.components(separatedBy: " / ").first ?? "—")
                column("Block R / W", container.blockIO)
                column("Net ↓ / ↑", container.netIO)
            }
        }
        .padding(RX.Space.s3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.rxSurfaceSunken))
    }

    func column(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).textCase(.uppercase).font(.system(size: 10, weight: .medium)).foregroundStyle(.rxInkSecondary)
            Text(value.isEmpty ? "—" : value).font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func act(_ verb: String, _ container: Container) {
        Task {
            _ = await session.run("docker \(verb) \(container.name) 2>&1", timeout: 60)
            await ContainerModel.of(session.machine.id).refresh(session)
        }
    }

    func openTerminal(running command: String) {
        actions.openTerminalRunning(session.machine.id, command)
    }
}

/// The rows of a reading, in the order it sorted them: running first, then by
/// CPU, then by name.
struct ContainerRows: View {
    @ObservedObject var session: MonitorSession
    let containers: [ContainerModel.Container]

    var body: some View {
        VStack(spacing: RX.Space.s2) {
            ForEach(containers) { container in
                ContainerRow(session: session, container: container)
            }
        }
    }
}

// MARK: - Inspector tab

/// The inspector's Containers tab: the rows in a column of their own, read
/// every few seconds while the tab is shown.
struct ContainerList: View {
    @ObservedObject var session: MonitorSession
    let machine: RDMachine.ID
    @ObservedObject private var model: ContainerModel

    init(session: MonitorSession, machine: RDMachine.ID) {
        self.session = session
        self.machine = machine
        model = ContainerModel.of(machine)
    }

    var body: some View {
        Group {
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = model.problem {
                EmptyStateView("No containers", systemImage: "shippingbox", message: "\(problem)")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    ContainerRows(session: session, containers: model.containers)
                        .padding(.horizontal, RX.Space.s4)
                        .padding(.bottom, RX.Space.s4)
                }
            }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await model.refresh(session)
                try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
            }
        }
    }
}

// MARK: - Monitor card

/// The monitor's Containers card: the same rows as the inspector's tab, in a
/// card of the grid, collapsed to one line until opened. Not there at all on
/// a server without Docker.
public struct ContainersCard: View {
    @ObservedObject var session: MonitorSession
    @ObservedObject private var model: ContainerModel
    @State private var showsContainers = false

    public init(session: MonitorSession) {
        self.session = session
        model = ContainerModel.of(session.machine.id)
    }

    public var body: some View {
        Group {
            if model.loaded, !model.dockerAbsent {
                VStack(alignment: .leading, spacing: 0) {
                    if let problem = model.problem {
                        CardHead("Containers")
                        HelpText(problem)
                            .padding(.top, RX.Space.s2)
                    } else {
                        // A container host runs a dozen of these and every
                        // row is two lines tall, so the list opens the way the
                        // network card's virtual group does: the counts stay
                        // in view, the rows wait for a click.
                        DisclosureGroup(isExpanded: $showsContainers) {
                            ContainerRows(session: session, containers: model.containers)
                                .padding(.top, RX.Space.s2)
                        } label: {
                            VStack(alignment: .leading, spacing: RX.Space.s3) {
                                HStack(spacing: RX.Space.s2) {
                                    CapsLabel("Containers")
                                    Spacer(minLength: RX.Space.s2)
                                    Text(verbatim: "\(model.containers.count)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.rxInkSecondary)
                                }
                                SubMetricRow([
                                    .init("Running", value: "\(model.running)", swatch: .rxSuccess),
                                    .init("Stopped", value: "\(model.stopped)", swatch: .rxInkTertiary),
                                ])
                            }
                        }
                    }
                }
                .rxCard()
            }
        }
        .task(id: session.id) {
            // A monitor stays open for hours, so it reads slower than the
            // inspector; a server without Docker is asked again only now and
            // then, since installing it is a rare event.
            let every = max(5, session.refreshInterval)
            while !Task.isCancelled {
                await model.refresh(session)
                let seconds = model.dockerAbsent ? max(60, every) : every
                try? await Task.sleep(nanoseconds: UInt64(seconds) * NSEC_PER_SEC)
            }
        }
    }
}
