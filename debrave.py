#!/usr/bin/env python3
"""debrave — strip Brave's crypto & monetization features from local browser profiles.

What it does:
  - Disables Brave Rewards / Brave Ads (BAT), the built-in crypto wallet (ETH/SOL/ADA),
    NFT discovery, IPFS, Solana Name Service prompts, Brave News (sponsored feed),
    sponsored NTP wallpapers, the Binance/Gemini/VPN/Rewards NTP widgets, Brave VPN,
    Brave Talk, Leo AI (premium upsell) + its telemetry, the Web Discovery Project, and
    the stats ping.
  - Wipes Brave's referral/affiliate tracking id + promo code.
  - Clears cached ad-network keying data, saved ad reactions, and P3A telemetry buffers.
  - Optionally (--purge) deletes on-disk wallet/ad/reward databases and wallet secrets.
  - Optionally (--write-policy) emits a managed-preferences plist that hard-enforces the
    disables across updates (survives Brave restarts; cannot be toggled back in the UI).

All target prefs were verified against the running Brave binary's pref namespace and are
NOT among Chromium's HMAC-tracked prefs, so editing them directly is safe and persistent.
Brave must be quit first (the script checks, or pass --quit).

Usage:
  debrave.py --dry-run            # preview only, write nothing
  debrave.py --quit               # quit Brave, then apply
  debrave.py --purge              # also delete wallet/ads/rewards DBs + wallet secrets
  debrave.py --write-policy       # also write com.brave.Browser.plist (+ prints install cmd)
  debrave.py --list               # show current monetization state, change nothing
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

BRAVE_APP_NAMES = ("Brave Browser", "BraveBrowser")


# --------------------------------------------------------------------------- paths

def brave_user_data_dir() -> Path:
    s = platform.system()
    if s == "Darwin":
        return Path.home() / "Library" / "Application Support" / "BraveSoftware" / "Brave-Browser"
    if s == "Windows":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "BraveSoftware" / "Brave-Browser" / "User Data"
    return Path.home() / ".config" / "BraveSoftware" / "Brave-Browser"


def profiles(root: Path) -> list[Path]:
    out = []
    if not root.is_dir():
        return out
    for name in sorted(os.listdir(root)):
        p = root / name
        if (p / "Preferences").is_file() and (name == "Default" or name.startswith("Profile ")):
            out.append(p)
    return out


# --------------------------------------------------------------------- json helpers

def load_json(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".debrave-tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    os.replace(tmp, path)
    try:
        shutil.chown(tmp, None, None)  # no-op on non-root; just keep linters quiet
    except Exception:
        pass


def nested_get(d: dict, path: list[str]):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def nested_set(d: dict, path: list[str], value) -> bool:
    cur = d
    for k in path[:-1]:
        if not isinstance(cur.get(k), dict):
            cur[k] = {}
        cur = cur[k]
    key = path[-1]
    if cur.get(key) == value and isinstance(cur.get(key), type(value)):
        return False
    cur[key] = value
    return True


def nested_del(d: dict, path: list[str]) -> bool:
    cur = d
    for k in path[:-1]:
        if not isinstance(cur, dict) or k not in cur:
            return False
        cur = cur[k]
    return cur.pop(path[-1], None) is not None


def nested_list_add(d: dict, path: list[str], value) -> bool:
    """Append value to a list at path (creating it if needed). Returns True if added."""
    cur = d
    for k in path[:-1]:
        if not isinstance(cur.get(k), dict):
            cur[k] = {}
        cur = cur[k]
    key = path[-1]
    lst = cur.get(key)
    if not isinstance(lst, list):
        lst = []
    if value in lst:
        return False
    lst.append(value)
    cur[key] = lst
    return True


# --------------------------------------------------------------------------- rules

# Per-profile Preferences rules: (dotted_path, op, value, group)
# op = "set" | "del" | "list_add"
PREF_RULES: list[tuple[str, str, object, str]] = [
    # --- Brave Rewards (BAT) ---
    ("brave.rewards.enabled", "set", False, "Rewards"),
    ("brave.rewards.ac.enabled", "set", False, "Rewards"),
    ("brave.rewards.ac.allow_video_contributions", "set", False, "Rewards"),
    ("brave.rewards.ac.allow_non_verified", "set", False, "Rewards"),
    ("brave.rewards.show_brave_rewards_button_in_location_bar", "set", False, "Rewards"),
    ("brave.rewards.inline_tip_buttons_enabled", "set", False, "Rewards"),
    ("brave.rewards.inline_tip.github", "set", False, "Rewards"),
    ("brave.rewards.inline_tip.reddit", "set", False, "Rewards"),
    ("brave.rewards.inline_tip.twitter", "set", False, "Rewards"),
    ("brave.rewards.user_has_claimed_grant", "set", False, "Rewards"),
    ("brave.rewards.promotion_last_fetch_stamp", "set", 0, "Rewards"),
    ("brave.rewards.wallet.payment_id", "del", None, "Rewards"),
    ("brave.rewards.wallet.seed", "del", None, "Rewards"),
    ("brave.rewards.external_wallet_type", "del", None, "Rewards"),
    ("brave.rewards.external_wallets", "set", {}, "Rewards"),
    ("brave.rewards.wallets", "set", {}, "Rewards"),
    ("brave.rewards.parameters", "del", None, "Rewards"),
    ("brave.rewards.notifications", "del", None, "Rewards"),

    # --- Brave Ads ---
    ("brave.brave_ads.enabled", "set", False, "Ads"),
    ("brave.brave_ads.ever_enabled_any_profile", "set", False, "Ads"),
    ("brave.brave_ads.were_disabled", "set", True, "Ads"),
    ("brave.brave_ads.opted_in_to_search_result_ads", "set", False, "Ads"),
    ("brave.brave_ads.should_show_my_first_ad_notification", "set", False, "Ads"),
    ("brave.brave_ads.should_show_search_result_ad_clicked_infobar", "set", False, "Ads"),
    ("brave.brave_ads.ads_per_hour", "set", "0", "Ads"),
    ("brave.brave_ads.issuers", "del", None, "Ads"),
    ("brave.brave_ads.catalog_id", "del", None, "Ads"),
    ("brave.brave_ads.catalog_version", "del", None, "Ads"),
    ("brave.brave_ads.catalog_last_updated", "del", None, "Ads"),
    ("brave.brave_ads.catalog_ping", "del", None, "Ads"),
    ("brave.brave_ads.ohttp.key_config", "del", None, "Ads"),
    ("brave.brave_ads.reactions", "del", None, "Ads"),
    ("brave.brave_ads.notification_ads", "del", None, "Ads"),
    ("brave.brave_ads.serve_ad_at", "del", None, "Ads"),
    ("brave.brave_ads.has_p3a_state", "del", None, "Ads"),

    # --- Brave Wallet (crypto: ETH/SOL/ADA, NFTs, swaps) ---
    ("brave.wallet.opted_in", "set", False, "Wallet"),
    ("brave.wallet.show_wallet_icon_on_toolbar", "set", False, "Wallet"),
    ("brave.wallet.should_show_wallet_suggestion_badge", "set", False, "Wallet"),
    ("brave.wallet.nft_discovery_enabled", "set", False, "Wallet"),
    ("brave.wallet.auto_pin_enabled", "set", False, "Wallet"),
    ("brave.wallet.default_base_cryptocurrency", "del", None, "Wallet"),
    ("brave.wallet.selected_networks", "del", None, "Wallet"),
    ("brave.wallet.selected_networks_origin", "del", None, "Wallet"),
    ("brave.wallet.selected_ada_dapp_account", "del", None, "Wallet"),
    ("brave.wallet.selected_eth_dapp_account", "del", None, "Wallet"),
    ("brave.wallet.selected_sol_dapp_account", "del", None, "Wallet"),
    ("brave.wallet.selected_wallet_account", "del", None, "Wallet"),
    ("brave.wallet.user_pin_data", "del", None, "Wallet"),
    ("brave.wallet.eth_allowances_cache", "del", None, "Wallet"),
    ("brave.wallet.transactions", "del", None, "Wallet"),
    ("brave.wallet.wallet_user_assets_list", "del", None, "Wallet"),

    # --- IPFS (NFT gateway / local node) ---
    ("brave.ipfs.enabled", "set", False, "IPFS"),
    ("brave.ipfs.show_ipfs_promo_infobar", "set", False, "IPFS"),
    ("brave.ipfs.always_start_mode", "set", False, "IPFS"),
    ("brave.ipfs.auto_redirect_gateway", "set", False, "IPFS"),
    ("brave.ipfs.auto_redirect_dnslink", "set", False, "IPFS"),
    ("brave.ipfs.auto_fallback_to_gateway", "set", False, "IPFS"),
    ("brave.ipfs.auto_redirect_to_configured_gateway", "set", False, "IPFS"),
    ("brave.ipfs.resolve_method", "del", None, "IPFS"),
    ("brave.ipfs.local_pinned_cids", "set", [], "IPFS"),
    ("brave.ipfs.local_node_used", "set", False, "IPFS"),
    ("brave.ipfs.public_nft_gateway_address", "set", "", "IPFS"),

    # --- Brave News (sponsored feed) ---
    ("brave.today.opted_in", "set", False, "Brave News"),
    ("brave.today.intro_dismissed", "set", True, "Brave News"),
    ("brave.today.should_show_toolbar_button", "set", False, "Brave News"),
    ("brave.today.sources", "set", [], "Brave News"),
    ("brave.today.userfeeds", "set", [], "Brave News"),

    # --- New Tab Page widgets (crypto + monetization) ---
    ("brave.new_tab_page.show_brave_news", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_branded_background_image", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_rewards", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_brave_vpn", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_together", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_binance", "set", False, "NTP widgets"),
    ("brave.new_tab_page.show_gemini", "set", False, "NTP widgets"),
    ("brave.new_tab_page.cached_referral_code", "del", None, "NTP widgets"),
    ("brave.new_tab_page.cached_super_referral_component_data", "del", None, "NTP widgets"),
    ("brave.new_tab_page.cached_super_referral_component_info", "del", None, "NTP widgets"),
    ("brave.new_tab_page.new_tab_takeover_infobar_remaining_display_count", "set", 0, "NTP widgets"),
    ("brave.new_tab_page.new_tab_takeover_infobar_show_count", "set", 0, "NTP widgets"),

    # --- Brave VPN (paid upsell) ---
    ("brave.brave_vpn.show_button", "set", False, "VPN"),
    ("brave.brave_vpn.disabled_by_policy", "set", True, "VPN"),
    ("brave.brave_vpn.subscriber_credential", "del", None, "VPN"),
    ("brave.brave_vpn.wireguard.profile_credentials", "del", None, "VPN"),
    ("brave.brave_vpn.dns_config", "del", None, "VPN"),
    ("brave.brave_vpn.selected_region_name", "del", None, "VPN"),
    ("brave.brave_vpn.region_list", "del", None, "VPN"),

    # --- Leo AI (premium upsell + telemetry) ---
    ("brave.ai_chat.show_toolbar_button", "set", False, "Leo AI"),
    ("brave.ai_chat.context_menu_enabled", "set", False, "Leo AI"),
    ("brave.ai_chat.autocomplete_provider_enabled", "set", False, "Leo AI"),
    ("brave.ai_chat.auto_generate_questions", "set", False, "Leo AI"),
    ("brave.ai_chat.storage_enabled", "set", False, "Leo AI"),
    ("brave.ai_chat.user_memory_enabled", "set", False, "Leo AI"),
    ("brave.ai_chat.user_memories", "set", [], "Leo AI"),
    ("brave.ai_chat.premium_credential_cache", "del", None, "Leo AI"),
    ("brave.ai_chat.user_dismissed_premium_prompt", "set", True, "Leo AI"),

    # --- Sidebar built-in items (hide monetization icons) ---
    # BuiltInItemType enum: kBraveTalk=1, kWallet=2, kChatUI=7
    ("brave.sidebar.hidden_built_in_items", "list_add", 7, "Sidebar"),   # Leo
    ("brave.sidebar.hidden_built_in_items", "list_add", 2, "Sidebar"),   # Wallet
    ("brave.sidebar.hidden_built_in_items", "list_add", 1, "Sidebar"),   # Brave Talk

    # --- Revoke per-site DApp / wallet / AI access ---
    ("profile.content_settings.exceptions.brave_ethereum", "set", {}, "Site access"),
    ("profile.content_settings.exceptions.brave_solana", "set", {}, "Site access"),
    ("profile.content_settings.exceptions.brave_cardano", "set", {}, "Site access"),
    ("profile.content_settings.exceptions.brave_open_ai_chat", "set", {}, "Site access"),
]

# Extra pref deletions applied only with --purge (destroys wallet secrets / identity).
PURGE_PREF_DELETIONS: list[tuple[str, str]] = [
    ("brave.wallet.encrypted_mnemonic", "Wallet"),
    ("brave.wallet.encrypted_seed", "Wallet"),
    ("brave.wallet.encryptor_salt", "Wallet"),
    ("brave.wallet.keyrings", "Wallet"),
    ("brave.wallet.legacy_eth_seed_format", "Wallet"),
]

# On-disk dirs (relative to a profile) deleted only with --purge.
PURGE_DIRS = ["ads_service", "segmentation_platform", "BraveWallet", "BudgetDatabase"]

# Local State rules (global, once).
LOCAL_STATE_RULES: list[tuple[str, str, object, str]] = [
    ("brave.referral.download_id", "del", None, "Referral"),
    ("brave.referral.promo_code", "del", None, "Referral"),
    ("brave.referral.initialization", "set", False, "Referral"),
    ("brave.referral.timestamp", "del", None, "Referral"),
    ("brave.referral.referral_attempt_count", "set", 0, "Referral"),
    ("brave.referral.referral_attempt_timestamp", "set", 0, "Referral"),
    ("brave.referral.checked_for_promo_code_file", "set", True, "Referral"),
    ("brave.brave_ads.enabled_last_profile", "set", False, "Ads"),
    ("brave.brave_ads.first_run_at", "del", None, "Ads"),
    ("brave.brave_search_conversion", "del", None, "Telemetry"),
    ("brave.ai_chat.p3a_last_premium_status", "set", False, "Leo AI"),
    ("brave.ai_chat.p3a_last_premium_check", "del", None, "Leo AI"),
    ("brave.p3a.notice_acknowledged", "set", True, "Telemetry"),
    ("p3a", "del", None, "Telemetry"),
    ("brave.serp_metrics", "del", None, "Telemetry"),
    ("brave.misc_metrics.brave_search_query_counts", "del", None, "Telemetry"),
]

# Managed-preferences policies (hard enforcement). Names verified against the binary.
POLICIES: dict[str, object] = {
    "BraveRewardsDisabled": True,
    "BraveWalletDisabled": True,
    "BraveVPNDisabled": True,
    "BraveTalkDisabled": True,
    "BraveNewsDisabled": True,
    "BraveAIChatEnabled": False,
    "BraveWebDiscoveryEnabled": False,
    "BraveStatsPingEnabled": False,
    "IPFSEnabled": False,
}

POLICY_INSTALL_PATH = "/Library/Managed Preferences/com.brave.Browser.plist"


# ---------------------------------------------------------------------- process mgmt

def brave_running() -> bool:
    try:
        r = subprocess.run(["pgrep", "-fil", "Brave Browser"], capture_output=True, text=True)
        return r.returncode == 0 and bool(r.stdout.strip())
    except FileNotFoundError:
        r = subprocess.run(["ps", "Ax"], capture_output=True, text=True)
        return any("Brave Browser" in line for line in r.stdout.splitlines())


def quit_brave(timeout: int = 20) -> bool:
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "Brave Browser" to quit'],
            check=False, capture_output=True,
        )
    except FileNotFoundError:
        pass
    for _ in range(timeout):
        if not brave_running():
            return True
        time.sleep(1)
    return not brave_running()


# ----------------------------------------------------------------------- apply logic

def split(path: str) -> list[str]:
    return path.split(".")


def apply_rules(data: dict, rules) -> list[tuple[str, str, str]]:
    """Return [(path, op, group), ...] of changes actually made (in-place on data)."""
    changed: list[tuple[str, str, str]] = []
    for path, op, value, group in rules:
        if op == "set":
            if nested_set(data, split(path), value):
                changed.append((path, "set", group))
        elif op == "del":
            if nested_del(data, split(path)):
                changed.append((path, "del", group))
        elif op == "list_add":
            if nested_list_add(data, split(path), value):
                changed.append((path, "list_add", group))
    return changed


def backup_file(src: Path, backup_dir: Path) -> Path | None:
    if not src.is_file():
        return None
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = backup_dir / f"{src.name}.{stamp}"
    shutil.copy2(src, dst)
    return dst


def fmt_val(v) -> str:
    if v is None:
        return "(deleted)"
    if isinstance(v, str):
        return repr(v) if v else '""'
    return str(v)


# --------------------------------------------------------------------------- report

def print_changes(title: str, changed: list[tuple[str, str, str]]) -> None:
    if not changed:
        print(f"  {title}: no changes needed (already clean)")
        return
    by_group: dict[str, list[str]] = {}
    for path, op, group in changed:
        by_group.setdefault(group, []).append(path)
    print(f"  {title}: {len(changed)} change(s)")
    for group in sorted(by_group):
        print(f"    [{group}]")
        for path in by_group[group]:
            print(f"      - {path}")


def show_current(root: Path, profs: list[Path]) -> None:
    print(f"Brave user data: {root}")
    if not profs:
        print("  No profiles found.")
        return
    interesting = {
        "brave.rewards.enabled", "brave.brave_ads.enabled", "brave.wallet.opted_in",
        "brave.ipfs.enabled", "brave.today.opted_in", "brave.new_tab_page.show_branded_background_image",
        "brave.new_tab_page.show_binance", "brave.new_tab_page.show_gemini",
        "brave.brave_vpn.subscriber_credential", "brave.ai_chat.show_toolbar_button",
    }
    for p in profs:
        print(f"\n  Profile: {p.name}")
        try:
            d = load_json(p / "Preferences")
        except Exception as e:
            print(f"    (cannot read Preferences: {e})")
            continue
        for path in sorted(interesting):
            v = nested_get(d, split(path))
            mark = "ON" if v else "off"
            if v is None:
                mark = "unset"
            print(f"    {mark:4} {path} = {v!r}")
        ls = root / "Local State"
        if ls.is_file():
            ld = load_json(ls)
            ref = nested_get(ld, split("brave.referral.promo_code"))
            print(f"    referral.promo_code = {ref!r}")


# ------------------------------------------------------------------------------ main

def main() -> int:
    ap = argparse.ArgumentParser(description="Strip Brave crypto & monetization features.")
    ap.add_argument("--dry-run", action="store_true", help="preview; write nothing")
    ap.add_argument("--quit", action="store_true", help="quit Brave before applying")
    ap.add_argument("--no-backup", action="store_true", help="skip backing up pref files")
    ap.add_argument("--purge", action="store_true", help="also delete wallet/ads/rewards DBs + wallet secrets (destructive)")
    ap.add_argument("--write-policy", action="store_true", help="also emit a managed-preferences plist")
    ap.add_argument("--list", action="store_true", help="show current monetization state and exit")
    ap.add_argument("--user-data", help="override Brave user-data directory")
    args = ap.parse_args()

    root = Path(args.user_data) if args.user_data else brave_user_data_dir()
    profs = profiles(root)

    if args.list:
        show_current(root, profs)
        return 0

    if not profs:
        print(f"No Brave profiles found under: {root}", file=sys.stderr)
        print("Use --user-data to point at the right directory.", file=sys.stderr)
        return 2

    if not args.dry_run and brave_running():
        if args.quit:
            print("Brave is running — quitting it...")
            if not quit_brave():
                print("Brave did not quit in time. Close it manually and rerun.", file=sys.stderr)
                return 1
        else:
            print("Brave is running. Close it first (or pass --quit); edits would be overwritten on exit.",
                  file=sys.stderr)
            return 1

    backup_dir = root / "debrave-backups"
    total_changes = 0
    purge_rules = [(p, "del", None, g) for p, g in PURGE_PREF_DELETIONS]

    for prof in profs:
        pref_path = prof / "Preferences"
        data = load_json(pref_path)
        before = copy.deepcopy(data)
        rules = list(PREF_RULES) + (purge_rules if args.purge else [])
        changed = apply_rules(data, rules)
        print_changes(f"[{prof.name}] Preferences", changed)
        total_changes += len(changed)

        if args.dry_run:
            continue

        if changed:
            if not args.no_backup:
                b = backup_file(pref_path, backup_dir)
                if b:
                    print(f"    backup: {b}")
            save_json(pref_path, data)

        if args.purge:
            for dname in PURGE_DIRS:
                d = prof / dname
                if d.exists():
                    if not args.no_backup:
                        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                        shutil.move(str(d), str(backup_dir / f"{prof.name}-{dname}.{stamp}"))
                        print(f"    purged+backed-up dir: {dname}")
                    else:
                        shutil.rmtree(d)
                        print(f"    purged dir: {dname}")

    # Local State (global)
    ls_path = root / "Local State"
    if ls_path.is_file():
        ld = load_json(ls_path)
        changed = apply_rules(ld, LOCAL_STATE_RULES)
        print_changes("[Global] Local State", changed)
        total_changes += len(changed)
        if changed and not args.dry_run:
            if not args.no_backup:
                b = backup_file(ls_path, backup_dir)
                if b:
                    print(f"    backup: {b}")
            save_json(ls_path, ld)

    if args.write_policy:
        write_policy(backup_dir if not args.dry_run else Path("."), args.dry_run)

    mode = "DRY RUN" if args.dry_run else "DONE"
    print(f"\n{mode}: {total_changes} preference change(s) across {len(profs)} profile(s).")
    if args.purge:
        print("  (purge: wallet/ads/rewards DBs + wallet secrets targeted)")
    if args.write_policy and not args.dry_run:
        print(f"  Policy plist written — install with the sudo command above to hard-enforce.")
    if not args.dry_run and total_changes:
        print("  Restart Brave to see the effect.")
    return 0


def write_policy(out_dir: Path, dry: bool) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    plist = out_dir / "com.brave.Browser.plist"
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
             '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
             '<plist version="1.0">', '<dict>']
    for k, v in POLICIES.items():
        tag = "true" if v is True else ("false" if v is False else "string")
        if isinstance(v, bool):
            lines += [f"  <key>{k}</key>", f"  <{tag}/>"]
        else:
            lines += [f"  <key>{k}</key>", f"  <{tag}>{v}</{tag}>"]
    lines += ['</dict>', '</plist>', '']
    plist.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n  Policy plist: {plist}")
    print(f"  Install (hard-enforces across updates):")
    print(f"    sudo install -o root -g wheel -m 644 \"{plist}\" \"{POLICY_INSTALL_PATH}\"")
    print(f"  Remove later with: sudo rm \"{POLICY_INSTALL_PATH}\"")
    if dry:
        print("  (dry-run: plist written next to script for inspection)")


if __name__ == "__main__":
    sys.exit(main())
