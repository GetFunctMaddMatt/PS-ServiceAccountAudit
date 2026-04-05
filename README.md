# Get-ServiceAccountAudit

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-lightgrey?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

Scans a list of Windows servers in parallel and reports every service, scheduled task, IIS application pool, and COM+ application running under a custom logon account — not LocalSystem, not NETWORK SERVICE, not any of the built-in accounts. Just the ones someone had to explicitly configure, and the ones that break when Group Policy rewrites your User Rights Assignment.

---

## The problem this solves

Two scenarios come up constantly in enterprise environments.

The first is pre-GPO rollout. You're about to push a "Log on as a service" or "Log on as a batch job" User Rights Assignment policy and you need to know every account that has to be in it before it goes out — not after something breaks. Without a full inventory you're guessing, and GPO will wipe whatever was already on each server the moment it applies.

The second is inherited environments. Not every server was built to spec. Over the years people configure services, scheduled tasks, and app pools to run under personal or shared domain accounts because it was the path of least resistance at the time. Before you can clean that up or migrate to managed service accounts, you need to know what's out there and where it is.

This script gives you that list across your entire server inventory in one shot.

WinRM and PowerShell Remoting also aren't always an option in older or locked-down environments. This uses PSExec so you're not fighting firewall rules or remoting configuration on every target server.

---

## What it checks

| Type | Where it appears |
|---|---|
| **Service** | services.msc / Win32_Service |
| **ScheduledTask** | Task Scheduler — root level only |
| **IISAppPool** | IIS Manager → Application Pools |
| **COMPlusApp** | Component Services (dcomcnfg) |

Anything running as `LocalSystem`, `NT AUTHORITY\*`, `NT SERVICE\*`, `NETWORK SERVICE`, `LOCAL SERVICE`, or `IIS APPPOOL\*` is filtered out. You won't see it. User-session auto-tasks (OneDrive, MicrosoftEdgeUpdateTaskUser, SID-stamped tasks, GUID tasks) are also excluded — those aren't what you're looking for.

---

## Requirements

- **PsExec.exe or PsExec64.exe** from [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) — the script auto-detects it from common locations. If it isn't found you'll be prompted for the path. You can also pass it explicitly with `-PSExecPath`.
- Local admin rights on each target server
- PowerShell 3.0+ on the machine you're running this from (targets can be PS 3.0+)
- No modules required on target servers

---

## Usage

```powershell
# Basic — file picker dialogs will open for the server list and output path
.\Get-ServiceAccountAudit.ps1

# Specify everything upfront — no dialogs
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -OutputCsv C:\Audit\Results.csv

# Point to a specific PSExec location
.\Get-ServiceAccountAudit.ps1 -PSExecPath "D:\Tools\PsExec64.exe" -ServerListPath C:\Servers.txt

# Run more sessions at once if your network can handle it
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -ThrottleLimit 10

# Use alternate credentials for PSExec and admin share access
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -Credential (Get-Credential)
```

Server list is a plain .txt file, one server name per line. If you don't pass `-ServerListPath` or `-OutputCsv` a file picker dialog will open for each.

---

## Output

CSV with five columns:

| Column | Description |
|---|---|
| Server | Server name |
| Type | Service / ScheduledTask / IISAppPool / COMPlusApp / Warning / Clean |
| Name | Name of the service, task, pool, or app |
| Details | Display name, task folder path, or context |
| Account | The logon account |

Every server gets at least one row. `Clean` means it was reached and nothing came back. `Warning` means PSExec couldn't connect or IIS is running but the WebAdministration module isn't installed — both worth following up on.

---

## How it works

Before launching any PSExec session the script tests port 445 (SMB) on each server with a 2 second timeout. Servers that don't respond get a `Warning` row in the CSV immediately and never consume a PSExec slot. This is more reliable than ping since many servers block ICMP but SMB has to be open for PSExec to work anyway.

For servers that pass the connectivity check, the script builds a per-server encoded PowerShell command and launches it via PSExec using background jobs. Results are written to `C:\Windows\Temp\PSExecAudit_<servername>.txt` on each remote server, then read back over the admin share (`\\server\C$\...`) once the job completes. The temp files are deleted after collection.

This approach sidesteps PSExec's stdout buffering, which silently drops output lines when more than one result comes back through the pipe.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-PSExecPath` | Auto-detected | Path to PsExec.exe or PsExec64.exe |
| `-ServerListPath` | File picker dialog | Path to .txt file with server names |
| `-OutputCsv` | Save dialog (timestamped filename) | Output file path |
| `-ThrottleLimit` | `5` | Max concurrent PSExec sessions |
| `-Credential` | Current user | Alternate credentials for PSExec and admin share access |

---

## Notes

- Read-only. Nothing is changed on any server.
- The script does not require WinRM or PowerShell Remoting to be configured on targets.
- Port 445 is tested before each PSExec session. Unreachable servers get a `Warning` row and are skipped — no timeout waiting on PSExec.
- IIS app pool check requires the `WebAdministration` module on the target. If IIS is running but the module isn't installed, the server gets a `Warning` row so you know to check it manually.
- Scheduled tasks are checked at the root `\` path only. Nested Microsoft tasks are ignored.
- A summary is printed at the end showing total servers, how many were scanned, and how many were unreachable.

---

## License

MIT — use it, modify it, share it.
