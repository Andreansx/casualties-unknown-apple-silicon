# Porting *Casualties: Together* (co-op mod) to the native arm64 Metal build

**Goal:** let people running our **native Apple Silicon / Metal port** play online co-op via the
community mod **Casualties: Together** (KrokMP) — **without Rosetta**, because Rosetta throws away
the port's whole reason to exist (native gameplay draws ~47% less power than the Wine/D3DMetal
path; see [`port-7.0.md`](port-7.0.md) and the power memory).

**Status in one line:** the single hard research blocker is **solved and reproducible** (BepInEx
now boots on native arm64); everything else is known, scoped, and mechanical. This is a
**packaging** problem now, not a research one.

This document is the durable state so a fresh session can pick up any single thread. It records
what the mod *is*, what was proven, the full blocker map with per-item status, the repo-layout
decision, and the phased to-do.

---

## 0. TL;DR status board

| Area | Status |
|---|---|
| Mod code portability (is the DLL arch-neutral?) | ✅ **Yes** — all managed assemblies are AnyCPU MSIL; nothing to recompile |
| BepInEx/Harmony on native arm64 (the hard blocker) | ✅ **SOLVED** (spike passed, reproducible) — `tools/bepinex-applesilicon/` |
| Steam lobbies on arm64 | 🔵 Possible (universal `libsteam_api.dylib`), **deferred to Phase 2** (direct-IP works without it) |
| Opus voice codec | 🟢 arm64 `libopus.dylib` already on the dev Mac (brew) |
| Steamworks.NET | 🟠 must **recompile** with `STEAMWORKS_LIN_OSX` (packing differs) |
| Microphone permission | 🟡 add `NSMicrophoneUsageDescription` or voice **TCC-kills** the app |
| Auto-updater | 🟡 strip it or it overwrites adapted files with Windows binaries |
| Game-hash cross-play gate | 🟠 one symlink (`Contents/Managed`) makes Mac hash == Windows hash |
| One-command installer (`tools/mp-install.sh`) | ⬜ **not built yet** — the main remaining work |

Legend: ✅ done · 🟢 trivial/have-it · 🟡 easy fix · 🟠 real work · 🔵 optional/later · ⬜ to build.

---

## 1. What the mod is (and where it lives)

- **Casualties: Together** = an online co-op mod for *Casualties: Unknown*, distributed as a
  **BepInEx 5** plugin (KrokMP) by **Krokosha666**. Repos
  ([creaturefeaturelarry/casualties-together](https://github.com/creaturefeaturelarry/casualties-together),
  upstream [Krokosha666/cas-unk-krokosha-multiplayer-coop](https://github.com/Krokosha666/cas-unk-krokosha-multiplayer-coop))
  are **docs-only — no source, no LICENSE.** The binary lives on NexusMods.
- **Consequence for us:** there is nothing to "fork and port". We adapt a copy the user downloads
  themselves, in place — the same shape as `port.sh` (which adapts the user's own game files and
  ships none of them). Because there's no license, we could not redistribute a patched DLL anyway;
  this repo is private, so that's moot for us, but the design (operate on the user's copy) is the
  right one regardless.
- **Payload** (from the NexusMods zip): `KrokoshaCasualtiesMP.dll` (~1.9 MB, the mod),
  `LiteNetLib.dll` (networking), `OpusSharp.Core.dll` + `opus.dll` (voice), `Steamworks.NET.dll`
  + `steam_api64.dll` (lobbies), `Multiupdater.dll` + `autoupdater_patcher.dll` (self-update).
  BepInEx itself: `BepInEx_win_x64_5` (the Windows build the mod's install guide points to).

---

## 2. What was accomplished (2026-07-17)

### 2a. Behavioural analysis of the mod (decompiled to C#)

Decompiled `KrokoshaCasualtiesMP.dll` with `ilspycmd` (IDA has `cli.dylib` but **no CIL
Hex-Rays decompiler** — ILSpy is the right tool for MSIL; IDA is only for the native `.dylib`s,
which we replace). Findings, all from the 54k-line decompile:

- **The mod is architecture-neutral.** Every managed assembly — including the proprietary
  `KrokoshaCasualtiesMP.dll` — is `ILONLY=1, 32BITREQ=0` (**AnyCPU**). Mono JITs them for arm64
  unchanged. **Nothing in the mod needs recompiling.** Only two files are genuinely native:
  `opus.dll` and `steam_api64.dll`.
- **Exactly one P/Invoke in the whole mod:** `user32!SetWindowText` (cosmetic window title), and
  it is self-guarding — `if (MainWindowHandle != IntPtr.Zero)`, so it no-ops when the handle is 0.
  (The earlier `GetCursorPos` scare was a false hit — it's a mod *method* name, not an import.)
- **No hardcoded Windows paths, no backslash literals.** Save system is portable:
  `mpsavefolder => Path.Combine(Application.persistentDataPath, "mp_save")`. The
  `%LocalAppData%Low\...` in the mod's docs is just Windows' expansion of `persistentDataPath`;
  on macOS it resolves under our bundle id automatically.
- **The mod explicitly supports the demo:** `APP_IS_DEMO = (STEAM_APPID == 4576510)`. Our port is
  a first-class target, not off-label.
- **Steam is optional.** `KSteam.Load()` runs `Packsize.Test()` → `DllCheck.Test()` →
  `SteamAPI.InitEx()`; any failure logs and returns with `Loaded=false`, and the UI falls back
  (`_USE_STEAM_MENU = KSteam.Loaded`) to **Direct Connect over IP** on LiteNetLib. So a first
  playable milestone does **not** require Steam at all.
- **Cross-play gate:** the mod computes `GAME_FILES_HASH` = FNV-1a-64 over
  `Application.dataPath + "/Managed/Assembly-CSharp.dll"` (then over its own dll), and a server
  with `SERVER_TOGGLE_CHECK_GAME_HASH` rejects mismatches. Our ported `Assembly-CSharp.dll` is
  **byte-identical** to the Windows 7.0.1 build (verified: sha256 `fd0ad285…`), and the hash is
  pure content — so a Mac client can hash **identically to a Windows player** → cross-play
  survives. BUT on macOS `Application.dataPath` is `<app>/Contents`, so the mod's path resolves to
  a file that doesn't exist → hash stays 0 → rejected. Fix: symlink `Contents/Managed →
  Resources/Data/Managed` (the port already uses this exact pattern for `Lang`/`custommusic`).
- **Voice** uses Unity's `Microphone` API (`Microphone.Start/devices`), guarded by
  `Microphone.devices.Length != 0`. On macOS, using the mic without
  `NSMicrophoneUsageDescription` in Info.plist doesn't just deny — it **TCC-kills the process**.

### 2b. The BepInEx-on-arm64 spike — SOLVED

Full write-up + code: **[`../tools/bepinex-applesilicon/`](../tools/bepinex-applesilicon/README.md)**.

- **Root blocker (corrected diagnosis):** it is **not** ARM misdetection (BepInEx sets the ARM bit
  itself). It is **W^X on Mono's `MAP_JIT` pages**: `mprotect(RW)` → **EACCES**, and
  `pthread_jit_write_protect_np` can't be driven from managed code (it disables execution of the
  patcher's own JIT pages). Proven empirically, not reasoned. This is exactly what MonoMod v25
  (PR #241) fixed for CoreCLR; BepInEx 5 ships MonoMod 22.x, which predates it.
- **The fix:** a native helper `as_jit_write` (unprotect → memcpy → reprotect → icache-flush in
  one native call) + a C# `IDetourNativePlatform` that wraps `DetourNativeARMPlatform` (its
  AArch64 encoding was already correct) and routes code-page writes through the helper. Installed
  via a **Doorstop entrypoint shim** (a BepInEx *patcher* is too late — the first detour fires
  before patchers initialize).
- **Result (reproducible):** on a **forced-arm64** (`arch -arm64`) headless run, a real
  method→method detour redirects (`SELF-TEST … PASS`) and BepInEx 5.4.23.5 reaches **`Chainloader
  startup complete`** with zero preloader crash. Baseline (same harness, no fix) reliably crashes
  at `HarmonyInteropFix` → `DetourHelper.GetIdentifiable` NRE.
- Corrected two earlier research claims: (1) `ApplyRuntimePatches=false` does **not** dodge the
  crash (`HarmonyInteropFix` is unconditional); (2) the only prior "working" arm64 boots were
  Rosetta, not native.

### 2c. Steam / networking research (external)

- `libsteam_api.dylib` is **universal (x86_64+arm64)** since Steamworks SDK 1.52; Valve's live
  `steamclient.dylib` went universal 2026-06-24 with the full lobby protocol in the arm64 slice.
  The "Steam has no ARM64" folklore (incl. Larian's still-live BG3 FAQ) is **stale**. Native arm64
  Steam lobbies are viable.
- **Steamworks.NET trap:** the mod ships the **Windows x64** build (PDB path proves it) which sets
  callback struct packing to Windows `Pack=8`; macOS/Linux needs `Pack=4`. Just renaming the dylib
  would load and **silently corrupt every callback**. Must **recompile Steamworks.NET with
  `STEAMWORKS_LIN_OSX`** (it's MIT and **not strong-named** — verified — so a rebuilt DLL drops in
  cleanly). One caveat to test at runtime: `libsteamwebrtc.dylib` is x86_64-only, so direct P2P
  may fall back to SDR relay.

---

## 3. Blocker map (with current status)

| # | Blocker | Severity | Status / fix |
|---|---|---|---|
| **B1** | MonoMod picks x86 detour platform (ARM bit) | — | **Non-issue** — BepInEx sets ARM; and we set `DetourHelper.Native` directly, bypassing selection |
| **B2** | Harmony detours die under Mono `MAP_JIT` W^X | 🔴→✅ | **SOLVED** — `tools/bepinex-applesilicon/` (native `as_jit_write` + Doorstop shim) |
| **B3** | Steamworks.NET is the Windows build (wrong packing) | 🟠 | Recompile w/ `STEAMWORKS_LIN_OSX`, `Pack=4`. MIT, not strong-named |
| **B4** | `steam_api64.dll` → needs `libsteam_api.dylib` | 🟡 | Drop in universal SDK ≥1.52 dylib |
| **B5** | `opus.dll` → needs `libopus.dylib` | 🟢 | arm64 dylib already present (brew); ship a copy |
| **B6** | `user32!SetWindowText` P/Invoke | ✅ | **Dissolved** — self-guarding, no-ops on macOS |
| **B7** | Mic without `NSMicrophoneUsageDescription` → TCC kill | 🟡 | Add the Info.plist key + re-sign |
| **B8** | Auto-updater overwrites adapted files | 🟡 | Remove `Multiupdater.dll` + `autoupdater_patcher.dll` |
| **B9** | `port.sh` strips `Plugins/x86_64` + re-signs whole bundle | 🟢 | Install mod **after** `port.sh`, then re-sign |
| **B10** | RMB/MMB inputs vs our trackpad rebind | 🟢 | `keybinds.json` is data-driven; ship a Mac preset (see [`port-7.0.md`](port-7.0.md)) |
| **B11** | Game-hash uses `Application.dataPath/Managed` (empty on macOS) | 🟠 | Symlink `Contents/Managed → Resources/Data/Managed` |

---

## 4. Repository layout decision — one repo, two clear concerns

Both the native port and the mod-port live in **this** repo. Rationale:

- The **mod installer** (`tools/mp-install.sh`, to build) is tightly coupled to `port.sh`: it runs
  as a post-step, depends on the bundle layout, the signing step, and the `Contents/Resources/Data`
  symlink pattern. Split out, it becomes a satellite that breaks whenever `port.sh` changes and
  can't be tested without this repo checked out beside it. The port and its mod adapter share a
  failure surface (a game-version bump touches both) — keep them together.
- The **generic BepInEx fix** (`tools/bepinex-applesilicon/`) is the one piece with a life of its
  own — it unlocks BepInEx for *any* arm64 Mono Unity game. It **incubates here** (against a target
  we can actually test end-to-end) and gets **extracted to its own repo once it has a
  one-command installer** and a proven "it works" story. Extracting now would mean maintaining a
  repo boundary around code that only just started working.

Tidiness rules that keep the two concerns legible:
- Port machinery stays where it is (`tools/port.sh`, `transplant.sh`, `rewrap/`, `hlslcc/`, …).
- Everything mod-related is namespaced: `tools/bepinex-applesilicon/` (generic fix) and the future
  `tools/mp-install.sh` (Casualties-specific glue), plus this doc.
- **Copyrighted inputs are gitignored** and never committed: the game (`CasualtiesUnknownDemo/`),
  `casualties-together/`, the mod payload (`KrokMP*/`), and `BepInEx_win_x64_5/`. Built artifacts
  (`tools/bepinex-applesilicon/dist/`, `bin/`, `obj/`) are gitignored too — source is committed,
  each user rebuilds.

---

## 5. What still needs to be done (phased)

### Phase 1 — native arm64, direct-IP multiplayer + voice (no Steam)
The first genuinely playable milestone. Everything here is proven-possible.
1. **`tools/mp-install.sh`** (the main deliverable) — takes a ported `.app` + the user's KrokMP
   download and, as a post-`port.sh` step:
   - lay down macOS-universal BepInEx 5.4.23.x + the `tools/bepinex-applesilicon/` artifacts into
     `BepInEx/core`, and rewrite the launcher's `DOORSTOP_TARGET_ASSEMBLY` to the shim (B2);
   - copy the mod's AnyCPU plugins into `BepInEx/plugins/KrokMP`;
   - swap natives: `libopus.dylib` (B5), and the recompiled `Steamworks.NET.dll` (B3) even for the
     no-Steam path, since `Packsize.Test()` runs regardless;
   - strip `Multiupdater.dll` + `autoupdater_patcher.dll` (B8);
   - add `NSMicrophoneUsageDescription` to Info.plist (B7);
   - add the `Contents/Managed → Resources/Data/Managed` symlink (B11);
   - ship a Mac `keybinds.json` preset (B10);
   - re-sign the bundle ad-hoc (B9).
2. **Exercise the real mod**, not just the self-test: install KrokMP into the harness and confirm
   all 67 of its Harmony patch classes apply under the fix (they target classes present in our
   `Assembly-CSharp.dll` — 66/67 confirmed, the 1 miss being a name-extraction artifact).
3. **Direct-IP smoke test:** host on the Mac, connect a second client, verify a session.

### Phase 2 — Steam lobbies
4. Recompile Steamworks.NET (`STEAMWORKS_LIN_OSX`) at the mod's version and drop in universal
   `libsteam_api.dylib` (B3/B4). Verify `SteamAPI.InitEx` succeeds and lobbies list/join.
5. **Cross-play with Windows players** (LiteNetLib wire protocol is arch-neutral; game-hash matches
   per B11). Test relay-vs-direct P2P given the `libsteamwebrtc` x86_64-only caveat.

### Phase 3 — polish / extract
6. Fold `tools/bepinex-applesilicon/install.sh` in, then **extract `bepinex-applesilicon` to its
   own repo** as a general-purpose arm64 BepInEx enabler.
7. Reach out to Krokosha666 — upstream cooperation turns a private patch-shim into a real macOS
   target (and could grant redistribution).

---

## 6. Reproduction & environment notes

- **Toolchain installed** (reversible): `brew install dotnet` (SDK 10) + `dotnet tool install -g
  ilspycmd`; `clang` from Xcode CLT. Uninstall via `brew uninstall dotnet` /
  `dotnet tool uninstall -g ilspycmd`.
- **Decompile the mod:** `ilspycmd KrokoshaCasualtiesMP.dll -o out -r <refs>` with the port's
  `Managed/` + BepInEx `core/` as `-r` reference dirs (drop `opus.dll`/`steam_api64.dll` from refs —
  they're native and confuse the resolver).
- **Build + test the arm64 fix:** `tools/bepinex-applesilicon/build.sh --core <BepInEx/core>` then
  `tools/bepinex-applesilicon/test/run-harness.sh --app <Game.app> --dist ./dist`. PASS =
  `Chainloader startup complete` on a forced-`arch -arm64` run, no `preloader_*.log` crash.
- **Port target:** Unity **2022.3.62f3**, Mono (`libmonobdwgc-2.0.dylib`), ad-hoc signed, bundle id
  `com.orsoniks.casualtiesunknown.metal`, version stamped **7.0.1** (matches the mod's target).
