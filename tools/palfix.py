#!/usr/bin/env python3
"""palfix - PalRelay's co-op -> dedicated-server save migration helper.

Battle-tested strategy (2026 Summer Update save format, PlM/Oodle):

* NEVER rewrite Players/*.sav - the server re-creates characters when player
  files are touched by tools.
* NEVER round-trip structures the parser only half-understands: writes use
  CONSERVATIVE mode, decoding only CharacterSaveParameterMap and
  CharacterContainerSaveData (both verified to re-serialize correctly);
  guilds, item-container slots, map objects etc. pass through byte-identical.
  (Full-decode rewrites corrupt the server's new-format guild blobs, which
  makes the server reject the player and spawn endless fresh characters.)
* Migration = "params swap": after the original co-op host joins the server
  once (creating a fresh, server-wired character), the old character's
  SaveParameter payload is swapped into that accepted entry, containers are
  re-keyed onto the ids referenced by the server-native player file, and the
  legacy entry/file are retired.

Subcommands (each prints one ASCII-safe JSON line on stdout):
  meta  --dir <world_dir>                     world name from LevelMeta.sav
  check --dir <world_dir> [--write-test]     parse + conservative round-trip
  players --dir <world_dir>                  identity diagnostic
  fix   --dir <world_dir> --new-guid <32hex> [--old-guid <32hex>]
        run the full migration (host must have joined once already)

Save parsing by palworld-save-tools + quadrantbs/palworld-hostfix-toolkit
patches (both MIT). PlM decompression via libooz.dll (github.com/zao/ooz),
located through PALWORLD_OOZ_DLL_PATH, --ooz-dll, or next to the executable.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile

ZERO_UID = "00000000-0000-0000-0000-000000000000"
DEFAULT_OLD = "00000000000000000000000000000001"

# Player-file fields that carry per-player PROGRESS (transplanted during fix).
# Identity fields (PlayerUId, IndividualId), container references and
# platform info deliberately stay with the server-created file.
PROGRESS_FIELDS = [
    "TechnologyPoint",
    "bossTechnologyPoint",
    "UnlockedRecipeTechnologyNames",
    "CompletedQuestArray_FullRelease",
    "OrderedQuestArray_FullRelease",
    "RecordData",
    "PlayerCharacterMakeData",
]

# WorldOption.sav keys owned by server operation / PalRelay provisioning;
# everything else is a gameplay setting that should follow the world.
OPTION_EXCLUDE = {
    "ServerName", "ServerDescription", "AdminPassword", "ServerPassword",
    "PublicPort", "PublicIP", "RCONEnabled", "RCONPort", "Region", "bUseAuth",
    "BanListURL", "RESTAPIEnabled", "RESTAPIPort", "bShowPlayerList",
    "ChatPostLimitPerMinute", "CrossplayPlatforms", "LogFormatType",
    "bIsUseBackupSaveData", "bAllowClientMod", "CoopPlayerMaxNum",
    "ServerPlayerMaxNum", "bIsMultiplay", "DenyTechnologyList",
    "RandomizerType", "RandomizerSeed", "bIsRandomizerPalLevelRandom",
}

_lib = None
_REAL_STDOUT = sys.stdout


def emit(obj):
    print(json.dumps(obj, ensure_ascii=True), file=_REAL_STDOUT)
    _REAL_STDOUT.flush()


def fail(msg):
    emit({"ok": False, "error": msg})
    sys.exit(1)


def setup_ooz(cli_path=None):
    existing = os.environ.get("PALWORLD_OOZ_DLL_PATH")
    if existing and os.path.exists(existing):
        return
    candidates = []
    if cli_path:
        candidates.append(cli_path)
    bases = []
    if getattr(sys, "_MEIPASS", None):
        bases.append(sys._MEIPASS)
    bases.append(os.path.dirname(os.path.abspath(sys.executable)))
    bases.append(os.path.dirname(os.path.abspath(__file__)))
    for b in bases:
        candidates.append(os.path.join(b, "libooz.dll"))
        candidates.append(os.path.join(b, "ooz", "libooz.dll"))
    for c in candidates:
        if c and os.path.exists(c):
            os.environ["PALWORLD_OOZ_DLL_PATH"] = os.path.abspath(c)
            return


def lib():
    global _lib
    if _lib is None:
        try:
            from palworld_save_tools.gvas import GvasFile
            from palworld_save_tools.palsav import (
                compress_gvas_to_sav,
                decompress_sav_to_gvas,
            )
            from palworld_save_tools.paltypes import (
                PALWORLD_CUSTOM_PROPERTIES,
                PALWORLD_TYPE_HINTS,
            )
        except ImportError as e:
            fail(f"palworld-save-tools not available: {e}")
        conservative = {
            k: v for k, v in PALWORLD_CUSTOM_PROPERTIES.items()
            if "CharacterSaveParameterMap" in k or "CharacterContainerSaveData" in k
        }
        _lib = {
            "GvasFile": GvasFile,
            "compress": compress_gvas_to_sav,
            "decompress": decompress_sav_to_gvas,
            "full": PALWORLD_CUSTOM_PROPERTIES,
            "conservative": conservative,
            "hints": PALWORLD_TYPE_HINTS,
        }
    return _lib


def dashed(hex32):
    g = hex32.replace("-", "").lower()
    if len(g) != 32:
        fail(f"not a 32-hex guid: {hex32}")
    return f"{g[0:8]}-{g[8:12]}-{g[12:16]}-{g[16:20]}-{g[20:32]}"


def load_json(path, props=None):
    L = lib()
    if props is None:
        props = L["full"]
    with open(path, "rb") as f:
        data = f.read()
    raw_gvas, save_type = L["decompress"](data)
    gvas = L["GvasFile"].read(raw_gvas, L["hints"], props, allow_nan=True)
    return gvas.dump(), save_type


def write_json(json_data, path, props=None):
    L = lib()
    if props is None:
        props = L["full"]
    gvas = L["GvasFile"].load(json_data)
    cls = gvas.header.save_game_class_name
    save_type = 0x32 if ("Pal.PalWorldSaveGame" in cls or "Pal.PalLocalWorldSaveGame" in cls) else 0x31
    sav = L["compress"](gvas.write(props), save_type)
    with open(path, "wb") as f:
        f.write(sav)


def wsd_of(level_json):
    props = level_json.get("properties", {})
    if "worldSaveData" not in props:
        fail("worldSaveData missing - not a Level.sav?")
    return props["worldSaveData"]["value"]


def save_parameter(entry):
    raw = entry.get("value", {}).get("RawData", {}).get("value")
    if not isinstance(raw, dict):
        return {}
    return raw.get("object", {}).get("SaveParameter", {}).get("value", {})


def is_player_entry(entry):
    return bool(save_parameter(entry).get("IsPlayer", {}).get("value", False))


def collect_container_ids(sd, prefix=""):
    found = {}
    if not isinstance(sd, dict):
        return found
    for k, v in sd.items():
        path = f"{prefix}/{k}"
        if isinstance(v, dict):
            if k.endswith("ContainerId"):
                inner = v.get("value", {})
                gid = None
                if isinstance(inner, dict):
                    idf = inner.get("ID")
                    if isinstance(idf, dict) and "value" in idf:
                        gid = str(idf["value"]).lower()
                    elif "value" in inner:
                        gid = str(inner["value"]).lower()
                if gid:
                    found[path] = gid
                    continue
            found.update(collect_container_ids(v, path))
    return found


def entry_key_id(entry):
    key = entry.get("key")
    if not isinstance(key, dict):
        return None
    idf = key.get("ID")
    if isinstance(idf, dict) and "value" in idf:
        return str(idf["value"]).lower()
    if "value" in key:
        return str(key["value"]).lower()
    return None


def set_entry_key_id(entry, new_id):
    key = entry["key"]
    if isinstance(key.get("ID"), dict) and "value" in key["ID"]:
        key["ID"]["value"] = new_id
    else:
        key["value"] = new_id


def verify_chain(world_dir, uid_dashed):
    """Structural identity-chain check: player file -> character entry ->
    guild reference -> containers. Returns (ok, report)."""
    L = lib()
    problems = []
    report = {}
    uid_hex = uid_dashed.replace("-", "").upper()
    level_path = os.path.join(world_dir, "Level.sav")
    player_path = os.path.join(world_dir, "Players", uid_hex + ".sav")
    if not os.path.exists(player_path):
        return False, {"ok": False, "problems": [f"player file missing: Players/{uid_hex}.sav"]}
    if not os.path.exists(level_path):
        return False, {"ok": False, "problems": ["Level.sav missing"]}

    pj, _ = load_json(player_path)
    sd = pj["properties"]["SaveData"]["value"]
    file_uid = str(sd.get("PlayerUId", {}).get("value", "")).lower()
    file_inst = str(sd["IndividualId"]["value"]["InstanceId"]["value"]).lower()
    report["fileInstance"] = file_inst
    if file_uid != uid_dashed:
        problems.append(f"player file uid is {file_uid}, expected {uid_dashed}")

    level_json, _ = load_json(level_path, L["conservative"])
    wsd = wsd_of(level_json)
    char_map = wsd.get("CharacterSaveParameterMap", {}).get("value", [])
    mine = []
    legacy = []
    for e in char_map:
        if not is_player_entry(e):
            continue
        e_uid = str(e["key"]["PlayerUId"]["value"]).lower()
        if e_uid == uid_dashed:
            mine.append(e)
        elif e_uid == dashed(DEFAULT_OLD):
            legacy.append(e)
    if legacy:
        problems.append("legacy co-op host entry (…0001) still present in Level.sav")
    if len(mine) == 0:
        problems.append(f"no character entry for {uid_dashed} in Level.sav")
    elif len(mine) > 1:
        insts = [str(e["key"]["InstanceId"]["value"]).lower()[:8] for e in mine]
        problems.append(f"duplicate character entries for the same uid: {insts}")
    match = None
    for e in mine:
        if str(e["key"]["InstanceId"]["value"]).lower() == file_inst:
            match = e
    if mine and match is None:
        insts = [str(e["key"]["InstanceId"]["value"]).lower()[:8] for e in mine]
        problems.append(
            f"player file points at instance {file_inst[:8]} but entry instances are {insts}")
    if match is not None:
        sp = save_parameter(match)
        report["nickname"] = sp.get("NickName", {}).get("value")
        lvl = sp.get("Level", {}).get("value")
        if isinstance(lvl, dict):
            lvl = lvl.get("value")
        report["level"] = lvl
        raw = match.get("value", {}).get("RawData", {}).get("value")
        group_id = str(raw.get("group_id", "")).lower() if isinstance(raw, dict) else ""
        report["groupId"] = group_id
        if group_id:
            group_keys = {str(g.get("key", "")).lower()
                          for g in wsd.get("GroupSaveDataMap", {}).get("value", [])}
            if group_id not in group_keys:
                problems.append(f"entry references guild {group_id[:8]} which does not exist (dangling)")
            else:
                report["guildFound"] = True

    container_keys = set()
    for section in ("ItemContainerSaveData", "CharacterContainerSaveData"):
        for e in wsd.get(section, {}).get("value", []):
            kid = entry_key_id(e)
            if kid:
                container_keys.add(kid)
    wanted = list(collect_container_ids(sd).values())
    missing = [c for c in wanted if c not in container_keys]
    report["containersExpected"] = len(wanted)
    report["containersFound"] = len(wanted) - len(missing)
    if missing:
        problems.append(f"{len(missing)} container(s) referenced by the player file are missing")

    report["ok"] = not problems
    report["problems"] = problems
    return report["ok"], report


# ------------------------------------------------------------- commands ----

def cmd_meta(args):
    meta_path = os.path.join(args.dir, "LevelMeta.sav")
    if not os.path.exists(meta_path):
        fail("LevelMeta.sav not found")
    meta_json, _ = load_json(meta_path)
    sd = meta_json.get("properties", {}).get("SaveData", {}).get("value", {})
    out = {"ok": True, "worldName": None}
    for key in ("WorldName", "worldName"):
        if key in sd:
            out["worldName"] = sd[key].get("value")
            break
    if "HostPlayerName" in sd:
        out["hostPlayerName"] = sd["HostPlayerName"].get("value")
    if "InGameDay" in sd:
        out["inGameDay"] = sd["InGameDay"].get("value")
    emit(out)


def cmd_check(args):
    L = lib()
    level_path = os.path.join(args.dir, "Level.sav")
    if not os.path.exists(level_path):
        fail("Level.sav not found")
    with open(level_path, "rb") as f:
        head = f.read(24)
    magic = head[8:11].decode("ascii", "replace") if len(head) >= 11 else "?"
    level_json, _ = load_json(level_path, L["conservative"])
    wsd = wsd_of(level_json)
    char_map = wsd.get("CharacterSaveParameterMap", {}).get("value", [])
    players = []
    pals = 0
    for entry in char_map:
        uid = str(entry["key"]["PlayerUId"]["value"]).lower()
        if is_player_entry(entry):
            players.append(uid)
        else:
            pals += 1
    pdir = os.path.join(args.dir, "Players")
    player_files = []
    if os.path.isdir(pdir):
        player_files = sorted(
            f[:-4].lower() for f in os.listdir(pdir) if f.lower().endswith(".sav")
        )
    out = {
        "ok": True,
        "magic": magic,
        "characterEntries": len(char_map),
        "playerCharacters": sorted(players),
        "palCount": pals,
        "playerFiles": player_files,
    }
    if args.write_test:
        tmp = tempfile.NamedTemporaryFile(suffix=".sav", delete=False)
        tmp.close()
        try:
            write_json(level_json, tmp.name, L["conservative"])
            reread, _ = load_json(tmp.name, L["conservative"])
            wsd_of(reread)
            out["writeTest"] = "ok"
        finally:
            os.unlink(tmp.name)
    emit(out)


def cmd_players(args):
    L = lib()
    level_path = os.path.join(args.dir, "Level.sav")
    if not os.path.exists(level_path):
        fail("Level.sav not found")
    level_json, _ = load_json(level_path, L["conservative"])
    wsd = wsd_of(level_json)
    entries = []
    for entry in wsd.get("CharacterSaveParameterMap", {}).get("value", []):
        if not is_player_entry(entry):
            continue
        sp = save_parameter(entry)
        entries.append({
            "uid": str(entry["key"]["PlayerUId"]["value"]).lower(),
            "instance": str(entry["key"]["InstanceId"]["value"]).lower(),
            "nickname": sp.get("NickName", {}).get("value"),
            "level": sp.get("Level", {}).get("value"),
        })
    files = []
    pdir = os.path.join(args.dir, "Players")
    if os.path.isdir(pdir):
        for f in sorted(os.listdir(pdir)):
            if not f.lower().endswith(".sav"):
                continue
            try:
                pj, _ = load_json(os.path.join(pdir, f))
                sd = pj["properties"]["SaveData"]["value"]
                rec = {"file": f, "playerUId": str(sd.get("PlayerUId", {}).get("value", "")).lower()}
                if "IndividualId" in sd:
                    rec["instance"] = str(sd["IndividualId"]["value"]["InstanceId"]["value"]).lower()
                files.append(rec)
            except Exception as e:
                files.append({"file": f, "error": f"{type(e).__name__}: {e}"})
    emit({"ok": True, "mapEntries": entries, "playerFiles": files})


def cmd_fix(args):
    L = lib()
    world_dir = args.dir
    old_d = dashed(args.old_guid)
    new_d = dashed(args.new_guid)
    old_hex = old_d.replace("-", "").upper()
    new_hex = new_d.replace("-", "").upper()
    if old_d == new_d:
        fail("old and new guid are identical")

    pdir = os.path.join(world_dir, "Players")
    old_player_path = os.path.join(pdir, f"{old_hex}.sav")
    new_player_path = os.path.join(pdir, f"{new_hex}.sav")
    level_path = os.path.join(world_dir, "Level.sav")
    for p, msg in (
        (level_path, "Level.sav not found"),
        (old_player_path, f"old player file not found: Players/{old_hex}.sav"),
        (new_player_path,
         f"new player file not found: Players/{new_hex}.sav "
         "(the original host must join the server once and create a character first)"),
    ):
        if not os.path.exists(p):
            fail(msg)

    stats = {}
    level_json, _ = load_json(level_path, L["conservative"])
    old_pj, _ = load_json(old_player_path)
    new_pj, _ = load_json(new_player_path)
    wsd = wsd_of(level_json)
    old_sd = old_pj["properties"]["SaveData"]["value"]
    new_sd = new_pj["properties"]["SaveData"]["value"]
    old_inst = str(old_sd["IndividualId"]["value"]["InstanceId"]["value"]).lower()
    new_inst = str(new_sd["IndividualId"]["value"]["InstanceId"]["value"]).lower()

    # --- 1. locate entries: legacy host + server-accepted fresh character ---
    char_map = wsd["CharacterSaveParameterMap"]["value"]
    old_i = fresh_i = None
    for i, entry in enumerate(char_map):
        uid = str(entry["key"]["PlayerUId"]["value"]).lower()
        inst = str(entry["key"]["InstanceId"]["value"]).lower()
        if inst == old_inst or (uid == old_d and is_player_entry(entry)):
            if old_i is None:
                old_i = i
        elif uid == new_d and inst == new_inst:
            fresh_i = i
    if old_i is None:
        fail(f"legacy host character entry not found (instance {old_inst})")
    if fresh_i is None:
        fail(f"fresh character entry not found for {new_d} / {new_inst} - "
             "end the hosting session after the host creates their character, then rerun")

    # --- 2. params swap into the accepted entry (its wiring stays intact) ---
    old_sp = char_map[old_i]["value"]["RawData"]["value"]["object"]["SaveParameter"]
    fresh_obj = char_map[fresh_i]["value"]["RawData"]["value"]["object"]
    fresh_obj["SaveParameter"] = old_sp
    swapped = fresh_obj["SaveParameter"].get("value", {})
    lnm = swapped.get("LastNickNameModifierPlayerUid")
    if isinstance(lnm, dict) and str(lnm.get("value", "")).lower() == old_d:
        lnm["value"] = new_d
    stats["paramsSwapped"] = True
    del char_map[old_i]
    if old_i < fresh_i:
        fresh_i -= 1
    stats["legacyEntryRemoved"] = True

    # --- 3. pal keys + internal owners (quadrantbs layers 1+2) --------------
    rekeyed = owner_fixed = old_owner_fixed = 0
    for entry in char_map:
        if is_player_entry(entry):
            continue
        if str(entry["key"]["PlayerUId"]["value"]).lower() != ZERO_UID:
            entry["key"]["PlayerUId"]["value"] = ZERO_UID
            rekeyed += 1
        sp = save_parameter(entry)
        owner = sp.get("OwnerPlayerUId", {})
        if str(owner.get("value", "")).lower() == old_d:
            owner["value"] = new_d
            owner_fixed += 1
        old_owners = sp.get("OldOwnerPlayerUIds", {}).get("value", {})
        vals = old_owners.get("values") if isinstance(old_owners, dict) else None
        if isinstance(vals, list):
            for i, v in enumerate(vals):
                if str(v).lower() == old_d:
                    vals[i] = new_d
                    old_owner_fixed += 1
    stats["palsRekeyed"] = rekeyed
    stats["ownerFixed"] = owner_fixed
    stats["oldOwnerFixed"] = old_owner_fixed

    # --- 4. character container slots (quadrantbs layer 4) ------------------
    slots_fixed = 0
    for c in wsd.get("CharacterContainerSaveData", {}).get("value", []):
        slots = c.get("value", {}).get("Slots", {}).get("value", {})
        for s in slots.get("values", []) or []:
            rd = s.get("RawData", {}).get("value", {})
            if isinstance(rd, dict) and "player_uid" in rd:
                if str(rd["player_uid"]).lower() == old_d:
                    rd["player_uid"] = ZERO_UID
                    slots_fixed += 1
    stats["containerSlotsFixed"] = slots_fixed

    # --- 5. containers: legacy character's ids -> accepted file's ids -------
    old_ids = collect_container_ids(old_sd)
    new_ids = collect_container_ids(new_sd)
    pairs = [(gid, new_ids[p]) for p, gid in old_ids.items() if p in new_ids and new_ids[p] != gid]
    containers_rekeyed = dropped = 0
    for section in ("ItemContainerSaveData", "CharacterContainerSaveData"):
        entries = wsd.get(section, {}).get("value", [])
        for old_id, new_id in pairs:
            fresh_j = old_j = None
            for j, e in enumerate(entries):
                kid = entry_key_id(e)
                if kid == new_id:
                    fresh_j = j
                elif kid == old_id:
                    old_j = j
            if old_j is None:
                continue
            if fresh_j is not None:
                del entries[fresh_j]
                dropped += 1
                if fresh_j < old_j:
                    old_j -= 1
            set_entry_key_id(entries[old_j], new_id)
            containers_rekeyed += 1
    stats["containerPairs"] = len(pairs)
    stats["containersRekeyed"] = containers_rekeyed
    stats["freshContainersDropped"] = dropped

    # --- 5b. progress transplant into the accepted player file --------------
    # (tech points, recipes, quests, paldeck records incl. fast-travel
    # unlocks, appearance). Verified live: the server accepts a rewritten
    # player file as long as identity/containers are untouched.
    moved_progress = []
    for f in PROGRESS_FIELDS:
        if f in old_sd:
            new_sd[f] = old_sd[f]
            moved_progress.append(f)
    stats["progressTransplanted"] = moved_progress

    # --- 6. write (conservative: guilds & co. stay byte-identical) ----------
    shutil.copy2(level_path, level_path + ".palfix-bak")
    write_json(level_json, level_path, L["conservative"])
    shutil.copy2(new_player_path, new_player_path + ".pre-progress-bak")
    write_json(new_pj, new_player_path)
    os.rename(old_player_path, old_player_path + ".palfix-bak")

    # --- 7. verify the identity chain; roll back automatically on failure ---
    ok, vreport = verify_chain(world_dir, new_d)
    stats["verify"] = vreport
    if not ok:
        shutil.copy2(level_path + ".palfix-bak", level_path)
        shutil.copy2(new_player_path + ".pre-progress-bak", new_player_path)
        os.rename(old_player_path + ".palfix-bak", old_player_path)
        stats["ok"] = False
        stats["rolledBack"] = True
        stats["error"] = "post-fix verification failed, all changes rolled back: " + \
            "; ".join(vreport.get("problems", []))
        emit(stats)
        sys.exit(1)

    stats["ok"] = True
    stats["oldGuid"] = old_d
    stats["newGuid"] = new_d
    emit(stats)


def cmd_options(args):
    """Extract gameplay world settings from WorldOption.sav as ini-ready
    key/value overrides (server-operational keys excluded)."""
    src = args.world_option
    if not os.path.exists(src):
        fail(f"WorldOption.sav not found: {src}")
    wo_json, _ = load_json(src)
    try:
        settings = wo_json["properties"]["OptionWorldData"]["value"]["Settings"]["value"]
    except (KeyError, TypeError):
        fail("OptionWorldData/Settings not found in WorldOption.sav")

    def fmt(val):
        if isinstance(val, bool):
            return "True" if val else "False"
        if isinstance(val, float):
            return f"{val:.6f}"
        if isinstance(val, int):
            return str(val)
        s = str(val)
        if "::" in s:
            return s.split("::")[-1]
        return None  # strings / complex structures: skip

    flat = {}
    for k, v in settings.items():
        if k in OPTION_EXCLUDE:
            continue
        val = v.get("value")
        if isinstance(val, dict) and "value" in val:
            val = val["value"]
        f = fmt(val)
        if f is not None:
            flat[k] = f
    emit({"ok": True, "optionOverrides": flat})


def main():
    ap = argparse.ArgumentParser(prog="palfix")
    ap.add_argument("--ooz-dll", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_meta = sub.add_parser("meta")
    p_meta.add_argument("--dir", required=True)

    p_check = sub.add_parser("check")
    p_check.add_argument("--dir", required=True)
    p_check.add_argument("--write-test", action="store_true")

    p_players = sub.add_parser("players")
    p_players.add_argument("--dir", required=True)

    p_fix = sub.add_parser("fix")
    p_fix.add_argument("--dir", required=True)
    p_fix.add_argument("--new-guid", required=True)
    p_fix.add_argument("--old-guid", default=DEFAULT_OLD)

    p_verify = sub.add_parser("verify")
    p_verify.add_argument("--dir", required=True)
    p_verify.add_argument("--uid", required=True)

    p_opt = sub.add_parser("options")
    p_opt.add_argument("--world-option", required=True)

    args = ap.parse_args()
    setup_ooz(args.ooz_dll)
    sys.stdout = sys.stderr  # keep parser warnings off the JSON channel
    try:
        if args.cmd == "meta":
            cmd_meta(args)
        elif args.cmd == "check":
            cmd_check(args)
        elif args.cmd == "players":
            cmd_players(args)
        elif args.cmd == "fix":
            cmd_fix(args)
        elif args.cmd == "verify":
            ok, vreport = verify_chain(args.dir, dashed(args.uid))
            emit(vreport)
            if not ok:
                sys.exit(1)
        elif args.cmd == "options":
            cmd_options(args)
    except SystemExit:
        raise
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
