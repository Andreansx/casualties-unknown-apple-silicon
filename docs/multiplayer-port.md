# Porting *Casualties: Together* (co-op mod) to the native arm64 Metal build

**Goal:** let people running our **native Apple Silicon / Metal port** play online co-op via the
community mod **Casualties: Together** (KrokMP) — **without Rosetta**, because Rosetta throws away
the port's whole reason to exist (native gameplay draws ~47% less power than the Wine/D3DMetal
path; see [`port-7.0.md`](port-7.0.md) and the power memory).

**Status in one line:** **Phase 1 is DONE** — the mod loads, all its Harmony patches apply, and a
real co-op session runs between two native arm64 instances over direct IP. What is left is Steam
lobbies (Phase 2) and on-screen QA.

This document is the durable state so a fresh session can pick up any single thread. It records
what the mod *is*, what was proven, the full blocker map with per-item status, the repo-layout
decision, and the phased to-do.

---

## 0. TL;DR status board

| Area | Status |
|---|---|
| Mod code portability (is the DLL arch-neutral?) | ✅ **Yes** — all managed assemblies are AnyCPU MSIL; nothing to recompile |
| BepInEx/Harmony on native arm64 (the hard blocker) | ✅ **SOLVED** (spike passed, reproducible) — `tools/bepinex-applesilicon/` |
| **The mod itself running** | ✅ **LOADS + all 225 `[HarmonyPatch]`es apply**, transpilers included, 0 errors |
| **Direct-IP co-op session** | ✅ **VERIFIED** — two native arm64 instances: join → seed sync → spawn |
| One-command installer (`tools/mp-install.sh`) | ✅ **built**, and `--uninstall` reverses it |
| Opus voice codec | ✅ arm64 `libopus.dylib` installed into `Contents/PlugIns` (voice itself is untested) |
| Microphone permission | ✅ `NSMicrophoneUsageDescription` added by the installer |
| Auto-updater | ✅ patcher dropped, `Multiupdater.dll` **kept** — see B8, the earlier plan was wrong |
| Game-hash gate | ✅ **proven by negative control**; it is mandatory for ANY connection, not just cross-play |
| Steam lobbies on arm64 | 🔵 Possible (universal `libsteam_api.dylib`), **deferred to Phase 2** (direct-IP works without it) |
| Steamworks.NET | 🟠 must **recompile** with `STEAMWORKS_LIN_OSX` (packing differs) — Phase 2 |
| On-screen co-op (mod UI + joining with graphics) | ✅ **VERIFIED on a real display** — mod menu renders, session plays; one intermittent IMGUI race found (§2f) |
| Voice chat / chat / B10 input | ⬜ needs a human at the keyboard (mic TCC prompt, push-to-talk, MMB bind) |

Legend: ✅ done · 🟢 trivial/have-it · 🟡 easy fix · 🟠 real work · 🔵 optional/later · ⬜ to do.

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

## 2. What was accomplished

### 2a. Behavioural analysis of the mod (decompiled to C#) — 2026-07-17

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

### 2b. The BepInEx-on-arm64 spike — SOLVED (2026-07-17)

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

### 2c. Steam / networking research (external) — 2026-07-17

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

### 2d. Phase 1 executed — the mod actually runs (2026-07-18)

`tools/mp-install.sh` was built and the whole path verified **headlessly** (no display needed —
everything below is from `-batchmode -nographics` runs and their logs).

**Install layout — BepInEx goes INSIDE the bundle.** `BepInEx.Preloader.PreloaderRunner` derives
its root from the *invoked assembly*, not the executable:
`bepinRootPath = Utility.ParentDirectory(DOORSTOP_INVOKE_DLL_PATH, 2)`. Our Doorstop target is
`<app>/Contents/BepInEx/core/AppleSiliconShim.dll`, so the root resolves to `<app>/Contents/BepInEx`
and the `.app` stays one self-contained, movable unit (no `BepInEx/` litter next to it, which is
what the upstream macOS layout would give). Confirmed working end-to-end.

The one cost of that choice, stated plainly: BepInEx writes its log/config/cache back inside the
bundle, so after the first modded launch `codesign --verify --deep --strict` reports *"a sealed
resource is missing or invalid"*. That is cosmetic **for this app**: the kernel validates the main
Mach-O (untouched) and Gatekeeper only re-checks the resource envelope for quarantined apps, which
a locally built ad-hoc-signed `.app` never is. Verified by repeated launches with the seal broken.
If the port ever needs to survive notarisation, move `BepInEx/` next to the `.app` instead — that
is the only reason to prefer the upstream layout.

**The mod loads and every patch applies.** BepInEx reports `2 plugins to load`, then
`Plugin KrokoshaCasualtiesMP version 4.0.1 is loaded!`. That line is decisive: in the decompile it
is only reached *after* `harmony.PatchAll()` + `ExtraPatches.ApplyPatches()` return, both inside a
try/catch whose failure branch logs `failed to load!` and bails instead. So all **225
`[HarmonyPatch]` attributes** applied on native arm64. The client log also shows the mod's
**transpilers** succeeding by name (`Body.Attack`, `TurretScript Shoot`, `BuildingEntity Update`,
`DamagingCrate OnCollisionEnter2D`) — real IL rewriting, not just simple prefix/postfix detours.
Zero errors in the BepInEx log; zero managed exceptions in the Unity log.

Also confirmed incidentally: `Application.version` reads `7.0.1`, so the mod's
`if (Application.version != "7.0.1")` version gate passes — that is `port.sh` step 5's
`CFBundleShortVersionString` stamp paying off.

**A real co-op session runs.** Host + client, two native arm64 instances on one Mac:

```
HOST   SERVER: SENDING CHAT ANNOUNCEMENT: MacClient just joined the game!
HOST   SERVER: Sending a spawn location for PB(ID:1, name:MacClient) to (0.00, 486.62, 0.00)
CLIENT Multiplayer: Connected!  :)
CLIENT Multiplayer: GenerateWorld_SeedAnnounce, received worldgen seed.
CLIENT CLIENT: Received starter char state packet, that im applying just now. POS: (0.00, 486.61)
CLIENT Creating other player characters!
```

**B11 proven by negative control, and it is stronger than we thought.** With
`Contents/Managed` renamed away, the client logs
`GAME HASH CALCULATION: Assembly-CSharp.dll DOES NOT EXIST????` and is then met with
`Connection Rejected: Game file Hashes mismatch.` Restore the symlink and the same session joins
fine. So the hash gate is **on by default** — without that one symlink a Mac client cannot connect
to *any* server, Mac or Windows. It is not merely a cross-play nicety.

### 2e. Two upstream quirks found while testing (neither is a port defect)

- **`--ksmulti-startclient` cannot connect — on any platform.** The CLI auto-connect path passes a
  hardcoded literal `"localhost:7790"` (verified: the UTF-16 string is in the DLL; `--ksmulti-ip-port`
  only feeds the *UI* path). `Net.TryParseIPPORT` decides IPv4-vs-IPv6 by asking whether a `.`
  appears before the `:` — `"localhost:7790"` has no dot, so it takes the IPv6 branch and hands the
  **whole string, port included**, to LiteNetLib as the host. `NetUtils.ResolveAddress` then calls
  `Dns.GetHostEntry("localhost:7790")`, which throws, and `NetManager.Connect` swallows it into
  `DisconnectReason.UnknownHost` → the mod prints `Multiplayer: Unknown Host`. A dotted IPv4 typed
  into the Direct Connect UI parses correctly, so this only bites the CLI shortcut.
  **Workaround for headless testing:** drive the mod's own console instead —
  `--ksmulti-runcommand "connect 127.0.0.1:7790"` (its `connect` command assigns `INPUT_IPPORT`
  directly). Host/dedicated-server flags are unaffected: those only use the *port*, so the same
  mis-parse is invisible there.
- **The mod re-enables `Application.runInBackground`** (`= network_system_is_running ||
  !IsWorldGenerated() || UIMainMenu.IsOpen()`), which is exactly the setting `port.sh` turns **off**
  in `globalgamemanagers` to fix the screen-lock wedge (Metal loop driven against a sleeping display
  with no acquirable drawable → hard hang). Co-op genuinely needs it — a client that pauses on focus
  loss would desync and time out — so this is a **real trade-off, not a bug to patch out**: while a
  session is live, expect the pre-fix screen-lock behaviour. Don't let the display sleep mid-session.

### 2f. On-screen QA — co-op plays with graphics (2026-07-18)

Ran the installed `.app` on a real display (the same day, right after §2d):

- **The mod's UI renders correctly on the native Metal port.** Main menu shows
  `CO-OP MOD v4.0.1 "RELEASE BUILD"`, the status line, the green `MP MOD` badge and the
  **Open Multiplayer Mod Menu** button, over the normal game art. Nothing pink, nothing missing.
- **A full co-op session runs on-screen**, headless host + GUI client: connect → worldgen from the
  server's seed → `Received location for WorldPlacePlayer` → `Creating other player characters!`.
  Reproduced across separate launches.
- **`-screen-fullscreen 0` is ignored** — the game's own saved display setting wins, so a QA launch
  takes over the whole screen. Budget for that when testing on someone's working machine.
- ⚠️ **Intermittent IMGUI race in the mod's player-list UI (1 of 3 valid joins).** On one join:
  ```
  MAIN MENU UI: UnityEngine.ExitGUIException: GUILayout: Mismatched LayoutGroup.repaint
    at UnityEngine.GUILayout.BeginVertical (…)
    at KrokoshaCasualtiesMP.UIMainMenu._GUI_DrawSideMenuWithPlayerList ()
    at KrokoshaCasualtiesMP.UIBullshit.__GUI__AllTheMenus ()
  GUI Error: You are pushing more GUIClips than you are popping. Make sure they are balanced.
  ```
  ~1 s later, at the world scene change, the client shut down **cleanly** (`Plugin.OnDestroy()` →
  `Can't add component to object that is being destroyed.` → Unity's normal shutdown dump — no
  crash report, no signal). Cause is almost certainly LiteNetLib's async player-list callbacks
  mutating the list *between* IMGUI's Layout and Repaint passes, which is what
  `Mismatched LayoutGroup.repaint` means. **Nothing ported is implicated** — the stack is pure
  `UnityEngine.GUILayout` plus the mod's own UI code, so this should reproduce on Windows; worth
  confirming there before reporting it upstream. Causation between the exception and the quit is
  *not* proven, only correlation in the one failing run.
  (A separate "failure" while measuring turned out to be my own doing: `Connection Rejected: Player
  with this name already exists` — the previous instance had not timed out on the host yet.)

**Still not exercised on-screen:** voice chat (the mic TCC prompt has to be clicked by a human, and
push-to-talk needs a real keypress), chat, and the B10 input pass (`krokosha_coop_pointfingerat`
defaults to MMB, which a trackpad cannot produce).

---

## 3. Blocker map (with current status)

| # | Blocker | Severity | Status / fix |
|---|---|---|---|
| **B1** | MonoMod picks x86 detour platform (ARM bit) | — | **Non-issue** — BepInEx sets ARM; and we set `DetourHelper.Native` directly, bypassing selection |
| **B2** | Harmony detours die under Mono `MAP_JIT` W^X | 🔴→✅ | **SOLVED** — `tools/bepinex-applesilicon/` (native `as_jit_write` + Doorstop shim) |
| **B3** | Steamworks.NET is the Windows build (wrong packing) | 🟠 | Phase 2: recompile w/ `STEAMWORKS_LIN_OSX`, `Pack=4`. MIT, not strong-named. **Until then the launcher forces `--ksmulti-nosteam`** — `DllCheck.Test()` would P/Invoke kernel32 and throw, and `KSteam.CheckSteam()` does not catch that |
| **B4** | `steam_api64.dll` → needs `libsteam_api.dylib` | 🟡 | Phase 2: drop in universal SDK ≥1.52 dylib. Not installed today |
| **B5** | `opus.dll` → needs `libopus.dylib` | ✅ | **DONE** — installer copies brew's arm64 dylib to `Contents/PlugIns`; `OpusSharp` imports plain `"opus"`, which Mono maps to `libopus.dylib`. Voice not yet exercised for real |
| **B6** | `user32!SetWindowText` P/Invoke | ✅ | **Dissolved** — self-guarding, no-ops on macOS |
| **B7** | Mic without `NSMicrophoneUsageDescription` → TCC kill | ✅ | **DONE** — installer adds the key, then re-signs |
| **B8** | Auto-updater overwrites adapted files | ✅ | **DONE, but not as first planned:** drop `autoupdater_patcher.dll` only. It is the patcher that clones a staged update over `Environment.CurrentDirectory`. **Keep `Multiupdater.dll`** — the mod's own settings GUI calls `Multiupdater.AutoUpdater` (`DrawUpdateButton`), so deleting it throws `TypeLoadException` inside `OnGUI`. With the patcher gone a staged update is simply never applied |
| **B9** | `port.sh` strips `Plugins/x86_64` + re-signs whole bundle | ✅ | Install mod **after** `port.sh`; `mp-install.sh` re-signs at the end. Re-run it after every rebuild |
| **B10** | RMB/MMB inputs vs our trackpad rebind | 🟡 | Open. The mod's own binds land in `settings.json` automatically; `krokosha_coop_pointfingerat` defaults to **Mouse2 (MMB)**, which a trackpad cannot produce — needs an on-screen pass to pick sane Mac defaults |
| **B11** | Game-hash uses `Application.dataPath/Managed` (empty on macOS) | ✅ | **DONE + PROVEN** by negative control (§2d). Mandatory for *any* connection, not just cross-play |

---

## 4. Repository layout decision — one repo, two clear concerns

Both the native port and the mod-port live in **this** repo. Rationale:

- The **mod installer** (`tools/mp-install.sh`) is tightly coupled to `port.sh`: it runs
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
- Everything mod-related is namespaced: `tools/bepinex-applesilicon/` (generic fix) and
  `tools/mp-install.sh` (Casualties-specific glue), plus this doc.
- **Copyrighted inputs are gitignored** and never committed: the game (`CasualtiesUnknownDemo/`),
  `casualties-together/`, the mod payload (`KrokMP*/`), and `BepInEx_win_x64_5/`. Built artifacts
  (`tools/bepinex-applesilicon/dist/`, `bin/`, `obj/`) are gitignored too — source is committed,
  each user rebuilds.

---

## 5. What still needs to be done (phased)

### Phase 1 — native arm64, direct-IP multiplayer ✅ DONE (2026-07-18)
1. ✅ **`tools/mp-install.sh`** — one command, `--uninstall` reverses it. See §2d for the layout
   decision and the header of the script for the per-step reasoning.
2. ✅ **The real mod exercised**, not just the self-test: 225 `[HarmonyPatch]`es apply, transpilers
   included.
3. ✅ **Direct-IP session verified** between two native instances (join → seed sync → spawn).

**Left over from Phase 1 — needs a display (nothing here is known-broken, just unobserved):**
- Play a session on-screen: menus, the MP button, chat, the player list, HUD.
- **Voice chat** end-to-end (the TCC prompt fires on first mic use — it cannot be answered headlessly).
- **B10 input pass:** `krokosha_coop_pointfingerat` defaults to MMB, unreachable on a trackpad.
- Sanity-check the screen-lock trade-off documented in §2e.

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
  `dotnet tool uninstall -g ilspycmd`. `ilspycmd` needs
  `export DOTNET_ROOT=/opt/homebrew/opt/dotnet/libexec PATH="$HOME/.dotnet/tools:$PATH"` — without
  `DOTNET_ROOT` it just prints *"You must install .NET to run this application."*
- **Install the mod:** `tools/mp-install.sh --app <CU.app> --mod <KrokMP download dir|zip>`.
  BepInEx is fetched to `~/.cache/casualties-port/` on first use
  (`BepInEx_macos_universal_5.4.23.5.zip` — the **macos_universal** asset; there is no
  `unix_x64` one, and the mod's own INSTALLATION.txt points at the Windows build).
- **Headless co-op test** (no display needed), two instances of the installed `.app`
  (the second can be a cheap APFS clone — `cp -a`, the launcher is self-locating):
  ```sh
  Game.app/Contents/MacOS/coop-launch  -batchmode -nographics -logFile host.log \
      --ksmulti-setname MacHost --ksmulti-starthost --ksmulti-immidiate-start
  Game2.app/Contents/MacOS/coop-launch -batchmode -nographics -logFile client.log \
      --ksmulti-setname MacClient --ksmulti-runcommand "connect 127.0.0.1:7790"
  ```
  Use `--ksmulti-runcommand "connect …"`, **not** `--ksmulti-startclient` (§2e: it is broken
  upstream). Read the result from `<app>/Contents/BepInEx/LogOutput.log`, not the Unity log —
  the mod logs through BepInEx.
- **Decompile the mod:** `ilspycmd KrokoshaCasualtiesMP.dll -o out -r <refs>` with the port's
  `Managed/` + BepInEx `core/` as `-r` reference dirs (drop `opus.dll`/`steam_api64.dll` from refs —
  they're native and confuse the resolver).
- **Build + test the arm64 fix:** `tools/bepinex-applesilicon/build.sh --core <BepInEx/core>` then
  `tools/bepinex-applesilicon/test/run-harness.sh --app <Game.app> --dist ./dist`. PASS =
  `Chainloader startup complete` on a forced-`arch -arm64` run, no `preloader_*.log` crash.
- **Port target:** Unity **2022.3.62f3**, Mono (`libmonobdwgc-2.0.dylib`), ad-hoc signed, bundle id
  `com.orsoniks.casualtiesunknown.metal`, version stamped **7.0.1** (matches the mod's target).
