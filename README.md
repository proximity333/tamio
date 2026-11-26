# Tamio

A native SSH client for macOS: a Ghostty terminal, a dual-pane SFTP browser,
live status for every server, end-to-end encrypted iCloud sync, and an MCP
server so AI agents can work across your hosts with your approval.

Tamio is in early development. The plan is in [DESIGN.md](./DESIGN.md). An
iOS version is planned, but work on it has not started yet.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask owo-network/brew/tamio
```

Or download the disk image from [Releases](https://github.com/missuo/tamio/releases/latest).
Tamio needs macOS 14 or later, and updates itself.

## Features

### Agents (MCP)

- **A built-in MCP server.** Claude Code, Codex and any other MCP client can
  work on your servers through Tamio. Settings › MCP sets up Claude Code, Codex
  and the Tamio skill in one click.
- **What agents can do:**
  - see your servers and their live CPU, memory, disk, load and traffic;
  - run commands or saved snippets on one server or many at once;
  - add or change servers, SSH keys, snippets and port forwards;
  - start and stop port forwards.
- **Every server operation leaves a history.** Each command an agent runs and
  each change it makes is recorded on that server's Activity: which agent, on
  which Mac, what it ran, and what came back. Agents also log what they did
  outside Tamio (their own `ssh`, `scp`, a deploy).
- **One entry per task, not per command.** An agent names the goal of each
  step, such as "Install nginx", and every step toward it (the repository,
  `apt update`, the install, its config) is kept as one entry, with each step
  and its result under it. The next agent sees what was done at a glance.
- **Filter by server.** Settings › MCP shows the activity of every server, or of
  the one you pick.
- **The history outlives the session.** An agent's session may be lost when you
  switch agents, swap devices or change computers. The record stays with the
  server, and syncs across your Macs, so the next agent knows what the last one
  did there.

### Assistant

- **A built-in AI assistant that works on your servers.** Assistant, in the
  sidebar, talks to Apple Intelligence on device (macOS 26 or later) or to
  OpenAI, Anthropic, Gemini, DeepSeek, Ollama and any compatible endpoint.
- **It uses Tamio's own tools.** The assistant reads live metrics, runs
  commands on one server or many, and changes servers, SSH keys, snippets and
  port forwards through the same MCP engine agents use — so every action asks
  for approval in the conversation and lands in the server's activity history.
- **A conversation per task.** Keep several chats, scope each one to all
  servers, a group or a set of hosts, choose its model, and give it built-in
  or imported ops skills. Screenshots can be attached to a message, pasted
  from the clipboard or picked from disk. API keys stay in your Keychain.

### Security

- **Agents never see a secret.** No tool returns a password, a private key or a
  passphrase. An agent can add a key, or have Tamio generate one, and gets back
  only the public half.
- **You approve first.** Every command, change and port forward an agent asks
  for waits for you, showing exactly what will run and where. Allow it once,
  for an hour, or always, for an agent left to work on its own; Settings › MCP
  lists the agents always allowed, and revokes them.
- **Only you can reach it.** The MCP server listens on a Unix socket that only
  your own user account can open. It doesn't use a network port.
- **Encrypted on disk.** Servers and identities are stored encrypted, under a key
  kept in your Keychain.
- **End-to-end encrypted sync.** Data is encrypted on your Mac, under a
  passphrase only your devices know, before it goes to iCloud. Apple cannot read
  it.
- **Host keys are checked.** A server's key is trusted once, and a changed key
  is refused.

### Servers and terminal

- A fast terminal, built on [Ghostty](https://ghostty.org).
- Servers with labels, groups and tags; a password or an SSH key to sign in.
- Identities: paste a key, load one from a file, or generate an Ed25519 key. A
  private key is never shown again once saved.
- Snippets for the commands you run often, and local and remote port forwards.

### Live status

- A Home card for every server with live CPU, memory and disk, its operating
  system's logo, and a flag for labels such as `JP Tokyo`.
- Details for each server: overview, processes, containers and agent activity.

### Files (SFTP)

- Two panes, this Mac and a server, each switchable to any server.
- Drag files between the panes, from Finder, or out to Finder. Folders go whole.
- A transfer queue with progress, speed, time left, cancel and retry, and a
  notification when a transfer ends while Tamio is in the background.

### iCloud sync

- On unless you turn it off, so your servers and what agents did on them are
  never lost with a Mac.
- Servers, identities, snippets, port forwards, known host keys and agent
  activity stay the same on all your Macs, each kind with its own switch.
- Tamio makes the passphrase and iCloud Keychain carries it, so your other Macs
  sync by themselves. Settings shows it, for a device without iCloud Keychain.

### App

- Updates itself with Sparkle: a new version shows at the bottom of the
  sidebar, with its release notes.
- Light and dark appearance.

## Build from source

Needs Xcode 26 or later.

```sh
git clone https://github.com/missuo/tamio.git
cd tamio
bash Workflow/Scripts/build-macos.sh          # Debug, signed ad hoc
```

Or open `App.xcworkspace` and run the **Tamio** scheme. After editing
`Application/Tamio/project.yml`, run `xcodegen generate` in `Application/Tamio`.

Tests:

```sh
swift test --package-path Foundation/TamioModule
swift test --package-path Foundation/TamioTerminal
swift test --package-path Foundation/MachineStatus
```

Releases are signed and notarized by GitHub Actions when a `v<version>` tag is
pushed (`.github/workflows/release.yml`).

## Credits

- [mizorewww/catussh](https://github.com/mizorewww/catussh)
- [Lakr233/Rayon](https://github.com/Lakr233/Rayon)

## License

[MIT](./LICENSE). Third-party licenses are listed in [Resources/LICENSE](./Resources/LICENSE).
