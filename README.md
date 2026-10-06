# PalRelay

Take turns hosting a shared Palworld dedicated-server world on Windows, with versioned saves synchronized through Google Drive.

[Windows releases](https://github.com/Lother13501350/palrelay/releases) · [Architecture](docs/DESIGN.md) · [Windows CI](https://github.com/Lother13501350/palrelay/actions/workflows/test.yml)

## Overview and status

PalRelay is a released community tool for a small group of friends who want to keep one world without renting an always-on server. Each member runs the dedicated server locally during their session, then publishes the save for the next host. Release **v0.6.1** includes the desktop application and migration helper.

Cloud coordination uses an **advisory lock**, not an atomic distributed lock. Nonces, a delayed read-back, and heartbeat checks reduce conflicts, but Google Drive has no compare-and-swap and simultaneous starts can still race. Coordinate handoffs within the group. The repository has Windows CI and downloadable releases; it does not publish usage or reliability metrics.

## Key features

- Multiple worlds within one shared Drive folder, with host status and connection information.
- Versioned ZIP saves, SHA-256 verification on download, and retained cloud/local backups.
- Publish-before-unlock ordering; a failed upload keeps the lock for recovery.
- Native C# WPF application and PowerShell CLI sharing the session commands.
- Setup wizard for rclone, Google Drive access, and dedicated-server installation.
- Co-op world import, host-character migration with identity-chain verification and rollback, and map-exploration recovery.
- Optional checkpoints and per-world server gameplay settings.

## Installation and use

Requirements: Windows 10/11, Windows PowerShell 5.1, the Steam version of Palworld, the free Palworld Dedicated Server, and a Google account with access to the group's shared folder. Tailscale is optional; otherwise configure game connectivity yourself.

1. Download and extract the latest ZIP from [Releases](https://github.com/Lother13501350/palrelay/releases).
2. Run `setup.cmd`. Choose to join an existing group or create a new one.
3. The group owner shares the Drive folder with members as editors.
4. Open `PalRelay.exe`, select a world, and start hosting.
5. Share the displayed game address. At the end, use the application's finish/upload action and wait for publication before another member starts.

Use PalRelay to launch the server so the session participates in save versioning. Keep independent backups before migrating a world. The legacy `palrelay-gui.cmd` launcher remains a fallback.

## Architecture

```text
WPF desktop application / PowerShell CLI
  -> shared session commands in palrelay.ps1
  -> rclone -> shared Google Drive folder
  -> local PalServer process and REST save/shutdown API

Google Drive:
group.json
worlds/<world>/lock.json
worlds/<world>/latest.json
worlds/<world>/options.json
worlds/<world>/saves/world-vNNNN-*.zip
```

The upload path stages a ZIP, computes its SHA-256, verifies the uploaded file size, and updates `latest.json` before releasing the lock. The download path verifies the checksum before replacing local saves. `tools/palfix.py` handles selected save structures conservatively and preserves other serialized blocks.

## CLI reference

```powershell
.\palrelay.ps1 <command> [world] [-Force]
```

| Command | Purpose |
| --- | --- |
| `init` | Create `config.json` from `config.sample.json`. |
| `start [world]` | Acquire lock, sync, host, stop, publish, and unlock. Press Q in the CLI to finish. |
| `worlds` / `status [world]` | Inspect cloud worlds, host state, and versions. |
| `upload [world]` | Publish a local save after a crash or seed a world. |
| `takeover [world]` | Clear a stale lock; a fresh lock requires `-Force`. |
| `import` | Copy an existing local co-op world into the dedicated-server workflow. |
| `fixhost [world]` | Migrate the original co-op host after the server creates their new character. |
| `fixmap [world]` | Restore backed-up client exploration data. |

Exit codes: `0` success, `1` general error, `2` lock held by another host, `3` configuration error, `5` server crash without successful upload. Omitted world names resolve from the previous world, the sole cloud world, or `main`.

## Configuration and security

Start with [config.sample.json](config.sample.json). The [configuration reference](docs/DESIGN.md#configuration) explains each field. Local `config.json`, `rclone.conf`, and runtime state are ignored by Git. The shared `group.json` contains the server administration password and belongs only in the private group folder.

Expose the game port as needed; do not expose the administrative REST port to the public internet. Cloud saves contain the group's player data. rclone authentication tokens stay on each member's machine.

## Development and testing

On Windows, clone the repository and run the offline harness:

```powershell
git clone https://github.com/Lother13501350/palrelay.git
cd palrelay
.\test\run-tests.ps1
```

The harness uses fake rclone and temporary files to exercise locks, migration of cloud layouts, publish/download behavior, pruning, and corrupt-download handling. The source CI run for `c812daa` recorded **65 passing checks** on July 26, 2026; this is a check count, not coverage. It does not run a real game server or real Drive session.

For the WPF application, install the .NET 9 SDK on Windows:

```powershell
dotnet publish gui/PalRelay.Gui.csproj -c Release
```

The `build-gui` and `build-palfix` workflows produce Windows artifacts. The migration-helper workflow installs pinned `palworld-save-tools`, overlays a pinned hostfix-toolkit commit, and builds an executable with PyInstaller. Those are artifact builds, not end-to-end game tests.

## Project structure

| Path | Responsibility |
| --- | --- |
| `palrelay.ps1` | Lock, save, configuration, server, and session logic. |
| `gui/` | .NET 9 WPF UI calling the CLI session API. |
| `setup.ps1` / `setup.cmd` | Group and machine setup. |
| `tools/palfix.py` | Save import, identity validation, and migration tooling. |
| `test/` | Offline harness and fake cloud adapter. |
| `.github/workflows/` | Windows tests and binary builds. |

## Engineering highlights and limitations

The main engineering work is failure handling around a stateful handoff: upload ordering, checksum validation, backup retention, stale-lock recovery, and a shared protocol for GUI and CLI. Forced takeover can lose another host's unpublished progress; inspect the state and coordinate first. A crash can also lose progress since the last successful checkpoint.

Migration may require `libooz.dll`. The helper downloads it only after consent and validates its checksum; it is not redistributed in this project. Imported groups may need to re-invite guild members in-game. See the [design document](docs/DESIGN.md) for the migration boundaries.

Remaining work includes atomic lock acquisition on a storage backend supporting conditional writes and real Drive/game regression runs. The desktop screenshot is still a documentation gap; no fabricated UI image is provided.

## License and acknowledgments

[MIT](LICENSE). PalRelay is an independent community tool and is not affiliated with Pocketpair.

The migration engine builds on [palworld-save-tools](https://github.com/cheahjs/palworld-save-tools), [palworld-hostfix-toolkit](https://github.com/quadrantbs/palworld-hostfix-toolkit), and the approach in [palworld-host-save-fix](https://github.com/xNul/palworld-host-save-fix). Synchronization uses [rclone](https://rclone.org/); Oodle decompression uses [ooz](https://github.com/zao/ooz) when downloaded by the user.
