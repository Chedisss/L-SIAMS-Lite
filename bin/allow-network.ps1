# ===========================================================================
#  L-SIAMS - let phones, tablets and laptops on the school network reach this PC
#
#  Run through allow-network.bat, which asks Windows for administrator rights.
#  Everything here can be done by hand (docs\NETWORK-ACCESS.md); this does it
#  in one go and says what it changed:
#
#    1. the network this PC is on is set to Private. On a Public network
#       Windows refuses other devices however the firewall rules read;
#    2. "Block" rules for php.exe are removed. Windows writes them when its
#       "allow PHP?" box is cancelled or closed, and a block rule beats any
#       allow rule, so the port rules below would do nothing;
#    3. ports 8080 (pages) and 8443 (live updates) are opened, on Private and
#       Domain networks only - never Public;
#    4. the address other devices should type is printed, taken from the
#       adapter that actually has a router, not a VirtualBox or Hyper-V one;
#    5. .env is checked to make sure it lets that address range in.
# ===========================================================================

param([string]$Php = '', [switch]$Pause)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Say([string]$text, [string]$color = 'Gray') { Write-Host "  $text" -ForegroundColor $color }

# ------------------------------------------------------------ elevation ----
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $admin) {
    Say 'Asking Windows for administrator rights - click Yes.' 'Yellow'
    # Windows opens the elevated run in a window of its own, which would close
    # the moment it finished; -Pause keeps it open long enough to read.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pause')
    if ($Php -ne '') { $arguments += @('-Php', "`"$Php`"") }
    try {
        $p = Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $p.ExitCode
    } catch {
        Say '[X] Administrator rights were refused, so nothing was changed.' 'Red'
        exit 1
    }
}

Write-Host ''
Write-Host '  ================================================'
Write-Host '   Open L-SIAMS to the local network'
Write-Host '  ================================================'
Write-Host ''

$failed = $false

# ------------------------------------------------------------ the ports ----
$webPort = 8080
$wsPort  = 8443
$envFile = Join-Path $root '.env'
$envText = if (Test-Path $envFile) { Get-Content $envFile -Raw } else { '' }

if ($envText -match '(?m)^\s*REALTIME_WS_PORT\s*=\s*(\d+)') { $wsPort = [int]$Matches[1] }

# --------------------------------------------- 1. network profile Private --
try {
    $profiles = Get-NetConnectionProfile | Where-Object {
        $_.IPv4Connectivity -in @('LocalNetwork', 'Internet')
    }

    if (-not $profiles) {
        Say '[X] This PC is not connected to any network. Connect it to the' 'Red'
        Say '    school Wi-Fi or plug in the cable, then run this again.' 'Red'
        $failed = $true
    }

    foreach ($p in $profiles) {
        if ($p.NetworkCategory -eq 'Public') {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
            Say "[ok] '$($p.Name)' ($($p.InterfaceAlias)) changed from Public to Private" 'Green'
        } else {
            Say "[ok] '$($p.Name)' ($($p.InterfaceAlias)) is $($p.NetworkCategory)" 'Green'
        }
    }
} catch {
    Say "[X] Could not set the network to Private: $($_.Exception.Message)" 'Red'
    Say '    Do it by hand: Settings > Network & internet > Wi-Fi (or Ethernet)' 'Red'
    Say '    > your network > Network profile type > Private.' 'Red'
    $failed = $true
}

# ------------------------------------------- 2. block rules for php.exe ----
if ($Php -ne '' -and (Test-Path $Php)) {
    $phpFull = (Resolve-Path $Php).Path
    try {
        $blocks = Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Program -and ([Environment]::ExpandEnvironmentVariables($_.Program) -ieq $phpFull) } |
            Get-NetFirewallRule |
            Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' }

        foreach ($rule in $blocks) {
            Remove-NetFirewallRule -Name $rule.Name
            Say "[ok] Removed a rule blocking PHP: '$($rule.DisplayName)'" 'Green'
        }

        if (-not $blocks) { Say '[ok] No rule is blocking PHP' 'Green' }
    } catch {
        Say "[!] Could not check for rules blocking PHP: $($_.Exception.Message)" 'Yellow'
    }
}

# -------------------------------------------------- 3. open the ports ----
foreach ($rule in @(
    @{ Name = 'L-SIAMS web';      Port = $webPort },
    @{ Name = 'L-SIAMS realtime'; Port = $wsPort }
)) {
    try {
        # Replaced rather than added again, so running this twice leaves one rule.
        Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $rule.Port -Profile Private,Domain | Out-Null
        Say "[ok] Port $($rule.Port) open on Private networks ($($rule.Name))" 'Green'
    } catch {
        Say "[X] Could not open port $($rule.Port): $($_.Exception.Message)" 'Red'
        $failed = $true
    }
}

# ---------------------------------------------- 4. the address to type ----
# The adapter with a default gateway is the one on the school network. The
# virtual adapters VirtualBox, VMware, Hyper-V and WSL add have none.
$addresses = @(Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object { $_.IPv4Address.IPAddress } |
    Where-Object { $_ -and $_ -notlike '169.254.*' })

# ------------------------------------------ 5. .env lets that range in ----
function Test-InCidr([string]$ip, [string]$cidr) {
    $parts = $cidr.Trim().Split('/')
    if ($parts.Count -ne 2) { return $false }
    try {
        $toInt = { param($a) $b = ([Net.IPAddress]::Parse($a)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
        $bits  = [int]$parts[1]
        # Arithmetic, not 0xFFFFFFFF: Windows PowerShell reads that literal as -1.
        $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits))
        return ((& $toInt $ip) -band $mask) -eq ((& $toInt $parts[0]) -band $mask)
    } catch { return $false }
}

$allow = $null
if ($envText -match '(?m)^\s*TRUSTED_WEB_CIDRS\s*=\s*(.*)$') {
    $allow = @($Matches[1].Trim().Trim('"').Split(',') | Where-Object { $_.Trim() -ne '' })
}

foreach ($ip in $addresses) {
    if ($allow -and -not ($allow | Where-Object { Test-InCidr $ip $_ })) {
        Write-Host ''
        Say "[X] .env does not let addresses like $ip in." 'Red'
        Say "    Its TRUSTED_WEB_CIDRS line is: $($allow -join ',')" 'Red'
        Say '    Change that line in .env to:' 'Red'
        Say '      TRUSTED_WEB_CIDRS=127.0.0.0/8,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12' 'Red'
        Say '    and do the same for TRUSTED_DEVICE_CIDRS, then restart start.bat.' 'Red'
        $failed = $true
    }
}

Write-Host ''
Write-Host '  ================================================'
if ($addresses.Count -gt 0) {
    Write-Host '   On the other devices, open:'
    Write-Host ''
    foreach ($ip in $addresses) { Write-Host "     http://${ip}:$webPort" -ForegroundColor Cyan }
    Write-Host ''
    Write-Host '   They must be on the same Wi-Fi as this PC'
    Write-Host '   (not Guest Wi-Fi, not mobile data), and'
    Write-Host '   start.bat must be running on this PC.'
} else {
    Write-Host '   This PC has no network address with a router,' -ForegroundColor Yellow
    Write-Host '   so other devices cannot reach it yet. Connect' -ForegroundColor Yellow
    Write-Host '   it to the school Wi-Fi or plug in the cable.' -ForegroundColor Yellow
    $failed = $true
}
Write-Host '  ================================================'
Write-Host ''

if ($Pause) { Read-Host '  Press Enter to close this window' | Out-Null }

if ($failed) { exit 1 } else { exit 0 }
