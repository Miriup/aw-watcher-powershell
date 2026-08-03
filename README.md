# aw-watcher-powershell

A PowerShell reimplementation of [aw-watcher-window][window] and
[aw-watcher-afk][afk] for users who cannot execute `.ps1` files (e.g.
restricted ExecutionPolicy) but **can** paste a script into an interactive
PowerShell window.

[window]: https://github.com/ActivityWatch/aw-watcher-window
[afk]: https://github.com/ActivityWatch/aw-watcher-afk

> The script used to be called `aw-watcher-window.ps1`. It now hosts the AFK
> watcher too, so it is simply `aw-watcher.ps1`.

## Usage

1. Open `aw-watcher.ps1`, copy the whole file, and paste it into a PowerShell
   window. After paste you will see:

   ```
   Loaded. Run: Start-AwWatcher       -Url http://localhost:5600  (window + AFK)
           or: Start-AwWatcherWindow -Url http://localhost:5600  (window only)
           or: Start-AwWatcherAfk    -Url http://localhost:5600  (AFK only)
   ```

2. Start the watcher:

   ```powershell
   Start-AwWatcher -Url http://localhost:5600
   ```

   It blocks and sends heartbeats until you press **Ctrl+C**.

If you have pasted an older version of this script into the same console,
open a **fresh** PowerShell window first — .NET types cannot be replaced in a
live session, and this script loads two of them.

## Which function do I run?

| Function | Buckets it fills | When |
|----------|------------------|------|
| `Start-AwWatcher`       | both | The normal choice. One paste, one console. |
| `Start-AwWatcherWindow` | `aw-watcher-window_<hostname>` | You only want window tracking, or you want to run the two watchers in separate consoles. |
| `Start-AwWatcherAfk`    | `aw-watcher-afk_<hostname>` | As above, for AFK only. |

`Start-AwWatcher` drives both watchers from a single loop, so a slow or
unreachable server stalls both together for the 10-second request timeout.
If that matters to you, run the two single-purpose functions in two consoles
instead.

## Parameters

All three functions accept the connection parameters. The window and AFK
parameters apply to whichever functions track that thing.

### Connection (all three functions)

| Parameter                | Description                                                                 |
|--------------------------|-----------------------------------------------------------------------------|
| `-Url`                   | ActivityWatch server URL (required), e.g. `http://localhost:5600`.          |
| `-CertificatePath`       | Path to a PFX/PKCS#12 file for mTLS client authentication.                  |
| `-CertificatePassword`   | `SecureString` password for the PFX (omit if the PFX is unencrypted).       |
| `-SkipCertificateCheck`  | Skip server certificate validation. PowerShell 6+ only.                     |
| `-NoProxy`               | Bypass any configured system / WPAD proxy and connect directly.             |
| `-Proxy`                 | Explicit proxy URI (e.g. `http://proxy.corp:8080`). Auto-detected if omitted when proxy creds are given. |
| `-ProxyUseDefaultCredentials` | Authenticate to the system proxy with current Windows credentials.     |
| `-ProxyCredential`       | `PSCredential` with explicit username/password for the proxy.               |

### Window (`Start-AwWatcher`, `Start-AwWatcherWindow`)

| Parameter       | Description                                                                 |
|-----------------|-----------------------------------------------------------------------------|
| `-PollInterval` | Seconds between window polls. Default `1.0`. Pulsetime is `PollInterval+1`. |
| `-BucketId`     | Override the bucket id (default: `aw-watcher-window_<hostname>`).            |

### AFK (`Start-AwWatcher`, `Start-AwWatcherAfk`)

| Parameter          | Description                                                                        |
|--------------------|------------------------------------------------------------------------------------|
| `-AfkTimeout`      | Seconds of no input before you count as away. Default `180.0`.                     |
| `-AfkPollInterval` | Seconds between idle checks. Default `5.0`.                                        |
| `-AfkBucketId`     | Override the bucket id (default: `aw-watcher-afk_<hostname>`).                      |

Pulsetime for the AFK bucket is `AfkTimeout + AfkPollInterval`, plus another
`PollInterval` under `Start-AwWatcher` — where the AFK check is gated on the
window loop, it can land up to one window poll late.

In `Start-AwWatcher`, AFK cannot be checked more often than `-PollInterval`,
since both share one loop. Setting `-AfkPollInterval` lower than
`-PollInterval` prints a warning rather than silently doing nothing.

## How AFK detection works

Idle time comes from the Win32 `GetLastInputInfo`, which reports when the
session last saw keyboard or mouse input. Events go to an `afkstatus` bucket
as `{"status":"afk"}` / `{"status":"not-afk"}`.

Heartbeats are stamped with **the time of the last input**, not the time the
watcher noticed. So an AFK block starts where you actually stopped typing,
not `AfkTimeout` seconds later — though it only becomes visible after that
timeout has elapsed.

Known limitations, all shared with the upstream Windows watcher:

- Gamepad and other DirectInput devices do not count as input.
- Watching a video without touching anything counts as AFK.
- A locked workstation counts as AFK.
- Input is per-session, and input to elevated processes is not seen by a
  non-elevated watcher.

> **Do not run this alongside ActivityWatch's bundled `aw-watcher-afk`**
> against the same server. Both write `aw-watcher-afk_<hostname>` and their
> events will fight. The same applies to `aw-watcher-window`.

> Overriding `-BucketId` or `-AfkBucketId` keeps events out of the web UI's
> Activity view, which finds buckets by their `aw-watcher-window_` /
> `aw-watcher-afk_` prefix.

## mTLS example

If your ActivityWatch server sits behind a reverse proxy that requires a
client certificate:

```powershell
$pw = Read-Host -AsSecureString "PFX password"
Start-AwWatcher `
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
Start-AwWatcher -Url https://aw.example.com -NoProxy

# Authenticate to the proxy with your current Windows login (NTLM/Kerberos).
Start-AwWatcher -Url https://aw.example.com -ProxyUseDefaultCredentials

# Authenticate with an explicit username/password.
$cred = Get-Credential
Start-AwWatcher -Url https://aw.example.com -ProxyCredential $cred

# If the proxy can't be auto-detected, give the URL explicitly:
Start-AwWatcher -Url https://aw.example.com -Proxy http://proxy.corp:8080 -ProxyUseDefaultCredentials
```

Windows PowerShell 5.1 requires an explicit `-Proxy` URL when proxy
credentials are used; the watcher tries to read it from the system settings
automatically, and surfaces a clear error if it can't.

On Windows PowerShell 5.1, `-NoProxy` is emulated by temporarily clearing the
session's default proxy and restoring it when the watcher stops.

## Verifying it works

Check the idle reader on its own, right after pasting — wait five seconds
without touching anything, then:

```powershell
[AwWatcher.Idle]::GetIdleMilliseconds()   # ≈ 5000
```

With `Start-AwWatcher` running, open `<Url>/#/buckets` in a browser. You
should see two buckets:

- `aw-watcher-window_<hostname>`, with events whose `app` is the foreground
  process name and `title` is the window title;
- `aw-watcher-afk_<hostname>`, with `not-afk` events while you are working.

To see an AFK transition without waiting three minutes, run with a short
timeout, leave the machine alone for half a minute, then move the mouse:

```powershell
Start-AwWatcherAfk -Url http://localhost:5600 -AfkTimeout 10 -AfkPollInterval 2
```

The timeline should show one contiguous `afk` block that begins about ten
seconds after your last input — not at the moment it was detected — and ends
when you moved the mouse.
