# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is a fork of the [Archipelago](https://github.com/ArchipelagoMW/Archipelago) multiworld randomizer, whose primary purpose in this fork is developing the **Left 4 Dead 2** world (`worlds/L4D2/`). Per the root [README.md](README.md), this L4D2 apworld is a WIP: DeathLink is being actively developed (see `worlds/L4D2/ThirdPartyProgramStuff/` — not yet fully working as of the README), weapon spawning and traps are still being tuned, and the original author is not actively maintaining it. When working in this repo, assume L4D2-specific work unless told otherwise; the rest of the tree is upstream Archipelago core, present because the L4D2 world builds on top of it.

## Running from source

Requires Python 3.11.9+ (3.13.x currently newest supported) and pip. Run `ModuleUpdate.py` first — it prompts to install/update all required modules (press enter to confirm):
```bash
python ModuleUpdate.py
```
Entry points:
- `Launcher.py` — GUI access to components/clients registered in `worlds/LauncherComponents.py`; has a "Generate Template Options" button for default YAMLs.
- `Generate.py` — generates a multiworld archive from YAMLs in the `Players/` folder.
- `MultiServer.py <archive file>` — hosts a multiworld locally (`--log_network` for debugging).
- `WebHost.py` — hosts the website locally (copy `docs/webhost configuration sample.yaml` to `config.yaml` to configure).

Full details, including platform-specific notes (Windows Visual Studio Build Tools, macOS, optional Enemizer/SNI): `docs/running from source.md`.

## Tests

```bash
pip install pytest pytest-subtests
pytest                      # from the repo root
pytest -n12                 # parallel, needs pytest-xdist
```
Generic per-world tests live in `test/general`; a world can add its own by creating a `test/` package inside the world directory (`__init__.py`, files named `test_*.py`, classes named `Test*`/`*Test` inheriting `unittest.TestCase` or `WorldTestBase` from `test/bases.py`). **`worlds/L4D2` has no `test/` package yet** — there's a standalone `worlds/L4D2/debug_location_check.py` script instead, which is not part of the pytest suite. See `docs/tests.md` for the full authoring guide (note: Archipelago tests may not use `@pytest.mark.parametrize`; use `test.param` helpers instead).

## Style

- 120 char lines, double-quoted strings, PEP8 with new-style type annotations (`dict[str, int]`, not `Dict[str, int]`) for new code.
- Full guide: `docs/style.md`.

## Architecture: how a world plugs into Archipelago core

A "world" (`worlds/<Name>/`) is a self-contained game implementation that the core generation/server/client machinery drives through a standard interface. The core files at the repo root you'll cross-reference when working on a world:
- `BaseClasses.py` — core `World`, `MultiWorld`, `Item`, `Location`, `Region`, `Entrance` classes every world subclasses/uses.
- `Options.py` — core option types (`Toggle`, `Choice`, `Range`, etc.) worlds build their own `Options.py` from.
- `Fill.py` — the item-placement/fill algorithm run during generation.
- `Generate.py` — orchestrates reading YAMLs, generating the multiworld, and producing the output archive.
- `NetUtils.py` / `MultiServer.py` — the network protocol and server; `CommonClient.py` is the base client implementations subclass (see `docs/network protocol.md`).
- Full spec: `docs/world api.md`, `docs/apworld specification.md`, `docs/options api.md`.

Within `worlds/L4D2/`, the convention (matching most worlds) is: `Options.py` (player-facing YAML options, e.g. `L4D2DeathLink`), `Items.py`/`Locations.py` (item/location tables and IDs), `Regions.py`/`Rules.py` (region graph and access logic), `Types.py` (shared enums/dataclasses), and `__init__.py` (the `World` subclass tying it together, including `fill_slot_data()` — what gets sent to the client on connect). These generation-time files only affect `.apworld` packaging/generation; they are independent of the runtime pieces below and don't need touching (or an `.apworld` rebuild) when only those change.

## Architecture: L4D2 runtime integration (outside the apworld)

Unlike most worlds, L4D2 is a live Source-engine game with no scriptable client of its own, so this world ships a **separate runtime bridge** living entirely in `worlds/L4D2/ThirdPartyProgramStuff/`, decoupled from the `.apworld`:

1. **`ap_companion_clean.py`** — a Tkinter GUI Python app that *is* the actual AP client: connects to the AP server over WebSocket (`websockets` is its only third-party dependency), speaks the AP network protocol, and bridges to the running game via file-drop polling. Built into a distributable `.exe` via PyInstaller (`ap_companion_clean.spec`); rebuild with `python -m PyInstaller --clean ap_companion_clean.spec` after any source edit — `--clean` matters, since PyInstaller's incremental cache can silently skip re-bundling a newly-installed dependency, and a plain rebuild with a missing dependency succeeds without error but produces a runtime-broken `.exe`.

2. **SourceMod (SourcePawn) plugin(s)** running inside L4D2 itself (`addons/sourcemod/plugins/` on an actual L4D2 install) — these call game natives/L4DHooks forwards to spawn traps, kill players, etc., and report events (location checks, deaths) back out. **No `.sp` source for the original trap plugin exists in this repo** — only new plugins built from scratch (e.g. `worlds/L4D2/ThirdPartyProgramStuff/sourcemod/scripting/l4d2_deathlink.sp`) have source here; treat any existing compiled `.smx` you find as opaque. A local build toolchain lives in `worlds/L4D2/ThirdPartyProgramStuff/sm-devkit/scripting/` (with its own `include/` — copy `.inc` files from a real, currently-installed SourceMod/L4DHooks install to keep signatures in sync with what's actually deployed); compile with `spcomp.exe <file>.sp -o <file>.smx -i <path-to-include-dir>` from that directory.

3. **File-drop IPC** is the *only* channel between (1) and (2) — there is no socket/RCON between the companion app and the game. Both sides poll (companion ~10Hz via `asyncio.sleep(0.1)` in `main_loop`; plugins ~4Hz via a repeating `CreateTimer`) a shared directory for small text files, consuming (reading + deleting) each one to avoid double-processing:
   ```
   <L4D2 install>/left4dead2/addons/sourcemod/data/archipelago/mod_data/
   ```
   Existing message files: `trap_command.txt`, `item_spawn.txt`, `starting_items.txt`, `location_check.txt`, `deathlink_outgoing.txt`, `deathlink_incoming.txt`. When adding a new file-drop message type, follow the existing pattern in `write_trap_command`/`main_loop` in `ap_companion_clean.py` (write/poll across all detected install paths from `L4D2_PATHS`, plus a CWD fallback).

   **Known gotcha**: in SourcePawn, `Path_SM` already resolves to `<moddir>/addons/sourcemod` — a relative path string passed to `BuildPath(Path_SM, ...)` must start from `data/...`, not `addons/sourcemod/data/...`, or the prefix silently doubles into a nonexistent path. This was the root cause of a full debugging session where a new plugin appeared to read/write nothing at all.

## Distribution layout (per README.md)

End users install the compiled outputs (not source) into their L4D2 install: `.smx` plugin files → `addons/sourcemod/plugins/`; the `archipelago` data folder → `addons/sourcemod/data/`; a `.json` file → `addons/sourcemod/data/`; the `.apworld` → the Archipelago install's custom apworlds folder; a `.vpk` → `addons/`; the companion client `.exe` can live anywhere. Testing requires launching L4D2 in the Archipelago mutation and with `-insecure` in launch options, or scripts won't run.
