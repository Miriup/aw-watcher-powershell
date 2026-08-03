# aw-watcher-powershell

ActivityWatch watchers written in PowerShell, for users who cannot execute
`.ps1` files (e.g. restricted ExecutionPolicy) but **can** paste a script into
an interactive PowerShell window.

| Script | Function | Bucket | Records |
|--------|----------|--------|---------|
| `aw-watcher-window.ps1` | `Start-AwWatcherWindow` | `aw-watcher-window_<hostname>` | Foreground window: process name and window title. A reimplementation of [aw-watcher-window][upstream]. |
| `aw-watcher-powershell.ps1` | `Start-AwWatcherPowerShell` | `aw-watcher-powershell_<hostname>` | The PowerShell session it was pasted into: the command currently running and the current working directory. |

They are independent — run either one, or both in separate windows.

[upstream]: https://github.com/ActivityWatch/aw-watcher-window

# Window watcher

## Usage

1. Open `aw-watcher-window.ps1`, copy the whole file, and paste it into a
   PowerShell window. After paste you will see:

   ```
   Loaded. Run: Start-AwWatcherWindow -Url http://localhost:5600
   ```

2. Start the watcher:

   ```powershell
   Start-AwWatcherWindow -Url http://localhost:5600
   ```

   It blocks and sends heartbeats every second. Press **Ctrl+C** to stop.

## Parameters

| Parameter                | Description                                                                 |
|--------------------------|-----------------------------------------------------------------------------|
| `-Url`                   | ActivityWatch server URL (required), e.g. `http://localhost:5600`.          |
| `-CertificatePath`       | Path to a PFX/PKCS#12 file for mTLS client authentication.                  |
| `-CertificatePassword`   | `SecureString` password for the PFX (omit if the PFX is unencrypted).       |
| `-PollInterval`          | Seconds between window polls. Default `1.0`. Pulsetime is `PollInterval+1`. |
| `-BucketId`              | Override the bucket id (default: `aw-watcher-window_<hostname>`).           |
| `-SkipCertificateCheck`  | Skip server certificate validation. PowerShell 6+ only.                     |
| `-NoProxy`               | Bypass any configured system / WPAD proxy and connect directly.             |
| `-Proxy`                 | Explicit proxy URI (e.g. `http://proxy.corp:8080`). Auto-detected if omitted when proxy creds are given. |
| `-ProxyUseDefaultCredentials` | Authenticate to the system proxy with current Windows credentials.     |
| `-ProxyCredential`       | `PSCredential` with explicit username/password for the proxy.               |

## mTLS example

If your ActivityWatch server sits behind a reverse proxy that requires a
client certificate:

```powershell
$pw = Read-Host -AsSecureString "PFX password"
Start-AwWatcherWindow `
    -Url https://aw.example.com `
    -CertificatePath C:\certs\me.pfx `
    -CertificatePassword $pw
```

## Behind a corporate proxy

If your PowerShell session sits behind an HTTP proxy that intercepts traffic
to the AW server (you'll see `HTTP 407 Proxy Authentication Required`), pick
one of:

```powershell
# Skip the proxy entirely — use when the AW server is reachable directly.
Start-AwWatcherWindow -Url https://aw.example.com -NoProxy

# Authenticate to the proxy with your current Windows login (NTLM/Kerberos).
Start-AwWatcherWindow -Url https://aw.example.com -ProxyUseDefaultCredentials

# Authenticate with an explicit username/password.
$cred = Get-Credential
Start-AwWatcherWindow -Url https://aw.example.com -ProxyCredential $cred

# If the proxy can't be auto-detected, give the URL explicitly:
Start-AwWatcherWindow -Url https://aw.example.com -Proxy http://proxy.corp:8080 -ProxyUseDefaultCredentials
```

Windows PowerShell 5.1 requires an explicit `-Proxy` URL when proxy
credentials are used; the watcher tries to read it from the system settings
automatically, and surfaces a clear error if it can't.

On Windows PowerShell 5.1, `-NoProxy` is emulated by temporarily clearing the
session's default proxy and restoring it when the watcher stops.

## Verifying it works

With the watcher running, open `<Url>/#/timeline` in a browser. You should
see a bucket named `aw-watcher-window_<hostname>` with events whose `app`
is the foreground process name and `title` is the window title.

# Session details watcher

The window watcher only ever sees `powershell / Windows PowerShell`. This
second watcher reports what the session is actually doing: the command that
is currently running and the current working directory.

## Usage

1. Paste `aw-watcher-powershell.ps1` into the PowerShell window you want to
   track. After paste you will see:

   ```
   Loaded. Run: Start-AwWatcherPowerShell -Url http://localhost:5600
   ```

2. Start it:

   ```powershell
   Start-AwWatcherPowerShell -Url http://localhost:5600
   ```

   Unlike the window watcher this **does not block** — it returns immediately
   and you keep using the shell as usual. That is exactly what gets recorded.

3. Stop it with `Stop-AwWatcherPowerShell` (it also stops automatically when
   the window is closed).

It tracks the session it was pasted into, not other PowerShell processes on
the machine: only the session itself knows which command is running right now
and where. To track several shells, paste the script into each of them and add
`-PerSession` so they do not share one bucket.

## How it works

* A hook on `prompt` and on PSReadLine's `AddToHistoryHandler` records the
  submitted command line, the current directory and the result of the last
  command in a shared state object.
* A background runspace sends a heartbeat every `-PollInterval` seconds. A
  timer inside the session would only fire *between* commands — that is, never
  while a long-running command is going, which is the interesting case.
* Both hooks are chained onto whatever was installed before them and restored
  on stop, so a custom prompt or history handler keeps working.

Event `data` fields: `command`, `path`, `status` (`running`/`idle`), `shell`
(`pwsh`/`powershell`), `pid`, plus `result` and `exit_code` of the last
finished command. The bucket type is `app.terminal.activity`.

Without PSReadLine (Windows PowerShell ISE, for example) the running command
cannot be captured; directory tracking still works.

## Parameters

Same connection parameters as the window watcher (`-Url`, `-CertificatePath`,
`-CertificatePassword`, `-PollInterval`, `-BucketId`, `-SkipCertificateCheck`,
`-NoProxy`, `-Proxy`, `-ProxyUseDefaultCredentials`, `-ProxyCredential`) plus:

| Parameter         | Description                                                                       |
|-------------------|-----------------------------------------------------------------------------------|
| `-PerSession`     | Append the process id to the bucket id, so several tracked shells stay separate.  |
| `-CommandDetail`  | `Full` (default), `Name` (first token only), or `None` (directory only).          |
| `-NoRedaction`    | Send command lines verbatim, without the secret redaction described below.        |

## Command lines and secrets

Command lines regularly contain credentials. By default the watcher:

* replaces the value after `-Password`, `-Token`, `-ApiKey`, `-Secret`,
  `-Credential` and the like, as well as `token=`/`password=` style
  assignments, `Bearer <...>` and long base64/hex literals with `***`;
* falls back to the command name alone when PSReadLine's own handler considers
  the line sensitive (the same rule that keeps such lines out of your history
  file);
* truncates anything longer than 512 characters.

This is best effort, not a guarantee. If command arguments must never leave
the machine, use `-CommandDetail Name` — or `-CommandDetail None` to record
directories only.

```powershell
Start-AwWatcherPowerShell -Url http://localhost:5600 -CommandDetail Name
```

## Verifying it works

Start the watcher, `cd` somewhere, run something slow (`Start-Sleep 20`), then
open `<Url>/#/timeline`. The bucket `aw-watcher-powershell_<hostname>` should
show one ~20 s event with `command = Start-Sleep 20`, followed by idle events
carrying the directory you are sitting in.
