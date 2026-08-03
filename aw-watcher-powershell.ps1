# aw-watcher-powershell — session details watcher
#
# Reports what a PowerShell session is doing: the command that is currently
# running and the current working directory. Paste this whole script into the
# PowerShell window you want to track. It defines two functions:
#
#   Start-AwWatcherPowerShell -Url <string>
#                             [-CertificatePath <path>] [-CertificatePassword <SecureString>]
#                             [-PollInterval <seconds>] [-BucketId <string>] [-PerSession]
#                             [-CommandDetail Full|Name|None] [-NoRedaction]
#                             [-SkipCertificateCheck]
#                             [-NoProxy] [-Proxy <uri>] [-ProxyUseDefaultCredentials] [-ProxyCredential <PSCredential>]
#
#   Stop-AwWatcherPowerShell
#
# Unlike Start-AwWatcherWindow this does NOT block: it hooks the prompt and
# PSReadLine, starts a background runspace that sends the heartbeats, and
# returns immediately. Keep using the shell as usual; that is exactly what
# gets recorded. Stop it with Stop-AwWatcherPowerShell.
#
# Examples:
#   Start-AwWatcherPowerShell -Url http://localhost:5600
#   Start-AwWatcherPowerShell -Url http://localhost:5600 -CommandDetail Name
#   Start-AwWatcherPowerShell -Url https://aw.example.com -PerSession -ProxyUseDefaultCredentials

function Get-AwCurrentPath {
    # Session-wide current location, works from inside PSReadLine handlers too.
    try {
        $loc = $ExecutionContext.SessionState.Path.CurrentLocation
        if ($loc.ProviderPath) { return $loc.ProviderPath }
        return $loc.Path
    } catch {
        return ''
    }
}

function ConvertTo-AwSafeCommand {
    [CmdletBinding()]
    param(
        [string] $CommandLine,

        [ValidateSet('Full', 'Name', 'None')]
        [string] $Detail = 'Full',

        [switch] $Redact
    )

    if ($Detail -eq 'None' -or [string]::IsNullOrWhiteSpace($CommandLine)) { return '' }

    $line = ($CommandLine -replace '\s+', ' ').Trim()

    if ($Detail -eq 'Name') { return (($line -split ' ')[0]).Trim('"', "'") }

    if ($Redact) {
        # Best effort only — this is not a security guarantee. Use
        # -CommandDetail Name if command arguments must never leave the machine.
        $line = $line -replace '(?i)(-(?:password|passwd|pwd|token|apikey|api_key|secret|clientsecret|credential)\s*:?\s+)("[^"]*"|''[^'']*''|[^\s"'']+)', '$1***'
        $line = $line -replace '(?i)((?:password|passwd|pwd|token|api[_-]?key|secret|access[_-]?key|auth)\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s"''&]+)', '$1***'
        $line = $line -replace '(?i)\b(bearer)\s+\S+', '$1 ***'
        $line = $line -replace '[A-Za-z0-9+/]{40,}={0,2}', '***'
    }

    if ($line.Length -gt 512) { $line = $line.Substring(0, 509) + '...' }
    return $line
}

function Start-AwWatcherPowerShell {
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
        [switch] $PerSession,

        [Parameter()]
        [ValidateSet('Full', 'Name', 'None')]
        [string] $CommandDetail = 'Full',

        [Parameter()]
        [switch] $NoRedaction,

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

    if ($global:AwWatcherPowerShell) {
        throw 'A session watcher is already running in this shell. Call Stop-AwWatcherPowerShell first.'
    }

    if ($NoProxy -and ($ProxyUseDefaultCredentials -or $ProxyCredential -or $Proxy)) {
        throw '-NoProxy cannot be combined with -Proxy, -ProxyUseDefaultCredentials, or -ProxyCredential.'
    }

    $baseUrl = $Url.TrimEnd('/')
    $hostname = [System.Net.Dns]::GetHostName().ToLowerInvariant()
    if (-not $BucketId) {
        $BucketId = "aw-watcher-powershell_$hostname"
        if ($PerSession) { $BucketId = "${BucketId}_$PID" }
    }
    $clientName = 'aw-watcher-powershell'
    # Format invariantly so a comma decimal separator never reaches the query string.
    $pulseTime = ($PollInterval + 1.0).ToString([System.Globalization.CultureInfo]::InvariantCulture)

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
        # Encode to UTF-8 bytes ourselves: Windows PowerShell 5.1 sends string
        # bodies as Latin-1, which the server rejects as invalid UTF-8 as soon
        # as a path or command contains a non-ASCII character.
        if ($Body) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        Invoke-RestMethod @params
    }

    $bucketUrl = "$baseUrl/api/0/buckets/$BucketId"
    $heartbeatUrl = "$bucketUrl/heartbeat?pulsetime=$pulseTime"

    $bucketBody = @{
        client   = $clientName
        hostname = $hostname
        type     = 'app.terminal.activity'
    } | ConvertTo-Json -Compress

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

    $state = [hashtable]::Synchronized(@{
        Running       = $true
        Status        = 'idle'
        Command       = ''
        Path          = (Get-AwCurrentPath)
        ExitCode      = $null
        Result        = $null
        LastError     = $null
        ErrorReported = $true
    })

    $shellName = if ($isCore) { 'pwsh' } else { 'powershell' }
    $config = @{
        HeartbeatUrl = $heartbeatUrl
        CommonArgs   = $commonArgs
        SleepMs      = [int][Math]::Max(100, $PollInterval * 1000)
        Shell        = $shellName
        SessionPid   = $PID
    }

    # The heartbeats must come from a second runspace: an in-session timer only
    # fires between commands, which is precisely when nothing is running.
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('State', $state)
    $runspace.SessionStateProxy.SetVariable('Cfg', $config)

    $sender = [powershell]::Create()
    $sender.Runspace = $runspace
    [void] $sender.AddScript({
        while ($State.Running) {
            try {
                $body = @{
                    timestamp = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                    duration  = 0
                    data      = @{
                        shell     = $Cfg.Shell
                        status    = $State.Status
                        path      = $State.Path
                        command   = $State.Command
                        exit_code = $State.ExitCode
                        result    = $State.Result
                        pid       = $Cfg.SessionPid
                    }
                } | ConvertTo-Json -Compress -Depth 5

                $params = @{
                    Method = 'Post'
                    Uri    = $Cfg.HeartbeatUrl
                    Body   = [System.Text.Encoding]::UTF8.GetBytes($body)
                } + $Cfg.CommonArgs
                Invoke-RestMethod @params | Out-Null
                $State.LastError = $null
            } catch {
                # Nothing is displayed from this runspace; hand the message to
                # the prompt hook, which surfaces it once.
                $State.LastError = $_.Exception.Message
                $State.ErrorReported = $false
            }
            Start-Sleep -Milliseconds $Cfg.SleepMs
        }
    })

    $newPrompt = {
        $ok = $?
        $lastExit = $global:LASTEXITCODE
        $w = $global:AwWatcherPowerShell
        if ($w) {
            try {
                $w.State.Status   = 'idle'
                $w.State.Command  = ''
                $w.State.Path     = Get-AwCurrentPath
                $w.State.ExitCode = $lastExit

                $result = $null
                $last = Get-History -Count 1 -ErrorAction SilentlyContinue
                if ($last) { $result = [string] $last.ExecutionStatus }
                if (-not $result) { $result = if ($ok) { 'Completed' } else { 'Failed' } }
                $w.State.Result = $result

                if ($w.State.LastError -and -not $w.State.ErrorReported) {
                    $w.State.ErrorReported = $true
                    Write-Warning "aw-watcher-powershell heartbeat failed: $($w.State.LastError)"
                }
            } catch {
                # never break the prompt
            }
        }

        if ($w -and $w.OldPrompt) { & $w.OldPrompt }
        else { "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> " }
    }

    $oldPrompt = $null
    $promptCmd = Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($promptCmd) { $oldPrompt = $promptCmd.ScriptBlock }

    $historyHandler = {
        param([string] $line)
        $w = $global:AwWatcherPowerShell

        $decision = $true
        if ($w -and $w.OldHistoryHandler) {
            # PSReadLine ships its own default handler, which arrives here as a
            # Func delegate rather than a ScriptBlock — keep calling whichever
            # was installed before us so its decision still wins.
            try {
                $previous = $w.OldHistoryHandler
                if ($previous -is [scriptblock]) { $decision = & $previous $line }
                else { $decision = $previous.Invoke($line) }
            } catch {
                $decision = $true
            }
        }

        if ($w) {
            try {
                $detail = $w.CommandDetail
                # PSReadLine's default handler answers MemoryOnly / SkipAdding
                # for lines it considers sensitive (passwords, tokens, ...).
                # Take that as a hint and send the command name only.
                $allowed = if ($decision -is [bool]) { $decision } else { ([string] $decision) -eq 'MemoryAndFile' }
                if ($detail -eq 'Full' -and -not $allowed) { $detail = 'Name' }

                $w.State.Command  = ConvertTo-AwSafeCommand -CommandLine $line -Detail $detail -Redact:$w.Redact
                $w.State.Path     = Get-AwCurrentPath
                $w.State.ExitCode = $null
                $w.State.Result   = $null
                $w.State.Status   = 'running'
            } catch {
                # never break the input loop
            }
        }

        return $decision
    }

    $oldHistoryHandler = $null
    $hasPSReadLine = [bool] (Get-Command -Name Set-PSReadLineOption -ErrorAction SilentlyContinue)
    if ($hasPSReadLine) {
        try { $oldHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler } catch { }
    }

    $global:AwWatcherPowerShell = @{
        State             = $state
        Config            = $config
        Runspace          = $runspace
        Sender            = $sender
        Handle            = $null
        BucketId          = $BucketId
        CommandDetail     = $CommandDetail
        Redact            = (-not $NoRedaction)
        OldPrompt         = $oldPrompt
        NewPrompt         = $newPrompt
        OldHistoryHandler = $oldHistoryHandler
        NewHistoryHandler = $historyHandler
        HasPSReadLine     = $hasPSReadLine
        SavedProxy        = $savedProxy
        ProxyOverridden   = $proxyOverridden
        ExitSubscription  = $null
    }

    $global:AwWatcherPowerShell.Handle = $sender.BeginInvoke()

    Set-Item -Path function:global:prompt -Value $newPrompt
    if ($hasPSReadLine) {
        try {
            Set-PSReadLineOption -AddToHistoryHandler $historyHandler
        } catch {
            $global:AwWatcherPowerShell.HasPSReadLine = $false
            Write-Warning "Could not hook PSReadLine: $($_.Exception.Message). Only the working directory will be tracked."
        }
    } else {
        Write-Warning 'PSReadLine is not available, so running commands cannot be captured. Only the working directory will be tracked.'
    }

    try {
        $global:AwWatcherPowerShell.ExitSubscription =
            Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-AwWatcherPowerShell }
    } catch {
        # Not fatal: the runspace dies with the process anyway.
    }

    Write-Host "Watching this PowerShell session (bucket: $BucketId, commands: $CommandDetail). Keep working; run Stop-AwWatcherPowerShell to stop."
}

function Stop-AwWatcherPowerShell {
    [CmdletBinding()]
    param()

    $w = $global:AwWatcherPowerShell
    if (-not $w) {
        Write-Warning 'No session watcher is running in this shell.'
        return
    }

    $w.State.Running = $false

    $currentPrompt = Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($currentPrompt -and $currentPrompt.ScriptBlock -eq $w.NewPrompt) {
        if ($w.OldPrompt) {
            Set-Item -Path function:global:prompt -Value $w.OldPrompt
        } else {
            Remove-Item -Path function:global:prompt -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning 'The prompt function was replaced after the watcher started; leaving it untouched.'
    }

    if ($w.HasPSReadLine) {
        try {
            $current = (Get-PSReadLineOption).AddToHistoryHandler
            if ($current -eq $w.NewHistoryHandler) {
                Set-PSReadLineOption -AddToHistoryHandler $w.OldHistoryHandler
            }
        } catch {
            Write-Warning "Could not restore the PSReadLine history handler: $($_.Exception.Message)"
        }
    }

    if ($w.ExitSubscription) {
        Unregister-Event -SubscriptionId $w.ExitSubscription.Id -ErrorAction SilentlyContinue
    }

    try { $w.Sender.Stop() } catch { }
    try { $w.Sender.Dispose() } catch { }
    try { $w.Runspace.Close(); $w.Runspace.Dispose() } catch { }

    if ($w.ProxyOverridden) {
        [System.Net.WebRequest]::DefaultWebProxy = $w.SavedProxy
        Write-Host 'Restored original system proxy.'
    }

    Remove-Variable -Name AwWatcherPowerShell -Scope Global -ErrorAction SilentlyContinue
    Write-Host 'Session watcher stopped.'
}

Write-Host "Loaded. Run: Start-AwWatcherPowerShell -Url http://localhost:5600"
