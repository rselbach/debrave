#requires -version 5.1
<#
debrave.ps1 - Windows-native version of debrave.py.

Strips Brave's crypto and monetization features from local Windows profiles.
Run with -DryRun first to preview the changes.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
Usage:
  powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -List
  powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit
  powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit -Purge
  powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit -WritePolicy

Options:
  -DryRun, --dry-run         Preview only; write nothing.
  -Quit, --quit              Ask Brave windows to close before applying.
  -NoBackup, --no-backup     Skip backing up preference files.
  -Purge, --purge            Also remove wallet/ad/rewards databases and secrets.
  -WritePolicy, --write-policy
                              Emit a Windows registry policy file for hard enforcement.
  -List, --list              Show current monetization state and exit.
  -UserData PATH, --user-data PATH
                              Override Brave user-data directory.
  -Help, --help              Show this help.
"@ | Write-Host
}

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Parse-Arguments {
    param([string[]]$ArgList)

    $options = [pscustomobject]@{
        DryRun      = $false
        Quit        = $false
        NoBackup    = $false
        Purge       = $false
        WritePolicy = $false
        List        = $false
        UserData    = $null
        Help        = $false
    }

    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $arg = $ArgList[$i]
        switch -Regex ($arg) {
            '^(--dry-run|-DryRun)$' { $options.DryRun = $true; continue }
            '^(--quit|-Quit)$' { $options.Quit = $true; continue }
            '^(--no-backup|-NoBackup)$' { $options.NoBackup = $true; continue }
            '^(--purge|-Purge)$' { $options.Purge = $true; continue }
            '^(--write-policy|-WritePolicy)$' { $options.WritePolicy = $true; continue }
            '^(--list|-List)$' { $options.List = $true; continue }
            '^(--help|-Help|-h|/\?)$' { $options.Help = $true; continue }
            '^--user-data=(.+)$' {
                $options.UserData = $Matches[1]
                continue
            }
            '^(--user-data|-UserData)$' {
                if ($i + 1 -ge $ArgList.Count) {
                    throw "Missing value for $arg"
                }
                $i += 1
                $options.UserData = $ArgList[$i]
                continue
            }
            default {
                throw "Unknown argument: $arg"
            }
        }
    }

    return $options
}

function Get-BraveUserDataDir {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $HOME "AppData\Local"
    }
    return (Join-Path $base "BraveSoftware\Brave-Browser\User Data")
}

function Get-BraveProfiles {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Root -Directory |
            Where-Object {
                ($_.Name -eq "Default" -or $_.Name -like "Profile *") -and
                (Test-Path -LiteralPath (Join-Path $_.FullName "Preferences") -PathType Leaf)
            } |
            Sort-Object Name
    )
}

function Load-JsonFile {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{}
    }
    return ($text | ConvertFrom-Json)
}

function Save-JsonFile {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $tmp = "$Path.debrave-tmp"
    $json = ConvertTo-Json -InputObject $Data -Depth 100 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $json + "`n", $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-JsonObject {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return $true
    }
    return ($Value -is [pscustomobject])
}

function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [string]$Name,
        [ref]$Found
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $Found.Value = $true
            Write-Output -NoEnumerate $Object[$Name]
            return
        }
        $Found.Value = $false
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        $Found.Value = $true
        Write-Output -NoEnumerate $prop.Value
        return
    }

    $Found.Value = $false
    return $null
}

function TryGet-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [string]$Name,
        [ref]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $Value.Value = $Object[$Name]
            return $true
        }
        $Value.Value = $null
        return $false
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        $Value.Value = $prop.Value
        return $true
    }

    $Value.Value = $null
    return $false
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [string]$Name,
        [AllowNull()]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $prop.Value = $Value
    }
}

function Remove-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $Object.Remove($Name)
            return $true
        }
        return $false
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $false
    }

    $Object.PSObject.Properties.Remove($Name)
    return $true
}

function ConvertTo-ComparableJson {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return "<null>"
    }

    try {
        return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress)
    }
    catch {
        return [string]$Value
    }
}

function Test-JsonValueEqual {
    param(
        [AllowNull()]$A,
        [AllowNull()]$B
    )

    return ((ConvertTo-ComparableJson -Value $A) -eq (ConvertTo-ComparableJson -Value $B))
}

function Split-RulePath {
    param([string]$Path)
    return @($Path -split '\.')
}

function Get-NestedValue {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string[]]$Parts
    )

    $cur = $Data
    foreach ($part in $Parts) {
        if (-not (Test-JsonObject -Value $cur)) {
            return $null
        }
        $value = $null
        $found = TryGet-JsonProperty -Object $cur -Name $part -Value ([ref]$value)
        if (-not $found) {
            return $null
        }
        $cur = $value
    }

    Write-Output -NoEnumerate $cur
}

function Get-NestedParent {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string[]]$Parts
    )

    $cur = $Data
    if ($Parts.Count -le 1) {
        Write-Output -NoEnumerate $cur
        return
    }

    for ($i = 0; $i -lt ($Parts.Count - 1); $i++) {
        $key = $Parts[$i]
        $child = $null
        $found = TryGet-JsonProperty -Object $cur -Name $key -Value ([ref]$child)

        if (-not $found -or -not (Test-JsonObject -Value $child)) {
            $child = [pscustomobject]@{}
            Set-JsonProperty -Object $cur -Name $key -Value $child
        }

        $cur = $child
    }

    Write-Output -NoEnumerate $cur
}

function Set-NestedValue {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string[]]$Parts,
        [AllowNull()]$Value
    )

    $parent = Get-NestedParent -Data $Data -Parts $Parts
    $leaf = $Parts[$Parts.Count - 1]
    $current = $null
    $found = TryGet-JsonProperty -Object $parent -Name $leaf -Value ([ref]$current)
    if ($found -and (Test-JsonValueEqual -A $current -B $Value)) {
        return $false
    }

    Set-JsonProperty -Object $parent -Name $leaf -Value $Value
    return $true
}

function Remove-NestedValue {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string[]]$Parts
    )

    $cur = $Data
    if ($Parts.Count -le 1) {
        return (Remove-JsonProperty -Object $cur -Name $Parts[0])
    }

    for ($i = 0; $i -lt ($Parts.Count - 1); $i++) {
        if (-not (Test-JsonObject -Value $cur)) {
            return $false
        }

        $next = $null
        $found = TryGet-JsonProperty -Object $cur -Name $Parts[$i] -Value ([ref]$next)
        if (-not $found) {
            return $false
        }
        $cur = $next
    }

    if (-not (Test-JsonObject -Value $cur)) {
        return $false
    }

    return (Remove-JsonProperty -Object $cur -Name $Parts[$Parts.Count - 1])
}

function Add-NestedListValue {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string[]]$Parts,
        [AllowNull()]$Value
    )

    $parent = Get-NestedParent -Data $Data -Parts $Parts
    $leaf = $Parts[$Parts.Count - 1]
    $current = $null
    $found = TryGet-JsonProperty -Object $parent -Name $leaf -Value ([ref]$current)

    if ($found -and $current -is [array]) {
        $list = @($current)
    }
    else {
        $list = @()
    }

    foreach ($item in $list) {
        if (Test-JsonValueEqual -A $item -B $Value) {
            return $false
        }
    }

    $list = @($list) + $Value
    Set-JsonProperty -Object $parent -Name $leaf -Value $list
    return $true
}

function Invoke-Rules {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)]$Rules
    )

    $changed = New-Object System.Collections.Generic.List[object]

    foreach ($rule in @($Rules)) {
        $parts = Split-RulePath -Path $rule.path
        $didChange = $false

        switch ($rule.op) {
            "set" { $didChange = Set-NestedValue -Data $Data -Parts $parts -Value $rule.value }
            "del" { $didChange = Remove-NestedValue -Data $Data -Parts $parts }
            "list_add" { $didChange = Add-NestedListValue -Data $Data -Parts $parts -Value $rule.value }
            default { throw "Unknown rule operation: $($rule.op)" }
        }

        if ($didChange) {
            $changed.Add([pscustomobject]@{
                Path  = $rule.path
                Op    = $rule.op
                Group = $rule.group
            }) | Out-Null
        }
    }

    return @($changed.ToArray())
}

function Backup-File {
    param(
        [string]$Source,
        [string]$BackupDir
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        return $null
    }

    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $name = [System.IO.Path]::GetFileName($Source)
    $destination = Join-Path $BackupDir "$name.$stamp"
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    return $destination
}

function Format-JsonValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return '$null'
    }
    if ($Value -is [string]) {
        if ($Value.Length -eq 0) {
            return '""'
        }
        return "'$Value'"
    }
    return (ConvertTo-ComparableJson -Value $Value)
}

function Print-Changes {
    param(
        [string]$Title,
        [AllowNull()]$Changed
    )

    $items = @($Changed)
    if ($items.Count -eq 0) {
        Write-Host "  ${Title}: no changes needed (already clean)"
        return
    }

    Write-Host "  ${Title}: $($items.Count) change(s)"
    $groups = $items | Group-Object Group | Sort-Object Name
    foreach ($group in $groups) {
        Write-Host "    [$($group.Name)]"
        foreach ($item in $group.Group) {
            Write-Host "      - $($item.Path)"
        }
    }
}

function Get-BraveProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -ieq "brave" -or $_.ProcessName -ieq "bravebrowser" }
    )
}

function Test-BraveRunning {
    return (@(Get-BraveProcesses).Count -gt 0)
}

function Stop-BraveGracefully {
    param([int]$TimeoutSeconds = 20)

    foreach ($proc in @(Get-BraveProcesses)) {
        try {
            if ($proc.MainWindowHandle -ne 0) {
                [void]$proc.CloseMainWindow()
            }
        }
        catch {
            # Ignore races where a Brave child process exits while we are asking windows to close.
        }
    }

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (-not (Test-BraveRunning)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return (-not (Test-BraveRunning))
}

function Show-Current {
    param(
        [string]$Root,
        [AllowNull()]$Profiles
    )

    Write-Host "Brave user data: $Root"
    $profileList = @($Profiles)
    if ($profileList.Count -eq 0) {
        Write-Host "  No profiles found."
        return
    }

    $interesting = @(
        "brave.rewards.enabled",
        "brave.brave_ads.enabled",
        "brave.wallet.opted_in",
        "brave.ipfs.enabled",
        "brave.today.opted_in",
        "brave.new_tab_page.show_branded_background_image",
        "brave.new_tab_page.show_binance",
        "brave.new_tab_page.show_gemini",
        "brave.brave_vpn.subscriber_credential",
        "brave.ai_chat.show_toolbar_button"
    ) | Sort-Object

    $localStatePath = Join-Path $Root "Local State"
    $localState = $null
    if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
        $localState = Load-JsonFile -Path $localStatePath
    }

    foreach ($profile in $profileList) {
        Write-Host ""
        Write-Host "  Profile: $($profile.Name)"
        try {
            $data = Load-JsonFile -Path (Join-Path $profile.FullName "Preferences")
        }
        catch {
            Write-Host "    (cannot read Preferences: $($_.Exception.Message))"
            continue
        }

        foreach ($path in $interesting) {
            $parts = Split-RulePath -Path $path
            $value = Get-NestedValue -Data $data -Parts $parts
            if ($null -eq $value) {
                $mark = "unset"
            }
            elseif ($value) {
                $mark = "ON"
            }
            else {
                $mark = "off"
            }
            Write-Host ("    {0,-5} {1} = {2}" -f $mark, $path, (Format-JsonValue -Value $value))
        }

        if ($null -ne $localState) {
            $refValue = Get-NestedValue -Data $localState -Parts (Split-RulePath -Path "brave.referral.promo_code")
            Write-Host ("    referral.promo_code = {0}" -f (Format-JsonValue -Value $refValue))
        }
    }
}

function Write-WindowsPolicyFile {
    param(
        [string]$OutDir,
        [bool]$DryRun
    )

    $policyPath = Join-Path $OutDir "brave-policy.reg"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Windows Registry Editor Version 5.00") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\BraveSoftware\Brave]") | Out-Null

    foreach ($policy in $WindowsPolicies) {
        $dword = if ($policy.value) { "00000001" } else { "00000000" }
        $lines.Add(('"{0}"=dword:{1}' -f $policy.name, $dword)) | Out-Null
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "  Policy registry file: $policyPath"
        Write-Host "  (dry-run: policy file not written)"
        return
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($policyPath, (($lines.ToArray() -join "`r`n") + "`r`n"), $utf8NoBom)

    Write-Host ""
    Write-Host "  Policy registry file: $policyPath"
    Write-Host "  Install from an elevated PowerShell or Command Prompt:"
    Write-Host "    reg import `"$policyPath`""
    Write-Host "  Remove later:"
    Write-Host "    reg delete HKLM\SOFTWARE\Policies\BraveSoftware\Brave /f"
}

function ConvertFrom-JsonList {
    param([string]$Json)

    $items = ConvertFrom-Json -InputObject $Json
    foreach ($item in $items) {
        Write-Output -NoEnumerate $item
    }
}

$PrefRulesJson = @'
[
  {"path":"brave.rewards.enabled","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.ac.enabled","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.ac.allow_video_contributions","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.ac.allow_non_verified","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.show_brave_rewards_button_in_location_bar","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.inline_tip_buttons_enabled","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.inline_tip.github","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.inline_tip.reddit","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.inline_tip.twitter","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.user_has_claimed_grant","op":"set","value":false,"group":"Rewards"},
  {"path":"brave.rewards.promotion_last_fetch_stamp","op":"set","value":0,"group":"Rewards"},
  {"path":"brave.rewards.wallet.payment_id","op":"del","value":null,"group":"Rewards"},
  {"path":"brave.rewards.wallet.seed","op":"del","value":null,"group":"Rewards"},
  {"path":"brave.rewards.external_wallet_type","op":"del","value":null,"group":"Rewards"},
  {"path":"brave.rewards.external_wallets","op":"set","value":{},"group":"Rewards"},
  {"path":"brave.rewards.wallets","op":"set","value":{},"group":"Rewards"},
  {"path":"brave.rewards.parameters","op":"del","value":null,"group":"Rewards"},
  {"path":"brave.rewards.notifications","op":"del","value":null,"group":"Rewards"},
  {"path":"brave.brave_ads.enabled","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.ever_enabled_any_profile","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.were_disabled","op":"set","value":true,"group":"Ads"},
  {"path":"brave.brave_ads.opted_in_to_search_result_ads","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.should_show_my_first_ad_notification","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.should_show_search_result_ad_clicked_infobar","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.ads_per_hour","op":"set","value":"0","group":"Ads"},
  {"path":"brave.brave_ads.issuers","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.catalog_id","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.catalog_version","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.catalog_last_updated","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.catalog_ping","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.ohttp.key_config","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.reactions","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.notification_ads","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.serve_ad_at","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_ads.has_p3a_state","op":"del","value":null,"group":"Ads"},
  {"path":"brave.wallet.opted_in","op":"set","value":false,"group":"Wallet"},
  {"path":"brave.wallet.show_wallet_icon_on_toolbar","op":"set","value":false,"group":"Wallet"},
  {"path":"brave.wallet.should_show_wallet_suggestion_badge","op":"set","value":false,"group":"Wallet"},
  {"path":"brave.wallet.nft_discovery_enabled","op":"set","value":false,"group":"Wallet"},
  {"path":"brave.wallet.auto_pin_enabled","op":"set","value":false,"group":"Wallet"},
  {"path":"brave.wallet.default_base_cryptocurrency","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_networks","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_networks_origin","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_ada_dapp_account","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_eth_dapp_account","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_sol_dapp_account","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.selected_wallet_account","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.user_pin_data","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.eth_allowances_cache","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.transactions","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.wallet.wallet_user_assets_list","op":"del","value":null,"group":"Wallet"},
  {"path":"brave.ipfs.enabled","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.show_ipfs_promo_infobar","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.always_start_mode","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.auto_redirect_gateway","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.auto_redirect_dnslink","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.auto_fallback_to_gateway","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.auto_redirect_to_configured_gateway","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.resolve_method","op":"del","value":null,"group":"IPFS"},
  {"path":"brave.ipfs.local_pinned_cids","op":"set","value":[],"group":"IPFS"},
  {"path":"brave.ipfs.local_node_used","op":"set","value":false,"group":"IPFS"},
  {"path":"brave.ipfs.public_nft_gateway_address","op":"set","value":"","group":"IPFS"},
  {"path":"brave.today.opted_in","op":"set","value":false,"group":"Brave News"},
  {"path":"brave.today.intro_dismissed","op":"set","value":true,"group":"Brave News"},
  {"path":"brave.today.should_show_toolbar_button","op":"set","value":false,"group":"Brave News"},
  {"path":"brave.today.sources","op":"set","value":[],"group":"Brave News"},
  {"path":"brave.today.userfeeds","op":"set","value":[],"group":"Brave News"},
  {"path":"brave.new_tab_page.show_brave_news","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_branded_background_image","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_rewards","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_brave_vpn","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_together","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_binance","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.show_gemini","op":"set","value":false,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.cached_referral_code","op":"del","value":null,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.cached_super_referral_component_data","op":"del","value":null,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.cached_super_referral_component_info","op":"del","value":null,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.new_tab_takeover_infobar_remaining_display_count","op":"set","value":0,"group":"NTP widgets"},
  {"path":"brave.new_tab_page.new_tab_takeover_infobar_show_count","op":"set","value":0,"group":"NTP widgets"},
  {"path":"brave.brave_vpn.show_button","op":"set","value":false,"group":"VPN"},
  {"path":"brave.brave_vpn.disabled_by_policy","op":"set","value":true,"group":"VPN"},
  {"path":"brave.brave_vpn.subscriber_credential","op":"del","value":null,"group":"VPN"},
  {"path":"brave.brave_vpn.wireguard.profile_credentials","op":"del","value":null,"group":"VPN"},
  {"path":"brave.brave_vpn.dns_config","op":"del","value":null,"group":"VPN"},
  {"path":"brave.brave_vpn.selected_region_name","op":"del","value":null,"group":"VPN"},
  {"path":"brave.brave_vpn.region_list","op":"del","value":null,"group":"VPN"},
  {"path":"brave.ai_chat.show_toolbar_button","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.context_menu_enabled","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.autocomplete_provider_enabled","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.auto_generate_questions","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.storage_enabled","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.user_memory_enabled","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.user_memories","op":"set","value":[],"group":"Leo AI"},
  {"path":"brave.ai_chat.premium_credential_cache","op":"del","value":null,"group":"Leo AI"},
  {"path":"brave.ai_chat.user_dismissed_premium_prompt","op":"set","value":true,"group":"Leo AI"},
  {"path":"brave.sidebar.hidden_built_in_items","op":"list_add","value":7,"group":"Sidebar"},
  {"path":"brave.sidebar.hidden_built_in_items","op":"list_add","value":2,"group":"Sidebar"},
  {"path":"brave.sidebar.hidden_built_in_items","op":"list_add","value":1,"group":"Sidebar"},
  {"path":"profile.content_settings.exceptions.brave_ethereum","op":"set","value":{},"group":"Site access"},
  {"path":"profile.content_settings.exceptions.brave_solana","op":"set","value":{},"group":"Site access"},
  {"path":"profile.content_settings.exceptions.brave_cardano","op":"set","value":{},"group":"Site access"},
  {"path":"profile.content_settings.exceptions.brave_open_ai_chat","op":"set","value":{},"group":"Site access"}
]
'@

$PurgePrefDeletionsJson = @'
[
  {"path":"brave.wallet.encrypted_mnemonic","group":"Wallet"},
  {"path":"brave.wallet.encrypted_seed","group":"Wallet"},
  {"path":"brave.wallet.encryptor_salt","group":"Wallet"},
  {"path":"brave.wallet.keyrings","group":"Wallet"},
  {"path":"brave.wallet.legacy_eth_seed_format","group":"Wallet"}
]
'@

$LocalStateRulesJson = @'
[
  {"path":"brave.referral.download_id","op":"del","value":null,"group":"Referral"},
  {"path":"brave.referral.promo_code","op":"del","value":null,"group":"Referral"},
  {"path":"brave.referral.initialization","op":"set","value":false,"group":"Referral"},
  {"path":"brave.referral.timestamp","op":"del","value":null,"group":"Referral"},
  {"path":"brave.referral.referral_attempt_count","op":"set","value":0,"group":"Referral"},
  {"path":"brave.referral.referral_attempt_timestamp","op":"set","value":0,"group":"Referral"},
  {"path":"brave.referral.checked_for_promo_code_file","op":"set","value":true,"group":"Referral"},
  {"path":"brave.brave_ads.enabled_last_profile","op":"set","value":false,"group":"Ads"},
  {"path":"brave.brave_ads.first_run_at","op":"del","value":null,"group":"Ads"},
  {"path":"brave.brave_search_conversion","op":"del","value":null,"group":"Telemetry"},
  {"path":"brave.ai_chat.p3a_last_premium_status","op":"set","value":false,"group":"Leo AI"},
  {"path":"brave.ai_chat.p3a_last_premium_check","op":"del","value":null,"group":"Leo AI"},
  {"path":"brave.p3a.notice_acknowledged","op":"set","value":true,"group":"Telemetry"},
  {"path":"p3a","op":"del","value":null,"group":"Telemetry"},
  {"path":"brave.serp_metrics","op":"del","value":null,"group":"Telemetry"},
  {"path":"brave.misc_metrics.brave_search_query_counts","op":"del","value":null,"group":"Telemetry"}
]
'@

$WindowsPoliciesJson = @'
[
  {"name":"BraveRewardsDisabled","value":true},
  {"name":"BraveWalletDisabled","value":true},
  {"name":"BraveVPNDisabled","value":true},
  {"name":"BraveTalkDisabled","value":true},
  {"name":"BraveNewsDisabled","value":true},
  {"name":"BraveAIChatEnabled","value":false},
  {"name":"BraveWebDiscoveryEnabled","value":false},
  {"name":"BraveStatsPingEnabled","value":false},
  {"name":"IPFSEnabled","value":false}
]
'@

$PrefRules = @(ConvertFrom-JsonList -Json $PrefRulesJson)
$PurgePrefDeletions = @(ConvertFrom-JsonList -Json $PurgePrefDeletionsJson)
$LocalStateRules = @(ConvertFrom-JsonList -Json $LocalStateRulesJson)
$WindowsPolicies = @(ConvertFrom-JsonList -Json $WindowsPoliciesJson)
$PurgeDirs = @("ads_service", "segmentation_platform", "BraveWallet", "BudgetDatabase")

function Main {
    param([string[]]$ScriptArgs)

    try {
        $options = Parse-Arguments -ArgList $ScriptArgs
    }
    catch {
        Write-Stderr $_.Exception.Message
        Show-Usage
        return 2
    }

    if ($options.Help) {
        Show-Usage
        return 0
    }

    if ($options.UserData) {
        $root = [System.IO.Path]::GetFullPath($options.UserData)
    }
    else {
        $root = Get-BraveUserDataDir
    }

    $profiles = @(Get-BraveProfiles -Root $root)

    if ($options.List) {
        Show-Current -Root $root -Profiles $profiles
        return 0
    }

    if ($profiles.Count -eq 0) {
        Write-Stderr "No Brave profiles found under: $root"
        Write-Stderr "Use -UserData to point at the right directory."
        return 2
    }

    if (-not $options.DryRun -and (Test-BraveRunning)) {
        if ($options.Quit) {
            Write-Host "Brave is running - asking it to close..."
            if (-not (Stop-BraveGracefully)) {
                Write-Stderr "Brave did not quit in time. Close it manually and rerun."
                return 1
            }
        }
        else {
            Write-Stderr "Brave is running. Close it first (or pass -Quit); edits would be overwritten on exit."
            return 1
        }
    }

    $backupDir = Join-Path $root "debrave-backups"
    $totalChanges = 0
    $purgeRules = @()
    if ($options.Purge) {
        $purgeRules = @(
            foreach ($entry in $PurgePrefDeletions) {
                [pscustomobject]@{
                    path  = $entry.path
                    op    = "del"
                    value = $null
                    group = $entry.group
                }
            }
        )
    }

    foreach ($profile in $profiles) {
        $prefPath = Join-Path $profile.FullName "Preferences"
        $data = Load-JsonFile -Path $prefPath
        $rules = @($PrefRules) + @($purgeRules)
        $changed = @(Invoke-Rules -Data $data -Rules $rules)
        Print-Changes -Title "[$($profile.Name)] Preferences" -Changed $changed
        $totalChanges += $changed.Count

        if (-not $options.DryRun -and $changed.Count -gt 0) {
            if (-not $options.NoBackup) {
                $backup = Backup-File -Source $prefPath -BackupDir $backupDir
                if ($backup) {
                    Write-Host "    backup: $backup"
                }
            }
            Save-JsonFile -Path $prefPath -Data $data
        }

        if (-not $options.DryRun -and $options.Purge) {
            foreach ($dirName in $PurgeDirs) {
                $dirPath = Join-Path $profile.FullName $dirName
                if (Test-Path -LiteralPath $dirPath -PathType Container) {
                    if (-not $options.NoBackup) {
                        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                        $destination = Join-Path $backupDir "$($profile.Name)-$dirName.$stamp"
                        Move-Item -LiteralPath $dirPath -Destination $destination
                        Write-Host "    purged+backed-up dir: $dirName"
                    }
                    else {
                        Remove-Item -LiteralPath $dirPath -Recurse -Force
                        Write-Host "    purged dir: $dirName"
                    }
                }
            }
        }
    }

    $localStatePath = Join-Path $root "Local State"
    if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
        $localState = Load-JsonFile -Path $localStatePath
        $changed = @(Invoke-Rules -Data $localState -Rules $LocalStateRules)
        Print-Changes -Title "[Global] Local State" -Changed $changed
        $totalChanges += $changed.Count

        if (-not $options.DryRun -and $changed.Count -gt 0) {
            if (-not $options.NoBackup) {
                $backup = Backup-File -Source $localStatePath -BackupDir $backupDir
                if ($backup) {
                    Write-Host "    backup: $backup"
                }
            }
            Save-JsonFile -Path $localStatePath -Data $localState
        }
    }

    if ($options.WritePolicy) {
        if ($options.DryRun) {
            $policyDir = Get-Location
        }
        else {
            $policyDir = $backupDir
        }
        Write-WindowsPolicyFile -OutDir ([string]$policyDir) -DryRun $options.DryRun
    }

    $mode = if ($options.DryRun) { "DRY RUN" } else { "DONE" }
    Write-Host ""
    Write-Host "$mode`: $totalChanges preference change(s) across $($profiles.Count) profile(s)."
    if ($options.Purge) {
        Write-Host "  (purge: wallet/ads/rewards DBs + wallet secrets targeted)"
    }
    if ($options.WritePolicy -and -not $options.DryRun) {
        Write-Host "  Policy registry file written - import it to hard-enforce."
    }
    if (-not $options.DryRun -and $totalChanges -gt 0) {
        Write-Host "  Restart Brave to see the effect."
    }

    return 0
}

exit (Main -ScriptArgs $args)
