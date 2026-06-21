# debrave

Strips Brave browser's crypto and monetization features from local browser profiles.

Brave is a great Chromium-based browser with strong privacy defaults. But it ships
with a pile of crypto and monetization features that most people don't want: a
built-in crypto wallet, BAT rewards, "Brave News" sponsored content, NFT/IPFS
integration, affiliate referral tracking, paid VPN/Talk/Leo upsells, and various
telemetry. This script disables all of that in one shot.

## What it disables

| Feature | What it is |
|---|---|
| Brave Rewards (BAT) | Token tipping/earning system |
| Brave Ads | Notification + search result ads |
| Brave Wallet | Built-in ETH/SOL/ADA crypto wallet + NFTs |
| IPFS | Decentralized storage + NFT gateway |
| Brave News | Sponsored content feed on the new tab page |
| Sponsored NTP wallpapers | Background images that earn Brave money |
| NTP widgets | Binance, Gemini, Rewards, VPN, Brave Talk cards |
| Brave VPN | Paid VPN upsell |
| Brave Talk | Paid video call upsell |
| Leo AI | AI chat with premium upsell + telemetry |
| Web Discovery Project | Opt-in search data collection |
| Stats ping | Usage telemetry |
| Referral/affiliate tracking | Download ID + promo code |
| P3A telemetry | Privacy-preserving analytics (still analytics) |
| Sidebar icons | Leo, Wallet, Brave Talk hidden from sidebar |

All preference keys and policy names were extracted from the Brave binary itself
and verified against the actual profile data on macOS. None of the target prefs
are HMAC-protected by Chromium's Secure Preferences system, so edits are safe and
persistent.

## Requirements

- macOS: Python 3.10+ for `debrave.py`
- Windows: PowerShell 5.1+ for `debrave.ps1`
- Brave Browser installed

## Usage

### macOS

```sh
# Preview what would change (safe, writes nothing, Brave can be running)
python3 debrave.py --dry-run

# Show current monetization feature state
python3 debrave.py --list

# Quit Brave and apply all disables (backs up to debrave-backups/)
python3 debrave.py --quit

# Also delete wallet/ads/rewards databases + wallet secrets (destructive)
python3 debrave.py --quit --purge

# Also generate a managed-preferences plist that hard-enforces the disables
# across browser updates (cannot be toggled back in the UI)
python3 debrave.py --quit --write-policy
```

### Windows

Double-click `debrave-windows.bat` to run the normal Windows cleanup without
opening a terminal manually. It runs `debrave.ps1 -Quit` and pauses at the end so
you can read the result.

```powershell
# Preview what would change (safe, writes nothing, Brave can be running)
powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -DryRun

# Show current monetization feature state
powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -List

# Ask Brave to close and apply all disables (backs up to debrave-backups/)
powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit

# Also delete wallet/ads/rewards databases + wallet secrets (destructive)
powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit -Purge

# Also generate a Windows registry policy file that hard-enforces the disables
# across browser updates (cannot be toggled back in the UI once imported)
powershell -ExecutionPolicy Bypass -File .\debrave.ps1 -Quit -WritePolicy
```

The PowerShell script also accepts the original long option names, such as
`--dry-run`, `--quit`, `--purge`, `--write-policy`, `--list`, and `--user-data`.

### Policy plist (optional, hard enforcement)

`--write-policy` generates `com.brave.Browser.plist` and prints the `sudo install`
command to deploy it to `/Library/Managed Preferences/`. Once installed, Brave
treats these as enterprise policies and locks the features off at the engine level.
Remove later with:

```sh
sudo rm /Library/Managed Preferences/com.brave.Browser.plist
```

### Windows policy registry file (optional, hard enforcement)

`-WritePolicy` generates `brave-policy.reg` in `debrave-backups/` and prints the
`reg import` command. Import it from an elevated PowerShell or Command Prompt to
install the policy values under:

```text
HKLM\SOFTWARE\Policies\BraveSoftware\Brave
```

## Safety

- Always backs up `Preferences` and `Local State` before writing (unless `--no-backup`)
- Refuses to run while Brave is open (or use `--quit` to close it automatically)
- `--dry-run` writes nothing and is always safe to try
- `--purge` is destructive (deletes wallet databases and secrets) -- use with care

## License

[MIT](LICENSE)
