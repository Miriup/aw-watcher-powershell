# aw-watcher-window for PowerShell
#
# Paste this whole script into a PowerShell window. It defines one function:
#
#   Start-AwWatcherWindow -Url <string>
#                         [-CertificatePath <path>] [-CertificatePassword <SecureString>]
#                         [-PollInterval <seconds>] [-BucketId <string>]
#                         [-SkipCertificateCheck]
#                         [-NoProxy] [-Proxy <uri>] [-ProxyUseDefaultCredentials] [-ProxyCredential <PSCredential>]
#
# Examples:
#   Start-AwWatcherWindow -Url http://localhost:5600
#   Start-AwWatcherWindow -Url https://aw.example.com -NoProxy
#   Start-AwWatcherWindow -Url https://aw.example.com -ProxyUseDefaultCredentials
#   Start-AwWatcherWindow -Url https://aw.example.com -Proxy http://proxy.corp:8080 -ProxyCredential (Get-Credential)
#   Start-AwWatcherWindow -Url https://aw.example.com -CertificatePath C:\certs\me.pfx
#   $pw = Read-Host -AsSecureString "PFX password"
#   Start-AwWatcherWindow -Url https://aw.example.com -CertificatePath .\me.pfx -CertificatePassword $pw
#
# Press Ctrl+C to stop the watcher.

try {
    Add-Type -Namespace AwWatcher -Name Win32 -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern System.IntPtr GetForegroundWindow();

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int GetWindowTextLength(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
'@ -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notmatch 'already exists') {
        Write-Warning "Failed to load Win32 helpers: $($_.Exception.Message)"
    }
}

function Start-AwWatcherWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter()]
        [string] $CertificatePath,

        [Parameter()]
        [System.Security.SecureString] $CertificatePassword,

        [Parameter()]
        [double] $PollInterval = 1.0,

        [Parameter()]
        [string] $BucketId,

        [Parameter()]
        [switch] $SkipCertificateCheck,

        [Parameter()]
        [switch] $NoProxy,

        [Parameter()]
        [string] $Proxy,

        [Parameter()]
        [switch] $ProxyUseDefaultCredentials,

        [Parameter()]
        [System.Management.Automation.PSCredential] $ProxyCredential
    )

    $ErrorActionPreference = 'Stop'

    if ($NoProxy -and ($ProxyUseDefaultCredentials -or $ProxyCredential -or $Proxy)) {
        throw '-NoProxy cannot be combined with -Proxy, -ProxyUseDefaultCredentials, or -ProxyCredential.'
    }

    $baseUrl = $Url.TrimEnd('/')
    $hostname = [System.Net.Dns]::GetHostName().ToLowerInvariant()
    if (-not $BucketId) { $BucketId = "aw-watcher-window_$hostname" }
    $clientName = 'aw-watcher-window-powershell'
    $pulseTime = $PollInterval + 1.0

    $certificate = $null
    if ($CertificatePath) {
        $resolved = (Resolve-Path -LiteralPath $CertificatePath).Path
        $plainPw = ''
        if ($CertificatePassword) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertificatePassword)
            try {
                $plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $resolved, $plainPw
        Write-Host "Loaded client certificate: $($certificate.Subject)"
    }

    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    if ($SkipCertificateCheck -and -not $isCore) {
        Write-Warning '-SkipCertificateCheck is only honoured on PowerShell 6+. On Windows PowerShell 5.1, trust the server certificate in your certificate store instead.'
    }

    $commonArgs = @{
        ContentType = 'application/json'
        TimeoutSec  = 10
        UseBasicParsing = $true
    }
    if ($certificate) { $commonArgs.Certificate = $certificate }
    if ($SkipCertificateCheck -and $isCore) { $commonArgs.SkipCertificateCheck = $true }
    if ($NoProxy -and $isCore) { $commonArgs.NoProxy = $true }

    if ($ProxyUseDefaultCredentials -or $ProxyCredential -or $Proxy) {
        $proxyUri = $Proxy
        if (-not $proxyUri) {
            try {
                $sysProxy = [System.Net.WebRequest]::DefaultWebProxy
                if ($sysProxy) {
                    $candidate = $sysProxy.GetProxy([Uri] $baseUrl)
                    if ($candidate -and $candidate.AbsoluteUri -ne ([Uri] $baseUrl).AbsoluteUri) {
                        $proxyUri = $candidate.AbsoluteUri
                    }
                }
            } catch {
                # fall through; we'll throw below
            }
        }
        if (-not $proxyUri) {
            throw 'Could not detect a system proxy. Pass -Proxy <uri> explicitly (e.g. -Proxy http://proxy.corp:8080).'
        }
        $commonArgs.Proxy = $proxyUri
        Write-Host "Using proxy: $proxyUri"
        if ($ProxyUseDefaultCredentials) { $commonArgs.ProxyUseDefaultCredentials = $true }
        if ($ProxyCredential)            { $commonArgs.ProxyCredential = $ProxyCredential }
    }

    $savedProxy = $null
    $proxyOverridden = $false
    if ($NoProxy -and -not $isCore) {
        $savedProxy = [System.Net.WebRequest]::DefaultWebProxy
        [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
        $proxyOverridden = $true
        Write-Host 'System proxy disabled for this session (Windows PowerShell 5.1 emulation of -NoProxy).'
    }

    function Invoke-AwRequest {
        param([string] $Method, [string] $Uri, [string] $Body)
        $params = @{ Method = $Method; Uri = $Uri } + $commonArgs
        if ($Body) { $params.Body = $Body }
        Invoke-RestMethod @params
    }

    $bucketUrl = "$baseUrl/api/0/buckets/$BucketId"
    $heartbeatUrl = "$bucketUrl/heartbeat?pulsetime=$pulseTime"

    $bucketBody = @{
        client   = $clientName
        hostname = $hostname
        type     = 'currentwindow'
    } | ConvertTo-Json -Compress

    try {
    $attempt = 0
    while ($true) {
        try {
            Invoke-AwRequest -Method Post -Uri $bucketUrl -Body $bucketBody | Out-Null
            Write-Host "Bucket ready: $BucketId at $baseUrl"
            break
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 304 -or $status -eq 200 -or $status -eq 201) {
                Write-Host "Bucket already exists: $BucketId"
                break
            }
            $attempt++
            $delay = [Math]::Min(30, [Math]::Pow(2, [Math]::Min($attempt, 5)))
            Write-Warning "Bucket creation failed (status=$status): $($_.Exception.Message). Retrying in ${delay}s..."
            if ($attempt -ge 5) {
                Write-Warning 'Giving up on bucket creation for now; heartbeats may still recover the bucket if the server comes online.'
                break
            }
            Start-Sleep -Seconds $delay
        }
    }

    Write-Host "Watching active window. Press Ctrl+C to stop."

    while ($true) {
        $app = 'unknown'
        $title = 'unknown'
        try {
            $hwnd = [AwWatcher.Win32]::GetForegroundWindow()
            if ($hwnd -ne [System.IntPtr]::Zero) {
                $len = [AwWatcher.Win32]::GetWindowTextLength($hwnd)
                if ($len -gt 0) {
                    $sb = New-Object System.Text.StringBuilder ($len + 1)
                    [void][AwWatcher.Win32]::GetWindowText($hwnd, $sb, $sb.Capacity)
                    $title = $sb.ToString()
                }
                $procId = 0
                [void][AwWatcher.Win32]::GetWindowThreadProcessId($hwnd, [ref] $procId)
                if ($procId -ne 0) {
                    try {
                        $proc = Get-Process -Id $procId -ErrorAction Stop
                        if ($proc.ProcessName) { $app = $proc.ProcessName }
                    } catch {
                        # process exited between calls; keep 'unknown'
                    }
                }
            }
        } catch {
            Write-Warning "Failed to read foreground window: $($_.Exception.Message)"
        }

        $event = @{
            timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            duration  = 0
            data      = @{ app = $app; title = $title }
        } | ConvertTo-Json -Compress

        try {
            Invoke-AwRequest -Method Post -Uri $heartbeatUrl -Body $event | Out-Null
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            Write-Warning "Heartbeat failed (status=$status): $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $PollInterval
    }
    }
    finally {
        if ($proxyOverridden) {
            [System.Net.WebRequest]::DefaultWebProxy = $savedProxy
            Write-Host 'Restored original system proxy.'
        }
    }
}

Write-Host "Loaded. Run: Start-AwWatcherWindow -Url http://localhost:5600"
