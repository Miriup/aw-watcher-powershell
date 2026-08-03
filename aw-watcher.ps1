# aw-watcher for PowerShell
#
# Paste this whole script into a PowerShell window. It defines three functions:
#
#   Start-AwWatcher       - active window AND AFK status (start here)
#   Start-AwWatcherWindow - active window only
#   Start-AwWatcherAfk    - AFK status only
#
# All three accept the same connection parameters:
#
#       -Url <string>
#       [-CertificatePath <path>] [-CertificatePassword <SecureString>]
#       [-SkipCertificateCheck]
#       [-NoProxy] [-Proxy <uri>] [-ProxyUseDefaultCredentials] [-ProxyCredential <PSCredential>]
#
# plus, where they apply:
#
#       [-PollInterval <seconds>] [-BucketId <string>]              window
#       [-AfkTimeout <seconds>] [-AfkPollInterval <seconds>]        AFK
#       [-AfkBucketId <string>]                                     AFK
#
# Examples:
#   Start-AwWatcher -Url http://localhost:5600
#   Start-AwWatcher -Url http://localhost:5600 -AfkTimeout 300
#   Start-AwWatcherAfk -Url http://localhost:5600 -AfkTimeout 10 -AfkPollInterval 2
#   Start-AwWatcher -Url https://aw.example.com -NoProxy
#   Start-AwWatcher -Url https://aw.example.com -ProxyUseDefaultCredentials
#   Start-AwWatcher -Url https://aw.example.com -Proxy http://proxy.corp:8080 -ProxyCredential (Get-Credential)
#   Start-AwWatcher -Url https://aw.example.com -CertificatePath C:\certs\me.pfx
#   $pw = Read-Host -AsSecureString "PFX password"
#   Start-AwWatcher -Url https://aw.example.com -CertificatePath .\me.pfx -CertificatePassword $pw
#
# Press Ctrl+C to stop the watcher.
#
# If you have pasted an older version of this script into the same console,
# open a FRESH PowerShell window: .NET types cannot be replaced in a live
# session, and this script loads two of them.

# NOTE: .NET types cannot be replaced once loaded, and the catch below deliberately
# swallows the "already exists" error so re-pasting the script is harmless. The
# consequence is that MEMBERS MUST NEVER BE ADDED TO AN ALREADY-PUBLISHED CLASS:
# a console that pasted an older version would silently keep the old class and the
# new members would be missing at call time. Introduce a new class name instead.
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

# Idle detection lives in its own class rather than in AwWatcher.Win32 above,
# precisely because of the note there: a console that already pasted an older
# version of this script cannot have members added to a class it already holds.
# A never-before-published class name loads cleanly even in such a console.
try {
    Add-Type -Namespace AwWatcher -Name Idle -MemberDefinition @'
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        // Both the struct and the import must be private: a public method taking
        // a private type is CS0051 (inconsistent accessibility).
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        // Milliseconds since the last keyboard or mouse input in this session.
        //
        // Environment.TickCount and LASTINPUTINFO.dwTime share the same 32-bit
        // GetTickCount base, which wraps every ~49.7 days. The subtraction is
        // therefore done unchecked and UNSIGNED so the wrap cancels out; in
        // signed arithmetic it would return a huge value once every 49.7 days
        // and pin the machine as "afk" until the next reboot.
        //
        // TickCount64 is deliberately not used: it does not exist on the .NET
        // Framework that Windows PowerShell 5.1 compiles this against. For the
        // same reason this stays within C# 5 -- 5.1 uses the CodeDom compiler,
        // where anything newer fails to compile even though PowerShell 7's
        // Roslyn accepts it.
        public static uint GetIdleMilliseconds() {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint) System.Runtime.InteropServices.Marshal.SizeOf(typeof(LASTINPUTINFO));
            lii.dwTime = 0;
            if (!GetLastInputInfo(ref lii)) {
                // Not Win32Exception: System.ComponentModel is not guaranteed to
                // be in Add-Type's default reference set on .NET Core.
                throw new System.InvalidOperationException(
                    "GetLastInputInfo failed with Win32 error " +
                    System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            }
            unchecked {
                return ((uint) System.Environment.TickCount) - lii.dwTime;
            }
        }
'@ -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notmatch 'already exists') {
        Write-Warning "Failed to load idle-time helper: $($_.Exception.Message)"
    }
}

if (-not ('AwWatcher.Idle' -as [type])) {
    Write-Warning 'AwWatcher.Idle is not available in this session, so AFK tracking will not work. Open a fresh PowerShell window and paste the script again.'
}

function Format-AwInvariant {
    # Every number that reaches a query string goes through here. A bare
    # $Value.ToString() is culture-sensitive and yields "2,5" under e.g. de-DE,
    # which the server rejects as a pulsetime; the explicit format provider is
    # what prevents that.
    param([double] $Value)
    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Select-AwConnectionArgs {
    # Narrows a caller's $PSBoundParameters down to the connection parameters, so
    # an entry point can splat into New-AwWatcherContext without its own
    # watcher-specific parameters causing a "cannot find parameter" error.
    param([System.Collections.IDictionary] $Bound)

    $keys = @(
        'Url', 'CertificatePath', 'CertificatePassword', 'SkipCertificateCheck',
        'NoProxy', 'Proxy', 'ProxyUseDefaultCredentials', 'ProxyCredential'
    )
    $selected = @{}
    foreach ($key in $keys) {
        # ContainsKey, not Contains: $PSBoundParameters is a generic dictionary
        # that implements IDictionary.Contains only explicitly, so PowerShell
        # cannot see it.
        if ($Bound.ContainsKey($key)) { $selected[$key] = $Bound[$key] }
    }
    return $selected
}

function New-AwWatcherContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter()]
        [string] $CertificatePath,

        [Parameter()]
        [System.Security.SecureString] $CertificatePassword,

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
        ContentType = 'application/json; charset=utf-8'
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

    $context = @{
        BaseUrl         = $baseUrl
        Hostname        = $hostname
        IsCore          = $isCore
        CommonArgs      = $commonArgs
        SavedProxy      = $null
        ProxyOverridden = $false
    }

    # Replacing DefaultWebProxy is a process-wide side effect, and it happens
    # before the caller's try/finally exists. Keep it as the last thing this
    # function does, so nothing that could throw runs between the override and
    # the caller taking responsibility for restoring it.
    if ($NoProxy -and -not $isCore) {
        $context.SavedProxy = [System.Net.WebRequest]::DefaultWebProxy
        [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
        $context.ProxyOverridden = $true
        Write-Host 'System proxy disabled for this session (Windows PowerShell 5.1 emulation of -NoProxy).'
    }

    return $context
}

function Close-AwWatcherContext {
    # Idempotent: Ctrl+C unwinding can re-enter this, and calling it twice must
    # not clobber the proxy a second time.
    param([hashtable] $Context)

    if ($Context -and $Context.ProxyOverridden) {
        [System.Net.WebRequest]::DefaultWebProxy = $Context.SavedProxy
        $Context.ProxyOverridden = $false
        Write-Host 'Restored original system proxy.'
    }
}

function Invoke-AwRequest {
    # $Context is passed explicitly rather than resolved from the caller's scope:
    # PowerShell looks free variables up dynamically, so relying on that would
    # work by accident and break silently when called from anywhere else.
    param([hashtable] $Context, [string] $Method, [string] $Uri, [string] $Body)

    $params = @{ Method = $Method; Uri = $Uri } + $Context.CommonArgs
    # Encode to UTF-8 bytes ourselves: Windows PowerShell 5.1 sends string
    # bodies as Latin-1, which the server rejects as invalid UTF-8 as soon
    # as a window title contains a non-ASCII character.
    if ($Body) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
    Invoke-RestMethod @params
}

function Initialize-AwBucket {
    param([hashtable] $Context, [string] $BucketId, [string] $Type, [string] $Client)

    $bucketUrl = "$($Context.BaseUrl)/api/0/buckets/$BucketId"
    $bucketBody = @{
        client   = $Client
        hostname = $Context.Hostname
        type     = $Type
    } | ConvertTo-Json -Compress

    $attempt = 0
    while ($true) {
        try {
            Invoke-AwRequest -Context $Context -Method Post -Uri $bucketUrl -Body $bucketBody | Out-Null
            Write-Host "Bucket ready: $BucketId at $($Context.BaseUrl)"
            return
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 304 -or $status -eq 200 -or $status -eq 201) {
                Write-Host "Bucket already exists: $BucketId"
                return
            }
            $attempt++
            $delay = [Math]::Min(30, [Math]::Pow(2, [Math]::Min($attempt, 5)))
            Write-Warning "Bucket creation failed (status=$status): $($_.Exception.Message). Retrying in ${delay}s..."
            if ($attempt -ge 5) {
                Write-Warning 'Giving up on bucket creation for now; heartbeats may still recover the bucket if the server comes online.'
                return
            }
            Start-Sleep -Seconds $delay
        }
    }
}

function Send-AwHeartbeat {
    # The single place a heartbeat is formatted and sent. Never throws.
    param(
        [hashtable] $Context,
        [string] $BucketId,
        [string] $PulseTime,
        [DateTime] $Timestamp,
        [double] $Duration,
        [hashtable] $Data,
        [string] $Label
    )

    # ConvertTo-Json's default -Depth of 2 exactly covers this shape. A raw
    # [DateTime] here would serialise as "\/Date(...)\/" on Windows PowerShell
    # 5.1, hence the pre-formatted string.
    $body = @{
        # 'o' is the culture-invariant round-trip format and yields the
        # trailing 'Z' because the timestamp has Kind=Utc.
        timestamp = $Timestamp.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        duration  = [Math]::Round($Duration, 3)
        data      = $Data
    } | ConvertTo-Json -Compress

    $uri = "$($Context.BaseUrl)/api/0/buckets/$BucketId/heartbeat?pulsetime=$PulseTime"
    try {
        Invoke-AwRequest -Context $Context -Method Post -Uri $uri -Body $body | Out-Null
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        Write-Warning "$Label heartbeat failed (status=$status): $($_.Exception.Message)"
    }
}

function Get-AwWindowEvent {
    # Never throws; falls back to 'unknown' so the loop keeps reporting.
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

    return @{ app = $app; title = $title }
}

function Invoke-AwWindowTick {
    param([hashtable] $Context, [hashtable] $Window)

    $data = Get-AwWindowEvent
    Send-AwHeartbeat -Context $Context -BucketId $Window.BucketId -PulseTime $Window.PulseTime `
        -Timestamp ([DateTime]::UtcNow) -Duration 0 -Data $data -Label 'Window'
}

function Get-AwIdleSeconds {
    # Returns $null rather than throwing when the idle time cannot be read, so
    # the caller can skip a tick without a try/catch. Being its own function
    # also makes it the single seam to stub when testing the state machine.
    try {
        return [double]([AwWatcher.Idle]::GetIdleMilliseconds()) / 1000.0
    } catch {
        Write-Warning "Failed to read idle time: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-AwAfkTick {
    # One iteration of the AFK state machine, mirroring upstream aw-watcher-afk.
    #
    # Every heartbeat is stamped with the time of the LAST INPUT, not the time
    # of detection. That is what makes an AFK block start where the user
    # actually stopped typing instead of $Timeout seconds later, and it is what
    # lets consecutive ticks merge into one event: the timestamp does not move
    # while the user stays idle.
    param([hashtable] $Context, [hashtable] $Afk)

    $idleSeconds = Get-AwIdleSeconds
    # Skip the tick entirely on a read failure. Guessing here would fabricate a
    # transition that never happened.
    if ($null -eq $idleSeconds) { return }

    # Sample the clock once: calling UtcNow twice would land the two heartbeats
    # of a transition on slightly different timestamps and break the seal.
    $lastInput = [DateTime]::UtcNow.AddSeconds(-$idleSeconds)

    $common = @{
        Context   = $Context
        BucketId  = $Afk.BucketId
        PulseTime = $Afk.PulseTime
        Timestamp = $lastInput
        Label     = 'AFK'
    }
    $afkData    = @{ status = 'afk' }
    $notAfkData = @{ status = 'not-afk' }

    # The state flips whether or not the heartbeat reached the server. That is
    # deliberate and self-healing: a lost "open" heartbeat is recreated by the
    # next steady-state tick at the same timestamp with a longer duration,
    # whereas retrying the transition would re-fire it forever.
    if ($Afk.State.Afk -and $idleSeconds -lt $Afk.Timeout) {
        # Input resumed: seal the afk period, then open not-afk.
        Send-AwHeartbeat @common -Duration 0 -Data $afkData
        $Afk.State.Afk = $false
        Send-AwHeartbeat @common -Duration 0 -Data $notAfkData
    }
    elseif (-not $Afk.State.Afk -and $idleSeconds -ge $Afk.Timeout) {
        # Gone idle long enough: seal not-afk, then open afk covering the
        # whole idle span so far.
        Send-AwHeartbeat @common -Duration 0 -Data $notAfkData
        $Afk.State.Afk = $true
        Send-AwHeartbeat @common -Duration $idleSeconds -Data $afkData
    }
    elseif ($Afk.State.Afk) {
        Send-AwHeartbeat @common -Duration $idleSeconds -Data $afkData
    }
    else {
        Send-AwHeartbeat @common -Duration 0 -Data $notAfkData
    }
}

function Invoke-AwWatcherLoop {
    # One loop drives every watcher; a $null half of $Plan simply disables it.
    param([hashtable] $Context, [hashtable] $Plan)

    # Start-Sleep -Seconds takes an [int] on Windows PowerShell 5.1 (only PS 6+
    # accepts a double), so a fractional interval would silently round -- and
    # round to zero below 0.5, busy-looping. Sleep in milliseconds instead.
    $sleepMs = [int][Math]::Max(1, [Math]::Round($Plan.TickInterval * 1000))

    # The AFK watcher usually ticks more slowly than the window watcher, so it
    # is gated on a deadline instead of getting its own loop. Rebasing the
    # deadline off the current time (rather than advancing it by a fixed step)
    # means a laptop resuming from sleep does not fire a burst of catch-up
    # ticks that would all read the same idle value. The cost is that the real
    # AFK period can run up to one tick long, which the pulse time allows for.
    $nextAfk = [DateTime]::UtcNow

    while ($true) {
        if ($Plan.Window) { Invoke-AwWindowTick -Context $Context -Window $Plan.Window }

        if ($Plan.Afk -and [DateTime]::UtcNow -ge $nextAfk) {
            Invoke-AwAfkTick -Context $Context -Afk $Plan.Afk
            $nextAfk = [DateTime]::UtcNow.AddSeconds($Plan.Afk.PollInterval)
        }

        Start-Sleep -Milliseconds $sleepMs
    }
}

function New-AwAfkPlan {
    # $State is a nested hashtable so Invoke-AwAfkTick can mutate it through
    # the reference it is handed.
    param([string] $BucketId, [double] $Timeout, [double] $PollInterval, [double] $PulseTime)

    return @{
        BucketId     = $BucketId
        Timeout      = $Timeout
        PollInterval = $PollInterval
        PulseTime    = Format-AwInvariant $PulseTime
        State        = @{ Afk = $false }
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
        [ValidateRange(0.05, 3600.0)]
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

    $connectionArgs = Select-AwConnectionArgs $PSBoundParameters
    $context = New-AwWatcherContext @connectionArgs
    try {
        if (-not $BucketId) { $BucketId = "aw-watcher-window_$($context.Hostname)" }
        Initialize-AwBucket -Context $context -BucketId $BucketId `
            -Type 'currentwindow' -Client 'aw-watcher-window-powershell'

        $plan = @{
            TickInterval = $PollInterval
            Window       = @{
                BucketId  = $BucketId
                PulseTime = Format-AwInvariant ($PollInterval + 1.0)
            }
        }

        Write-Host "Watching active window. Press Ctrl+C to stop."
        Invoke-AwWatcherLoop -Context $context -Plan $plan
    }
    finally {
        Close-AwWatcherContext -Context $context
    }
}

function Start-AwWatcherAfk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter()]
        [string] $CertificatePath,

        [Parameter()]
        [System.Security.SecureString] $CertificatePassword,

        [Parameter()]
        [ValidateRange(1.0, 86400.0)]
        [double] $AfkTimeout = 180.0,

        [Parameter()]
        [ValidateRange(0.05, 3600.0)]
        [double] $AfkPollInterval = 5.0,

        [Parameter()]
        [string] $AfkBucketId,

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

    $connectionArgs = Select-AwConnectionArgs $PSBoundParameters
    $context = New-AwWatcherContext @connectionArgs
    try {
        if (-not $AfkBucketId) { $AfkBucketId = "aw-watcher-afk_$($context.Hostname)" }
        Initialize-AwBucket -Context $context -BucketId $AfkBucketId `
            -Type 'afkstatus' -Client 'aw-watcher-afk-powershell'

        $plan = @{
            TickInterval = $AfkPollInterval
            Afk          = New-AwAfkPlan -BucketId $AfkBucketId -Timeout $AfkTimeout `
                -PollInterval $AfkPollInterval -PulseTime ($AfkTimeout + $AfkPollInterval)
        }

        Write-Host "Watching AFK status (timeout ${AfkTimeout}s). Press Ctrl+C to stop."
        Invoke-AwWatcherLoop -Context $context -Plan $plan
    }
    finally {
        Close-AwWatcherContext -Context $context
    }
}

function Start-AwWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter()]
        [string] $CertificatePath,

        [Parameter()]
        [System.Security.SecureString] $CertificatePassword,

        [Parameter()]
        [ValidateRange(0.05, 3600.0)]
        [double] $PollInterval = 1.0,

        [Parameter()]
        [string] $BucketId,

        [Parameter()]
        [ValidateRange(1.0, 86400.0)]
        [double] $AfkTimeout = 180.0,

        [Parameter()]
        [ValidateRange(0.05, 3600.0)]
        [double] $AfkPollInterval = 5.0,

        [Parameter()]
        [string] $AfkBucketId,

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

    # The shared loop ticks at the window interval, so the AFK watcher cannot
    # run faster than that however it is configured.
    if ($AfkPollInterval -lt $PollInterval) {
        Write-Warning "-AfkPollInterval ${AfkPollInterval}s is shorter than -PollInterval ${PollInterval}s; AFK will be checked every ${PollInterval}s."
    }

    $connectionArgs = Select-AwConnectionArgs $PSBoundParameters
    $context = New-AwWatcherContext @connectionArgs
    try {
        if (-not $BucketId)    { $BucketId    = "aw-watcher-window_$($context.Hostname)" }
        if (-not $AfkBucketId) { $AfkBucketId = "aw-watcher-afk_$($context.Hostname)" }

        Initialize-AwBucket -Context $context -BucketId $BucketId `
            -Type 'currentwindow' -Client 'aw-watcher-window-powershell'
        Initialize-AwBucket -Context $context -BucketId $AfkBucketId `
            -Type 'afkstatus' -Client 'aw-watcher-afk-powershell'

        $plan = @{
            TickInterval = $PollInterval
            Window       = @{
                BucketId  = $BucketId
                PulseTime = Format-AwInvariant ($PollInterval + 1.0)
            }
            # One extra PollInterval of pulse time, because the AFK tick is
            # gated on the window loop and so can land up to one window poll
            # late. Without it a late tick could fail to merge and split the
            # event in two.
            Afk          = New-AwAfkPlan -BucketId $AfkBucketId -Timeout $AfkTimeout `
                -PollInterval $AfkPollInterval -PulseTime ($AfkTimeout + $AfkPollInterval + $PollInterval)
        }

        Write-Host "Watching active window and AFK status (timeout ${AfkTimeout}s). Press Ctrl+C to stop."
        Invoke-AwWatcherLoop -Context $context -Plan $plan
    }
    finally {
        Close-AwWatcherContext -Context $context
    }
}

Write-Host "Loaded. Run: Start-AwWatcher       -Url http://localhost:5600  (window + AFK)"
Write-Host "        or: Start-AwWatcherWindow -Url http://localhost:5600  (window only)"
Write-Host "        or: Start-AwWatcherAfk    -Url http://localhost:5600  (AFK only)"
