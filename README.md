# aw-watcher-powershell

A PowerShell reimplementation of [aw-watcher-window][upstream] for users who
cannot execute `.ps1` files (e.g. restricted ExecutionPolicy) but **can**
paste a script into an interactive PowerShell window.

[upstream]: https://github.com/ActivityWatch/aw-watcher-window

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

## Verifying it works

With the watcher running, open `<Url>/#/timeline` in a browser. You should
see a bucket named `aw-watcher-window_<hostname>` with events whose `app`
is the foreground process name and `title` is the window title.
