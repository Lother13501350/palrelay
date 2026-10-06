# PalRelay architecture

PalRelay coordinates rotating Windows hosts for a shared Palworld world. PowerShell owns the session protocol; the WPF desktop application calls that protocol rather than implementing its own cloud writes. rclone transports files between each host and a private Google Drive folder.

## System boundaries

The local machine runs PalServer and stores its saves. Google Drive holds coordination metadata and versioned ZIPs. The group is trusted: editors can change its files and read the shared administration password. PalRelay is not a hostile multi-tenant service or an always-on game host.

```text
Desktop UI -> CLI session API -> PalServer process / local REST API
                             -> local saves, state.json, backups/
                             -> rclone -> private Drive folder
Save migration commands -> tools/palfix.py / packaged palfix.exe
```

## Cloud and local records

| Record | Fields and role |
| --- | --- |
| `group.json` | `schemaVersion`, `adminPassword`, `createdBy`, `createdUtc`; shared setup and server administration secret. |
| `worlds/<world>/lock.json` | `holder`, `machine`, `nonce`, `startedUtc`, `heartbeatUtc`, `hostIp`, `hostIpSource`, `serverPort`, `toolVersion`; advisory host ownership and connection information. |
| `worlds/<world>/latest.json` | `version`, `zip`, `sha256`, `sizeBytes`, `worldGuid`, `uploadedBy`, `uploadedUtc`, `toolVersion`; points to the published save. |
| `worlds/<world>/saves/` | Versioned ZIP files, named with version, UTC time, and uploader. |
| `worlds/<world>/options.json` | Gameplay options imported with a world; operational password/REST settings are applied separately. |
| `state.json` | Schema version 2, `lastWorld`, and per-world state under `worlds`; tracks phase, downloaded version, hosting start, and migration state. |
| `backups/` | Local saves displaced during synchronization. |

Old flat cloud and local-state layouts migrate into the multi-world schema. `latest.json` is the publication pointer; merely uploading a ZIP does not publish that version.

## Configuration

Create local `config.json` using `init` or the wizard. See [config.sample.json](../config.sample.json).

| Field | Default | Role |
| --- | --- | --- |
| `playerName` | Required | Displayed lock/upload identity. |
| `remote` | Required | rclone remote pointing to the shared folder. |
| `serverDir` | Required | Local dedicated-server installation. |
| `rclonePath` | `rclone` | Executable path. |
| `rcloneConfig` | Empty | Optional explicit rclone configuration file. |
| `serverExe` | `PalServer.exe` | Dedicated-server launcher. |
| `serverArgs` | `[]` | Additional launcher arguments. |
| `adminPassword` | Empty | Bootstrap/legacy fallback; shared `group.json` takes precedence. |
| `serverPort` | `8211` | Announced game port. |
| `restPort` | `8212` | Local administrative REST API. |
| `heartbeatMinutes` | `5` | Host heartbeat interval. |
| `staleMinutes` | `20` | Age after which a lock is stale. |
| `checkpointMinutes` | `0` | Optional checkpoint publication interval; zero disables it. |
| `keepVersions` | `10` | Retained cloud save versions. |
| `worldGuid` | Empty | Override when automatic save-directory selection is ambiguous. |

Runtime files and tokens are local/group secrets and are ignored by Git. Do not expose the administration port publicly. World ZIPs contain player data and should remain within the group.

## Advisory lock protocol

`Acquire-Lock` reads the existing lock. Another host's fresh lock rejects the start; a stale lock requires confirmation or an explicit force path. The new host writes a random nonce, waits three seconds, and reads the lock back. A different nonce means it lost the race and must stop.

Heartbeats re-read ownership before updating. If the nonce differs, the host warns instead of overwriting the conflicting lock. Release also checks the nonce before deleting the lock.

This is not atomic acquisition: Drive does not provide compare-and-swap for this protocol. Two hosts can pass read-back at different moments in an overlapping write window. Delayed verification, heartbeat warnings, and human handoff coordination mitigate that risk without proving mutual exclusion. A backend supporting conditional writes would be needed to eliminate this class of race.

## Session and publication order

```text
idle -> lock acquired -> latest downloaded / verified -> hosting
hosting -> save requested -> server stopped -> ZIP uploaded / size checked
        -> latest.json published -> lock released -> idle
hosting -> crash / interrupted upload -> retained state -> recovery prompt
```

For a normal session, lock release occurs after publication. A failed upload retains the lock and recovery state; `upload` retries publication. On the next start, a previous `hosting` state prompts the user to recover the local save before syncing another version. Declining recovery can discard unpublished progress during a later download.

`Publish-Save` stages the world folder, excludes the game server's own `backup/` subtree, builds a ZIP, computes SHA-256, uploads it, checks the remote size, updates `latest.json`, and prunes older ZIPs while protecting the published target. Upload verification is a size check; a downloader independently verifies the checksum.

`Sync-Down` downloads the referenced ZIP, checks SHA-256, and only then moves the existing local save into backup and extracts the new save. Local backup retention and cloud version retention are separate.

Optional checkpoints request a save while hosting, stage and publish another version, and retain session ownership. Recovery is bounded by the last **successful** checkpoint, not simply by the configured interval when uploads fail.

## Server control

The launcher uses `Start-Process`, and liveness checks include PalServer child processes. Before hosting, the tool updates `DedicatedServerName` and merges per-world gameplay options with required REST/password settings.

Shutdown requests `POST /v1/api/save` followed by `POST /v1/api/shutdown` with local Basic authentication. It waits for process termination and may force-stop after the timeout, with a warning. Process failures and unpublished progress remain separate from successful publication.

## Co-op import and host migration

`import` scans local co-op saves, copies rather than moves the original world, extracts gameplay options, and seeds a cloud world. The original co-op host then joins the dedicated server once so the server creates a new accepted character. `fixhost` migrates progress into that identity while preserving its server-recognized links.

The migration helper uses pinned `palworld-save-tools` and hostfix-toolkit patches. PlM decompression uses `libooz.dll`, downloaded after consent and checksum verification rather than redistributed here. Rewritten saves use the supported zlib format.

The helper decodes only selected structures it can safely serialize and passes other blocks through as bytes. After mutation it verifies the player/character/guild/container identity chain. Verification failure restores backups and returns a failure code. This is narrower than a guarantee of compatibility with all future game formats.

Imported worlds retain gameplay settings. Client `LocalData.sav` exploration data is backed up so `fixmap` can restore it after the game resets map discovery. Guild membership may require in-game re-invitation; unknown guild structures are not manually rewritten.

## Failure and recovery

| Failure | Expected response |
| --- | --- |
| Fresh lock owned by someone else | Reject start and show the host. |
| Crash or power loss | Heartbeat expires; another host may take over after the stale threshold, losing unpublished progress. The previous host gets a recovery prompt. |
| Upload failure | Keep lock and local recovery state; retry `upload` after resolving connectivity. |
| Corrupt download | Checksum failure aborts before local save replacement. |
| Overlapping acquisition | Residual advisory race; coordinate hosts and react to conflict warnings. |
| Incorrect fresh-lock takeover | Requires force; may lose another host's work. |
| Unwanted published save | Choose a retained ZIP and deliberately update its publication metadata after coordinating with the group. |
| Failed host migration verification | Restore backed-up save files and return failure. |

## Interfaces and verification

The CLI provides `start`, `worlds`, `status`, `upload`, `takeover`, `init`, `import`, `fixhost`, and `fixmap`. The WPF application uses JSON/session commands in the same PowerShell implementation. The legacy PowerShell UI remains a fallback.

[The offline harness](../test/run-tests.ps1) uses fake rclone and temporary local directories. It checks coordination, multi-world migration, save publication/download, retention, and corruption detection. The historical source CI run recorded 65 passing checks; those checks do not exercise real Drive authorization, real server shutdown, GUI usability, or game-format compatibility end to end.

The binary workflows build the GUI and migration helper. Real Drive/game sessions and a native Windows screenshot remain separate manual verification work.

## Remaining work

Atomic acquisition via conditional-write storage, richer handoff notifications, and automated server-version coordination are future work. Multi-world UI and connection announcements already exist and must not be presented as unfinished roadmap features.
