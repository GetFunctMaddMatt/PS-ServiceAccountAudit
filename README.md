# Get-ServiceAccountAudit

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-lightgrey?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

Audits service logon accounts across your Windows server estate and exports the results to CSV.

[![Download](https://img.shields.io/badge/Download-Get--ServiceAccountAudit.ps1-blue?style=for-the-badge&logo=powershell)](https://raw.githubusercontent.com/GetFunctMaddMatt/PS-ServiceAccountAudit/main/Get-ServiceAccountAudit.ps1)

---

Covers services, scheduled tasks, IIS application pools, and COM+ applications. Useful before rolling out a User Rights Assignment GPO — if an account isn't in the policy when it applies, whatever is running under it breaks. This gives you the full list, including NT SERVICE\ virtual accounts that products like SQL Server and Entra Connect install automatically. Those resolve to a unique SID per server, so the UseSID column captures that on each machine they're found on.
Uses PSExec rather than WinRM so remoting configuration on target servers isn't a requirement.

Requirements

PsExec.exe or PsExec64.exe — auto-detected from common locations or pass it with -PSExecPath. Download from Sysinternals.
Local admin on each target server
PowerShell 3.0+ on the machine running the script


Usage
powershell# File picker dialogs open for server list and output path if not supplied
.\Get-ServiceAccountAudit.ps1

# No dialogs
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -OutputCsv C:\Audit\Results.csv

# Specific PSExec path
.\Get-ServiceAccountAudit.ps1 -PSExecPath "D:\Tools\PsExec64.exe" -ServerListPath C:\Servers.txt

# More concurrent sessions
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -ThrottleLimit 10

# Alternate credentials
.\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -Credential (Get-Credential)
Server list is a plain .txt file, one name per line.

Output
ServerTypeObjectNameDetailsAccountUseSIDSRV-APP01ServiceSQL Server (MSSQLSERVER)MSSQLSERVER [NT SERVICE virtual account — local to this server, no password]NT SERVICE\MSSQLSERVERS-1-5-80-3880718306-...SRV-APP01ServiceMicrosoft Entra Connect SyncADSyncNT SERVICE\ADSyncS-1-5-80-1544895418-...SRV-APP01ServiceBackup Exec AgentBEAgentDOMAIN\svc_backupSRV-WEB01IISAppPoolIntranetAppPoolDOMAIN\svc_intranetSRV-WEB01ScheduledTaskNightlyReport\DOMAIN\svc_reportsSRV-DC02WarningServer not reachablePort 445 (SMB) did not respondUNKNOWNSRV-SQL01CleanNo custom accounts foundServer was reached and returned no resultsN/A
UseSID is populated for NT SERVICE\ virtual accounts and local user accounts. Domain accounts and gMSAs are left blank — those can be referenced by name in GPO. Every server gets at least one row. Warning rows are worth following up on.

Parameters
ParameterDefaultDescription-PSExecPathAuto-detectedPath to PsExec.exe or PsExec64.exe-ServerListPathFile picker dialogPath to .txt file with server names-OutputCsvSave dialog (timestamped filename)Output file path-ThrottleLimit5Max concurrent PSExec sessions-CredentialCurrent userAlternate credentials for PSExec and admin share access

How it works
Port 445 is tested on each server before any PSExec session launches. Unreachable servers get a Warning row immediately and never consume a slot. For servers that respond, the script encodes a PowerShell command and runs it remotely via PSExec as a background job. Results are written to C:\Windows\Temp\PSExecAudit_<servername>.txt on the remote machine and read back over the admin share once the job finishes. Temp files are cleaned up after collection.
The file-based approach avoids PSExec's stdout buffering issue, which silently drops lines when more than one result comes back through the pipe.

## License

MIT — use it, modify it, share it.
