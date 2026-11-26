//
//  ServerOpsSkills.swift
//  Tamio (macOS)
//
//  Built-in and custom server operations Skills (SKILL.md) with progressive
//  disclosure into the AI system prompt and on-demand loading via `load_skill`.
//

import Foundation
import Observation

// MARK: - Skill Category

nonisolated enum ServerOpsSkillCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case health
    case storage
    case containers
    case network
    case database
    case security
    case performance
    case maintenance

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .health: String(localized: "Fleet Health")
        case .storage: String(localized: "Disk & Logs")
        case .containers: String(localized: "Docker")
        case .network: String(localized: "Network & Web")
        case .database: String(localized: "Database")
        case .security: String(localized: "Security")
        case .performance: String(localized: "Performance")
        case .maintenance: String(localized: "Batch Ops")
        }
    }

    var systemImage: String {
        switch self {
        case .health: "heart.text.square"
        case .storage: "internaldrive"
        case .containers: "shippingbox"
        case .network: "network"
        case .database: "cylinder.split.1x2"
        case .security: "lock.shield"
        case .performance: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Skill Model

nonisolated struct ServerOpsSkill: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String
    var version: String
    var category: ServerOpsSkillCategory
    var instructions: String
    var quickPrompt: String?
    var isEnabled: Bool
    var isBuiltIn: Bool
    var sourceURL: String?
    var updatedAt: Date

    init(
        id: String,
        name: String,
        description: String,
        version: String = "1.0.0",
        category: ServerOpsSkillCategory = .maintenance,
        instructions: String,
        quickPrompt: String? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        sourceURL: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.category = category
        self.instructions = instructions
        self.quickPrompt = quickPrompt
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.sourceURL = sourceURL
        self.updatedAt = updatedAt
    }

    var effectiveRunPrompt: String {
        if let quickPrompt, !quickPrompt.isEmpty {
            return quickPrompt
        }
        return String(localized: "Use the \"\(name)\" ops skill to inspect my target servers and summarize findings.")
    }

    var xmlSummaryElement: String {
        let desc = description.count > 200 ? String(description.prefix(200)) + "…" : description
        return """
          <skill>
            <id>\(id.xmlEscaped)</id>
            <name>\(name.xmlEscaped)</name>
            <category>\(category.rawValue)</category>
            <description>\(desc.xmlEscaped)</description>
          </skill>
        """
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - SKILL.md Parser

nonisolated enum ServerSkillMDParser {
    struct Parsed: Sendable {
        var name: String = "Untitled Skill"
        var description: String = ""
        var version: String = "1.0.0"
        var category: ServerOpsSkillCategory = .maintenance
        var body: String = ""
    }

    static func parse(_ raw: String) -> Parsed {
        var result = Parsed()
        var content = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if content.first == "\u{FEFF}" {
            content.removeFirst()
        }
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            result.body = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }

        for line in lines[1 ..< endIdx] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "name": result.name = value
            case "description": result.description = value
            case "version": result.version = value
            case "category":
                if let cat = ServerOpsSkillCategory(rawValue: value.lowercased()) {
                    result.category = cat
                }
            default: break
            }
        }
        if endIdx + 1 < lines.count {
            result.body = lines[(endIdx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let slug = name.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? "skill-\(UUID().uuidString.prefix(8).lowercased())" : slug
    }

    static func resolveRawURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), let host = url.host?.lowercased() else { return nil }
        if host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 4, parts[2] == "blob" || parts[2] == "tree" else { return nil }
            var path = parts.dropFirst(4).joined(separator: "/")
            if !path.lowercased().hasSuffix(".md") {
                path = path.isEmpty ? "SKILL.md" : "\(path)/SKILL.md"
            }
            return URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(parts[3])/\(path)")
        }
        return url
    }
}

// MARK: - Skill Store

@MainActor
@Observable
final class ServerOpsSkillStore {
    static let shared = ServerOpsSkillStore()

    private static let storageKey = "sb.moe.tamio.ai.skills.v1"

    private(set) var skills: [ServerOpsSkill] = []

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        loadOrSeed()
    }

    var enabledSkills: [ServerOpsSkill] {
        skills.filter(\.isEnabled)
    }

    func skill(idOrName query: String) -> ServerOpsSkill? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = skills.first(where: { $0.id.lowercased() == normalized || $0.name.lowercased() == normalized }) {
            return exact
        }
        return skills.first { $0.id.lowercased().contains(normalized) || $0.name.lowercased().contains(normalized) }
    }

    func addSkill(_ skill: ServerOpsSkill) {
        var candidate = skill
        if skills.contains(where: { $0.id == candidate.id }) {
            candidate = ServerOpsSkill(
                id: "\(candidate.id)-\(UUID().uuidString.prefix(4).lowercased())",
                name: candidate.name,
                description: candidate.description,
                version: candidate.version,
                category: candidate.category,
                instructions: candidate.instructions,
                quickPrompt: candidate.quickPrompt,
                isEnabled: candidate.isEnabled,
                isBuiltIn: false,
                sourceURL: candidate.sourceURL
            )
        }
        skills.insert(candidate, at: 0)
        persist()
    }

    func updateSkill(_ skill: ServerOpsSkill) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        var updated = skill
        updated.updatedAt = Date()
        skills[idx] = updated
        persist()
    }

    func toggleEnabled(id: String) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isEnabled.toggle()
        skills[idx].updatedAt = Date()
        persist()
    }

    func deleteSkill(id: String) {
        skills.removeAll { $0.id == id && !$0.isBuiltIn }
        persist()
    }

    func resetBuiltInSkill(id: String) {
        guard let template = Self.builtInSkills.first(where: { $0.id == id }),
              let idx = skills.firstIndex(where: { $0.id == id })
        else { return }
        skills[idx] = template
        persist()
    }

    func importFromBackup(
        customSkills: [ServerOpsSkill],
        disabledBuiltInIDs: Set<String>,
        replaceExisting: Bool
    ) {
        if replaceExisting {
            skills.removeAll { !$0.isBuiltIn }
        }
        for item in customSkills where !item.isBuiltIn {
            if let idx = skills.firstIndex(where: { $0.id == item.id && !$0.isBuiltIn }) {
                skills[idx] = item
            } else {
                skills.insert(item, at: 0)
            }
        }
        for idx in skills.indices where skills[idx].isBuiltIn {
            if replaceExisting {
                skills[idx].isEnabled = !disabledBuiltInIDs.contains(skills[idx].id)
            } else if disabledBuiltInIDs.contains(skills[idx].id) {
                skills[idx].isEnabled = false
            }
        }
        persist()
    }

    @discardableResult
    func importFromMarkdown(_ raw: String, sourceURL: String? = nil) -> ServerOpsSkill {
        let parsed = ServerSkillMDParser.parse(raw)
        let skill = ServerOpsSkill(
            id: ServerSkillMDParser.slugify(parsed.name),
            name: parsed.name,
            description: parsed.description.isEmpty ? String(localized: "Custom server operations skill") : parsed.description,
            version: parsed.version,
            category: parsed.category,
            instructions: parsed.body.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : parsed.body,
            isEnabled: true,
            isBuiltIn: false,
            sourceURL: sourceURL
        )
        addSkill(skill)
        return skill
    }

    @discardableResult
    func importFromURL(_ urlString: String) async throws -> ServerOpsSkill {
        guard let rawURL = ServerSkillMDParser.resolveRawURL(urlString) else {
            throw RemoteLLMError.invalidURL(urlString)
        }
        var request = URLRequest(url: rawURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RemoteLLMError.httpError(statusCode: code, message: String(localized: "Unable to download SKILL.md"))
        }
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteLLMError.decodingError("Empty SKILL.md")
        }
        return importFromMarkdown(text, sourceURL: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func buildSystemPromptFragment(pinnedSkillIDs: Set<String> = [], compactForOnDevice: Bool = false) -> String {
        let enabled = enabledSkills
        guard !enabled.isEmpty else { return "" }

        var parts: [String] = []
        if compactForOnDevice {
            let pinned = enabled.filter { pinnedSkillIDs.contains($0.id) }
            if !pinned.isEmpty {
                for skill in pinned.prefix(2) {
                    let snippet = skill.instructions.count > 500
                        ? String(skill.instructions.prefix(500)) + "…"
                        : skill.instructions
                    parts.append("[Active Skill: \(skill.name)]\n\(snippet)")
                }
            }
            return parts.joined(separator: "\n\n")
        }

        var xml = "<available_skills>\n"
        for skill in enabled.prefix(24) {
            xml += skill.xmlSummaryElement + "\n"
        }
        xml += "</available_skills>"

        parts.append("""
        Server Operations Skills (reusable runbooks):
        When a task matches a skill below, call `load_skill` first to read its exact checklist before running commands.
        \(xml)
        """)

        for skill in enabled where pinnedSkillIDs.contains(skill.id) {
            parts.append("""
            <active_skill id="\(skill.id)" name="\(skill.name)">
            \(skill.instructions)
            </active_skill>
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    private func loadOrSeed() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ServerOpsSkill].self, from: data),
           !decoded.isEmpty
        {
            var merged = decoded
            let existingIDs = Set(decoded.map(\.id))
            var addedNew = false
            for builtIn in Self.builtInSkills where !existingIDs.contains(builtIn.id) {
                merged.append(builtIn)
                addedNew = true
            }
            skills = merged
            if addedNew {
                persist()
            }
            return
        }
        skills = Self.builtInSkills
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(skills) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 14 Built-in Server Ops Skills

    static let builtInSkills: [ServerOpsSkill] = [
        ServerOpsSkill(
            id: "fleet-health-check",
            name: String(localized: "Fleet Health Check"),
            description: String(localized: "Inspect CPU, memory, root disk, load average, and uptime across all servers and rank risks."),
            category: .health,
            instructions: """
            # Fleet Health Check Runbook
            1. Call `list_hosts` and `get_metrics` (with empty `hosts` for all servers, or the user's scoped servers).
            2. Summarize the fleet in a concise Markdown table: Server | OS | CPU | Mem | Disk | Load | Status.
            3. Highlight risks clearly:
               - **Critical**: Disk >= 85%, Memory >= 90%, Load 1m > cores * 1.5, or server unreachable.
               - **Warning**: Disk 75–84%, CPU >= 80%, Memory 80–89%.
            4. Recommend one concrete next step for every flagged host (offer to inspect logs/top processes via `run_command`).
            """,
            quickPrompt: String(localized: "Run a fleet health check across my servers: summarize CPU, memory, disk usage, load average, and flag any anomalies."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "disk-cleanup-audit",
            name: String(localized: "Disk & Log Cleanup"),
            description: String(localized: "Batch-inspect disk usage, large directories, systemd journal size, and Docker reclaimable space."),
            category: .storage,
            instructions: """
            # Batch Disk & Log Cleanup Runbook
            1. Call `get_metrics` first to locate servers with high disk usage (>= 75%) or use the user's target servers.
            2. Run a single read-only diagnostic command across those servers with `run_command` (task: "Disk usage audit"):
               `df -h -x tmpfs -x devtmpfs; echo "---VAR---"; du -xhd1 /var 2>/dev/null | sort -hr | head -n 8; command -v journalctl >/dev/null && journalctl --disk-usage 2>/dev/null; command -v docker >/dev/null && docker system df 2>/dev/null`
            3. Report the biggest space consumers per server (also note inode exhaustion via `df -i` if needed).
            4. Only after showing findings and getting explicit user intent, propose safe cleanup commands (e.g. `journalctl --vacuum-time=7d`, `docker image prune -f`, `apt-get autoremove -y`) — never run destructive `rm -rf` blindly.
            """,
            quickPrompt: String(localized: "Check disk usage across my servers and find the largest directories, systemd journal size, and reclaimable Docker space."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "docker-fleet-audit",
            name: String(localized: "Docker Fleet Audit"),
            description: String(localized: "Check running, exited, and unhealthy Docker containers plus per-container CPU and memory across servers."),
            category: .containers,
            instructions: """
            # Docker Fleet Audit Runbook
            1. Determine target servers (`list_hosts` if needed).
            2. Run a read-only batch check via `run_command` (task: "Docker container audit"):
               `command -v docker >/dev/null && (docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'; echo "---STATS---"; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null) || echo "docker not installed"`
            3. Group results by server, calling out any `Restarting`, `Exited`, or `(unhealthy)` containers first.
            4. Offer to inspect logs (`docker logs --tail 80 <name>`) or restart specific containers if requested.
            """,
            quickPrompt: String(localized: "Check Docker containers across my servers and highlight any exited, restarting, or unhealthy containers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "docker-compose-ops",
            name: String(localized: "Docker Compose & Image Prune"),
            description: String(localized: "List active Compose stacks, dangling images, unused volumes, and prepare safe image updates or cleanup."),
            category: .containers,
            instructions: """
            # Docker Compose & Image Prune Runbook
            1. Inspect Compose projects and reclaimable storage across target servers via `run_command` (task: "Docker Compose inventory"):
               `command -v docker >/dev/null && (docker compose ls 2>/dev/null; echo "---DF---"; docker system df -v 2>/dev/null | head -n 40) || echo "docker not installed"`
            2. Summarize active Compose stacks, config file paths, dangling images, and unused build cache.
            3. Before running `docker compose pull && docker compose up -d` or `docker system prune`, confirm the exact stack/scope with the user and never prune named volumes without explicit confirmation.
            """,
            quickPrompt: String(localized: "List Docker Compose stacks and reclaimable image/cache space across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "security-baseline-audit",
            name: String(localized: "Security & SSH Audit"),
            description: String(localized: "Audit listening ports, SSH authentication policy, root login, sudoers, and recent failed SSH logins."),
            category: .security,
            instructions: """
            # Security Baseline & SSH Audit Runbook
            1. Run a read-only security probe across targets using `run_command` (task: "Security baseline audit"):
               `ss -tulnp 2>/dev/null | head -n 25; echo "---SSH---"; grep -E '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|Port)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; echo "---AUTH---"; lastb -n 8 2>/dev/null || journalctl -u ssh -u sshd -n 15 --no-pager 2>/dev/null | grep -iE 'failed|invalid' || true`
            2. Flag unexpected `0.0.0.0` / `::` listening ports, enabled password login, root password login, or active brute-force attempts.
            3. Provide prioritized hardening recommendations without modifying `sshd_config` unless the user explicitly approves (and always remind to validate with `sshd -t` before reloading).
            """,
            quickPrompt: String(localized: "Audit open listening ports, SSH authentication policy, and recent failed login attempts across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "firewall-ports-audit",
            name: String(localized: "Firewall & Port Exposure"),
            description: String(localized: "Inspect ufw, firewalld, nftables, or iptables rules and cross-check against public listening sockets."),
            category: .security,
            instructions: """
            # Firewall & Port Exposure Runbook
            1. Run a read-only firewall check across target servers via `run_command` (task: "Firewall rules audit"):
               `if command -v ufw >/dev/null; then ufw status verbose; elif command -v firewall-cmd >/dev/null; then firewall-cmd --list-all; elif command -v nft >/dev/null; then nft list ruleset | head -n 60; else iptables -S 2>/dev/null | head -n 50; fi; echo "---PUBLIC---"; ss -tuln | awk '$5 ~ /(0\\.0\\.0\\.0|\\[::\\]|\\*):/'`
            2. Cross-reference listening public ports against active firewall rules.
            3. Flag databases (3306, 5432, 6379, 27017) or admin panels exposed publicly without firewall restrictions.
            """,
            quickPrompt: String(localized: "Check firewall status and publicly exposed listening ports across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "ssl-cert-expiry",
            name: String(localized: "TLS Certificate Expiry"),
            description: String(localized: "Batch-check Let's Encrypt, Nginx, and Caddy TLS certificate expiration dates and auto-renewal timers."),
            category: .network,
            instructions: """
            # TLS / SSL Certificate Expiry Runbook
            1. Inspect certificate files and renewal timers across targets using `run_command` (task: "TLS certificate expiry check"):
               `for f in /etc/letsencrypt/live/*/fullchain.pem /etc/nginx/ssl/*.crt /etc/nginx/certs/*.pem; do [ -f "$f" ] && echo "=== $f ===" && openssl x509 -in "$f" -noout -subject -enddate 2>/dev/null; done; command -v certbot >/dev/null && certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry Date'; systemctl list-timers 2>/dev/null | grep -iE 'certbot|acme|caddy' || true`
            2. List every discovered certificate sorted by soonest expiry, marking `< 14 days` as Critical and `< 30 days` as Warning.
            3. If any renewal timer is missing or failing, offer to run `certbot renew --dry-run` to diagnose safely.
            """,
            quickPrompt: String(localized: "Check TLS/SSL certificate expiration dates and auto-renewal timers across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "web-proxy-audit",
            name: String(localized: "Nginx & Caddy Proxy Audit"),
            description: String(localized: "Validate Nginx/Caddy configs, inspect recent 5xx errors and upstream timeouts across web nodes."),
            category: .network,
            instructions: """
            # Nginx / Caddy Reverse Proxy Audit Runbook
            1. Probe web proxy health and recent errors via `run_command` (task: "Web proxy audit"):
               `if command -v nginx >/dev/null; then echo "---NGINX---"; nginx -t 2>&1; systemctl is-active nginx 2>/dev/null; tail -n 20 /var/log/nginx/error.log 2>/dev/null; fi; if command -v caddy >/dev/null; then echo "---CADDY---"; systemctl is-active caddy 2>/dev/null; journalctl -u caddy -n 20 --no-pager 2>/dev/null; fi`
            2. Highlight config syntax issues, `502 Bad Gateway` / `504 Gateway Timeout` upstream failures, or worker connection saturation.
            3. Offer targeted upstream checks or safe graceful reload (`nginx -s reload` / `systemctl reload caddy`) only when asked.
            """,
            quickPrompt: String(localized: "Check Nginx and Caddy status, config validity, and recent error logs across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "network-diagnostics",
            name: String(localized: "Network & TCP Diagnostics"),
            description: String(localized: "Inspect TCP socket states (TIME_WAIT/CLOSE_WAIT), NIC packet drops, DNS resolution, and outbound latency."),
            category: .network,
            instructions: """
            # Network & TCP Diagnostics Runbook
            1. Gather network stack health across targets via `run_command` (task: "Network stack diagnostics"):
               `ss -s 2>/dev/null; echo "---STATES---"; ss -tan 2>/dev/null | awk 'NR>1 {c[$1]++} END {for (s in c) print s, c[s]}'; echo "---DROPS---"; ip -s link show 2>/dev/null | grep -E '^[0-9]+:|RX:|TX:' -A 1 | head -n 30; echo "---DNS---"; cat /etc/resolv.conf 2>/dev/null | grep -v '^#'`
            2. Highlight high `CLOSE_WAIT` (app socket leak), excessive `TIME_WAIT`, NIC RX/TX errors/drops, or misconfigured DNS resolvers.
            3. Offer targeted `curl -w` / `mtr` / `ping` checks between specific nodes if latency issues are reported.
            """,
            quickPrompt: String(localized: "Run network diagnostics across my servers: check TCP socket states, interface packet drops, and DNS resolvers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "perf-bottleneck-triage",
            name: String(localized: "CPU & Memory Bottleneck"),
            description: String(localized: "Pinpoint top CPU/memory consumers, zombie processes, swap thrashing, and I/O wait hotspots."),
            category: .performance,
            instructions: """
            # CPU & Memory Bottleneck Triage Runbook
            1. Check live metrics with `get_metrics` first, then run a read-only process snapshot on relevant servers via `run_command` (task: "Performance bottleneck triage"):
               `uptime; free -h; echo "---TOP CPU---"; ps -eo pid,ppid,stat,%cpu,%mem,comm --sort=-%cpu | head -n 10; echo "---TOP MEM---"; ps -eo pid,ppid,stat,%cpu,%mem,rss,comm --sort=-%mem | head -n 10; echo "---ZOMBIES---"; ps -eo pid,stat,comm | awk '$2 ~ /Z/' | head -n 10`
            2. Identify runaway processes, memory leaks, heavy swap usage, or zombie process buildup.
            3. Explain root cause clearly and propose safe mitigation (service restart, memory limit, log rotation) before taking action.
            """,
            quickPrompt: String(localized: "Find top CPU and memory consuming processes, swap usage, and zombie processes across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "database-health-check",
            name: String(localized: "Database & Redis Health"),
            description: String(localized: "Check PostgreSQL, MySQL/MariaDB, and Redis service health, active connections, memory, and backup freshness."),
            category: .database,
            instructions: """
            # Database & Redis Health Runbook
            1. Run a read-only database probe across target servers via `run_command` (task: "Database health check"):
               `for svc in postgresql mysql mariadb mysqld redis redis-server mongod; do systemctl is-active --quiet "$svc" 2>/dev/null && echo "ACTIVE: $svc"; done; command -v redis-cli >/dev/null && redis-cli info memory clients 2>/dev/null | grep -E 'used_memory_human|maxmemory_human|connected_clients|evicted_keys'; command -v psql >/dev/null && su - postgres -c "psql -tAc 'SELECT count(*), state FROM pg_stat_activity GROUP BY state;'" 2>/dev/null || true; ls -lht /var/backups /backup /root/backups 2>/dev/null | head -n 12`
            2. Summarize active DB engines, connection pressure, Redis memory/evictions, and latest backup timestamps.
            3. Flag missing/stale backups (> 24h) or memory pressure approaching `maxmemory`.
            """,
            quickPrompt: String(localized: "Check PostgreSQL, MySQL, and Redis health, active connections, memory usage, and recent backup files across my servers."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "package-updates-audit",
            name: String(localized: "Package & Security Updates"),
            description: String(localized: "Inventory pending apt/dnf/yum/apk security updates and check whether any server requires a reboot."),
            category: .maintenance,
            instructions: """
            # Package & Security Updates Audit Runbook
            1. Run a read-only update inventory across targets via `run_command` (task: "Package updates inventory"):
               `if command -v apt >/dev/null; then apt list --upgradable 2>/dev/null | tail -n +2 | head -n 30; [ -f /var/run/reboot-required ] && echo "REBOOT_REQUIRED=yes" || echo "REBOOT_REQUIRED=no"; elif command -v dnf >/dev/null; then dnf check-update -q 2>/dev/null | head -n 30; elif command -v apk >/dev/null; then apk version -l '<' 2>/dev/null | head -n 30; fi; uname -r`
            2. Summarize upgradable package counts, kernel version, and which servers have `REBOOT_REQUIRED=yes`.
            3. Never run unattended upgrades or reboots automatically — propose a rolling update plan grouped by host when requested.
            """,
            quickPrompt: String(localized: "Check pending package and security updates and see which servers require a reboot."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "cron-timers-audit",
            name: String(localized: "Cron & Systemd Timers"),
            description: String(localized: "Audit root/system crontabs and systemd timers to spot broken scheduled jobs or suspicious entries."),
            category: .maintenance,
            instructions: """
            # Cron & Systemd Timers Audit Runbook
            1. Inspect scheduled jobs across target servers via `run_command` (task: "Scheduled jobs audit"):
               `echo "---CRONTAB---"; crontab -l 2>/dev/null | grep -v '^#'; ls -la /etc/cron.d /etc/cron.daily 2>/dev/null; echo "---TIMERS---"; command -v systemctl >/dev/null && systemctl list-timers --all --no-pager 2>/dev/null | head -n 25`
            2. Summarize active jobs and call out any disabled, failed, or suspicious curl/bash pipe cron entries.
            3. Offer to inspect logs of any failing timer (`journalctl -u <service> -n 30`).
            """,
            quickPrompt: String(localized: "Audit crontabs and systemd timers across my servers and highlight any broken or suspicious scheduled jobs."),
            isBuiltIn: true
        ),
        ServerOpsSkill(
            id: "batch-ops-triage",
            name: String(localized: "Service & Crash Triage"),
            description: String(localized: "Check failed systemd units, kernel OOM kills, and recent unexpected reboots across server groups."),
            category: .maintenance,
            instructions: """
            # Batch Service & Crash Triage Runbook
            1. Call `get_activity` first if working on an unfamiliar host to see recent agent changes.
            2. Run a read-only triage via `run_command` (task: "Service health triage"):
               `command -v systemctl >/dev/null && systemctl --failed --no-pager; echo "---REBOOTS---"; last -x reboot -n 3 2>/dev/null; echo "---OOM---"; dmesg -T 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -n 8 || true`
            3. Summarize failed units, recent reboots, and OOM-killed processes per server, and offer targeted service log inspection (`journalctl -u <unit> -n 50`) or restarts.
            """,
            quickPrompt: String(localized: "Check failed systemd services, recent unexpected reboots, and kernel OOM kills across my servers."),
            isBuiltIn: true
        ),
    ]
}
