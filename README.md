# PS-ServiceAccountAudit
Audits Windows servers for services, scheduled tasks, IIS app pools, and COM+ apps running under custom logon accounts. Runs in parallel via PSExec — no WinRM required.

# Get-ServiceAccountAudit

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-lightgrey?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

Scans a list of Windows servers in parallel and reports every service, scheduled task, IIS application pool, and COM+ application running under a custom logon account — not LocalSystem, not NETWORK SERVICE, not any of the built-in accounts. Just the ones someone had to explicitly configure, and the ones that break when Group Policy rewrites your User Rights Assignment.

---

## The problem this solves

If you manage more than a handful of Windows servers, you've probably hit this. Group Policy pushes a "Log on as a service" or "Log on as a batch job" policy, and it wipes whatever was already there. Suddenly services are failing, scheduled tasks are throwing 0x5 Access Denied, and nobody wrote down which accounts needed those rights in the first place.

This script does the inventory first, so you're not rebuilding the list from scratch after the fact.

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

- **PsExec64.exe** from [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) — place it at `C:\Temp\Tools\psexec64.exe` or update the path in the script
- Local admin rights on each target server
- PowerShell 3.0+ on the machine you're running this from (targets can be PS 3.0+)
- No modules required on target servers

---

## Usage

```powershell
# Basic — will prompt for server list and output path
.\Get-ServiceAccountAudit.ps1

# Specify everything upfront
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -OutputCsv C:\Audit\Results.csv

# Run more sessions at once if your network can handle it
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -ThrottleLimit 10
```

Server list is a plain .txt file, one server name per line.

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

The script builds a per-server encoded PowerShell command and launches it via PSExec using background jobs. Results are written to `C:\Windows\Temp\PSExecAudit_<servername>.txt` on each remote server, then read back over the admin share (`\\server\C$\...`) once the job completes. The temp files are deleted after collection.

This approach sidesteps PSExec's stdout buffering, which silently drops output lines when more than one result comes back through the pipe.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ServerListPath` | Prompted | Path to .txt file with server names |
| `-OutputCsv` | `C:\Temp\Backup\ServiceAccountAudit_<timestamp>.csv` | Output file path |
| `-ThrottleLimit` | `5` | Max concurrent PSExec sessions |

---

## Notes

- Read-only. Nothing is changed on any server.
- The script does not require WinRM or PowerShell Remoting to be configured on targets.
- IIS app pool check requires the `WebAdministration` module on the target. If IIS is running but the module isn't installed, the server gets a `Warning` row so you know to check it manually.
- Scheduled tasks are checked at the root `\` path only. Nested Microsoft tasks are ignored.

---

## License

MIT — use it, modify it, share it.
