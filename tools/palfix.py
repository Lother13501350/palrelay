#!/usr/bin/env python3
"""palfix - PalRelay's co-op -> dedicated-server save migration helper.

Runs the FULL migration needed for post-2026-Summer-Update saves (PlM/Oodle
format), combining every layer of quadrantbs/palworld-hostfix-toolkit (MIT):

  layer 0  host character merge (adapted from xNul/palworld-host-save-fix, MIT)
  layer 1+2  pal map keys re-zeroed + OwnerPlayerUId/OldOwnerPlayerUIds
  layer 3  guild raw-blob pal handles zeroed (byte-level)
  layer 3b guild raw-blob old-guid -> new-guid byte replacement
  layer 4  character container slot player_uid fix

Requires palworld-save-tools with the hostfix-toolkit patches overlaid
(handles PlM via libooz.dll; writes back plain zlib which the game accepts).

Subcommands (all print one ASCII-safe JSON object on stdout):
  meta  --dir <world_dir>
  check --dir <world_dir> [--write-test]
  fix   --dir <world_dir> --new-guid <32hex> [--old-guid <32hex>]

libooz.dll is located via PALWORLD_OOZ_DLL_PATH, --ooz-dll, or next to the
executable/script. It is downloaded separately (github.com/zao/ooz) and is
only needed for PlM-format saves.
"""

import argparse
import json
import os
import sys
import tempfile

ZERO_UID = "00000000-0000-0000-0000-000000000000"
DEFAULT_OLD = "00000000000000000000000000000001"

_lib = None
_REAL_STDOUT = sys.stdout


def emit(obj):
    # The save-tools parsers print copious warnings to stdout; we shunt all of
    # that to stderr (see main) and reserve the real stdout for one JSON line.
    print(json.dumps(obj, ensure_ascii=True), file=_REAL_STDOUT)
    _REAL_STDOUT.flush()


def fail(msg):
    emit({"ok": False, "error": msg})
    sys.exit(1)


def setup_ooz(cli_path=None):
    # Must run BEFORE importing palworld_save_tools.palsav (it reads the env
    # var at import time).
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
            from palworld_save_tools.archive import UUID as PalUUID
        except ImportError as e:
            fail(f"palworld-save-tools not available: {e}")
        _lib = {
            "GvasFile": GvasFile,
            "compress": compress_gvas_to_sav,
            "decompress": decompress_sav_to_gvas,
            "props": PALWORLD_CUSTOM_PROPERTIES,
            "hints": PALWORLD_TYPE_HINTS,
            "UUID": PalUUID,
        }
    return _lib


def dashed(hex32):
    g = hex32.replace("-", "").lower()
    if len(g) != 32:
        fail(f"not a 32-hex guid: {hex32}")
    return f"{g[0:8]}-{g[8:12]}-{g[12:16]}-{g[16:20]}-{g[20:32]}"


def load_json(path):
    L = lib()
    with open(path, "rb") as f:
        data = f.read()
    raw_gvas, save_type = L["decompress"](data)
    gvas = L["GvasFile"].read(raw_gvas, L["hints"], L["props"], allow_nan=True)
    return gvas.dump(), save_type


def write_json(json_data, path):
    L = lib()
    gvas = L["GvasFile"].load(json_data)
    cls = gvas.header.save_game_class_name
    save_type = 0x32 if ("Pal.PalWorldSaveGame" in cls or "Pal.PalLocalWorldSaveGame" in cls) else 0x31
    sav = L["compress"](gvas.write(L["props"]), save_type)
    with open(path, "wb") as f:
        f.write(sav)


def guid_bytes(dashed_str):
    L = lib()
    u = L["UUID"].from_str(dashed_str) if hasattr(L["UUID"], "from_str") else L["UUID"](dashed_str)
    for attr in ("raw_bytes", "raw"):
        if hasattr(u, attr):
            return bytes(getattr(u, attr))
    import uuid as _uuid
    return _uuid.UUID(dashed_str).bytes_le


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
    level_path = os.path.join(args.dir, "Level.sav")
    if not os.path.exists(level_path):
        fail("Level.sav not found")
    with open(level_path, "rb") as f:
        head = f.read(24)
    magic = head[8:11].decode("ascii", "replace") if len(head) >= 11 else "?"
    level_json, _ = load_json(level_path)
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
    guilds = 0
    for entry in wsd.get("GroupSaveDataMap", {}).get("value", []):
        gtype = entry["value"].get("GroupType", {}).get("value")
        if isinstance(gtype, dict):
            gtype = gtype.get("value")
        if "Guild" in str(gtype):
            guilds += 1
    out = {
        "ok": True,
        "magic": magic,
        "characterEntries": len(char_map),
        "playerCharacters": sorted(players),
        "palCount": pals,
        "playerFiles": player_files,
        "guilds": guilds,
    }
    if args.write_test:
        tmp = tempfile.NamedTemporaryFile(suffix=".sav", delete=False)
        tmp.close()
        try:
            write_json(level_json, tmp.name)
            reread, _ = load_json(tmp.name)
            wsd_of(reread)
            out["writeTest"] = "ok"
        finally:
            os.unlink(tmp.name)
    emit(out)


def cmd_fix(args):
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
         "(join the dedicated server once and create a character first)"),
    ):
        if not os.path.exists(p):
            fail(msg)

    stats = {}
    level_json, _ = load_json(level_path)
    old_player_json, _ = load_json(old_player_path)
    wsd = wsd_of(level_json)

    # --- layer 0a: player file re-own -------------------------------------
    sd = old_player_json["properties"]["SaveData"]["value"]
    sd["PlayerUId"]["value"] = new_d
    old_instance = None
    if "IndividualId" in sd:
        sd["IndividualId"]["value"]["PlayerUId"]["value"] = new_d
        old_instance = str(sd["IndividualId"]["value"]["InstanceId"]["value"]).lower()

    # --- layer 0b: character map ------------------------------------------
    char_map = wsd["CharacterSaveParameterMap"]["value"]
    fresh_instance = None
    fresh_index = None
    host_index = None
    for i, entry in enumerate(char_map):
        uid = str(entry["key"]["PlayerUId"]["value"]).lower()
        inst = str(entry["key"]["InstanceId"]["value"]).lower()
        if old_instance is not None and inst == old_instance:
            host_index = i
        elif uid == new_d and is_player_entry(entry):
            fresh_index = i
            fresh_instance = inst
    if host_index is None:
        fail(f"no character entry with the host instance id {old_instance} in Level.sav")
    char_map[host_index]["key"]["PlayerUId"]["value"] = new_d
    if fresh_index is not None:
        del char_map[fresh_index]
    stats["freshCharacterRemoved"] = fresh_index is not None

    # --- layers 1+2: pal keys + internal owners ---------------------------
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

    # --- guild passes ------------------------------------------------------
    pal_instance_bytes = [
        guid_bytes(str(e["key"]["InstanceId"]["value"]).lower())
        for e in char_map
        if not is_player_entry(e)
    ]
    old_bytes = guid_bytes(old_d)
    new_bytes = guid_bytes(new_d)
    zero16 = b"\x00" * 16
    guild_dict_fixed = 0
    guild_bytes_replaced = 0
    guild_handles_zeroed = 0
    for group in wsd.get("GroupSaveDataMap", {}).get("value", []):
        gtype = group["value"].get("GroupType", {}).get("value")
        if isinstance(gtype, dict):
            gtype = gtype.get("value")
        if "Guild" not in str(gtype):
            continue
        raw = group["value"].get("RawData", {}).get("value")
        if not isinstance(raw, dict):
            continue
        # decoded-dict fixes (pre-update style, harmless if fields absent)
        if str(raw.get("admin_player_uid", "")).lower() == old_d:
            raw["admin_player_uid"] = new_d
            guild_dict_fixed += 1
        for p in raw.get("players", []) or []:
            if str(p.get("player_uid", "")).lower() == old_d:
                p["player_uid"] = new_d
                guild_dict_fixed += 1
        handles = raw.get("individual_character_handle_ids")
        if isinstance(handles, list) and old_instance is not None:
            for h in handles:
                if str(h.get("instance_id", "")).lower() == old_instance:
                    h["guid"] = new_d
                    guild_dict_fixed += 1
        # byte-level fixes for undecoded guild blobs (2026 format)
        if "values" in raw and isinstance(raw["values"], list):
            b = bytearray(bytes(raw["values"]))
            blob = bytes(b)
            if old_bytes in blob:
                b = bytearray(blob.replace(old_bytes, new_bytes))
                guild_bytes_replaced += blob.count(old_bytes)
            for inst_bytes in pal_instance_bytes:
                idx = bytes(b).find(inst_bytes)
                if idx >= 16 and bytes(b[idx - 16:idx]) != zero16:
                    b[idx - 16:idx] = zero16
                    guild_handles_zeroed += 1
            raw["values"] = list(bytes(b))
    stats["guildDictFixed"] = guild_dict_fixed
    stats["guildBytesReplaced"] = guild_bytes_replaced
    stats["guildHandlesZeroed"] = guild_handles_zeroed

    # --- layer 4: character container slots --------------------------------
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

    # --- write back (originals kept as .palfix-bak) ------------------------
    import shutil
    shutil.copy2(level_path, level_path + ".palfix-bak")
    shutil.copy2(new_player_path, new_player_path + ".palfix-bak")
    write_json(old_player_json, new_player_path)
    os.rename(old_player_path, old_player_path + ".palfix-bak")
    write_json(level_json, level_path)

    out = {"ok": True, "oldGuid": old_d, "newGuid": new_d}
    out.update(stats)
    emit(out)


def main():
    ap = argparse.ArgumentParser(prog="palfix")
    ap.add_argument("--ooz-dll", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_meta = sub.add_parser("meta")
    p_meta.add_argument("--dir", required=True)

    p_check = sub.add_parser("check")
    p_check.add_argument("--dir", required=True)
    p_check.add_argument("--write-test", action="store_true")

    p_fix = sub.add_parser("fix")
    p_fix.add_argument("--dir", required=True)
    p_fix.add_argument("--new-guid", required=True)
    p_fix.add_argument("--old-guid", default=DEFAULT_OLD)

    args = ap.parse_args()
    setup_ooz(args.ooz_dll)
    sys.stdout = sys.stderr  # keep parser warnings off the JSON channel
    try:
        if args.cmd == "meta":
            cmd_meta(args)
        elif args.cmd == "check":
            cmd_check(args)
        elif args.cmd == "fix":
            cmd_fix(args)
    except SystemExit:
        raise
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
