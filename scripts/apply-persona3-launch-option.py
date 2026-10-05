#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / "Madeira"

def replace_once(path, old, new):
    p = MADEIRA / path
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}")
    p.write_text(text.replace(old, new, 1))
    print(f"patched {path}")

# Preserve the numeric config.launch key.
replace_once(
    "app/Madeira/SwiftSteam/Library/SteamAppInfo.swift",
    '''    var osarch = ""
    var betaKey = ""

    /// Entries in Steam's order (numeric keys), without those that name no
''',
    '''    var osarch = ""
    var betaKey = ""
    /// Numeric config.launch key Valve's client expects in LaunchApp.
    /// Optional so launch options cached by older Madeira builds still decode.
    var index: Int? = nil

    /// Entries in Steam's order (numeric keys), without those that name no
'''
)
replace_once(
    "app/Madeira/SwiftSteam/Library/SteamAppInfo.swift",
    "        for (_, key) in keys.prefix(32) {",
    "        for (numericKey, key) in keys.prefix(32) {"
)
replace_once(
    "app/Madeira/SwiftSteam/Library/SteamAppInfo.swift",
    '''            options.append(SteamLaunchOption(executable: executable, arguments: arguments, workingDir: workingDir,
                                             type: type, oslist: oslist, osarch: osarch, betaKey: betaKey))
''',
    '''            options.append(SteamLaunchOption(executable: executable, arguments: arguments, workingDir: workingDir,
                                             type: type, oslist: oslist, osarch: osarch, betaKey: betaKey,
                                             index: numericKey))
'''
)

# Carry the key through Madeira's existing launch-choice logic.
replace_once(
    "app/Madeira/SteamGames.swift",
    '''    struct Choice: Equatable {
        var program: String
        var arguments: String
        var folder: String?
    }
''',
    '''    struct Choice: Equatable {
        var program: String
        var arguments: String
        var folder: String?
        /// Steam config.launch key for this exact program, when it came from
        /// product info. Madeira Dock passes this to Valve's LaunchApp.
        var launchIndex: Int? = nil
    }
'''
)
replace_once(
    "app/Madeira/SteamGames.swift",
    '''            return Choice(program: program, arguments: option.arguments.trimmingCharacters(in: spaces), folder: folder)
''',
    '''            return Choice(program: program, arguments: option.arguments.trimmingCharacters(in: spaces),
                          folder: folder, launchIndex: option.index)
'''
)

# Older caches lack the new index; refresh their PICS launch data once.
replace_once(
    "app/Madeira/SteamOwnedLibrary.swift",
    '''    func launchOptions(appID: Int) async -> [SteamLaunchOption]? {
        if let cached = game(appID)?.launches { return cached }
''',
    '''    func launchOptions(appID: Int) async -> [SteamLaunchOption]? {
        // Older cache files have launch entries but not their numeric config.launch
        // keys. Refresh those once so Dock can pass the real launch option to Steam.
        if let cached = game(appID)?.launches,
           cached.isEmpty || cached.allSatisfy({ $0.index != nil }) { return cached }
'''
)

# Export the selected launch key to Dock.
replace_once(
    "app/Madeira/MadeiraDock.swift",
    "    static func configure(_ game: DockGame) {",
    "    static func configure(_ game: DockGame, launchOption: Int? = nil) {"
)
replace_once(
    "app/Madeira/MadeiraDock.swift",
    '''        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\\\madeira-dock.txt", 1)
''',
    '''        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\\\madeira-dock.txt", 1)
        // LaunchApp's third argument is the numeric config.launch key, not an
        // array offset. Most games have key 0; some (Persona 3 Reload among them)
        // start at 1. Unset keeps Dock's historical option-0 fallback.
        if let launchOption, launchOption >= 0, UInt64(launchOption) <= UInt64(UInt32.max) {
            setenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION", String(launchOption), 1)
            SteamLog.event("[dock-launch] launch-option=\\(launchOption)")
        } else {
            unsetenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION")
        }
'''
)

# Resolve the option before the app's Steam connection is handed to Dock.
replace_once(
    "app/Madeira/ContentView.swift",
    '''        Task { @MainActor in
            await SteamOwnedLibrary.shared.prepareDock()
''',
    '''        Task { @MainActor in
            // Resolve the same Windows/default launch entry used by
            // "Start with: The game" while the app's Steam connection is still
            // available. Dock later passes its numeric config.launch key to Valve.
            // If metadata is unavailable, nil preserves the historical option-0
            // behaviour rather than blocking a game that used to launch.
            let launchOptions = await SteamOwnedLibrary.shared.launchOptions(appID: game.id)
            let installRoot = MadeiraDock.drive
                .appendingPathComponent(game.library, isDirectory: true)
                .appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(game.installDir, isDirectory: true)
            let launchOption = launchOptions.flatMap {
                SteamDirectStart.choose($0, installFolder: installRoot)?.launchIndex
            }
            await SteamOwnedLibrary.shared.prepareDock()
'''
)
replace_once(
    "app/Madeira/ContentView.swift",
    "            MadeiraDock.configure(game)\n",
    "            MadeiraDock.configure(game, launchOption: launchOption)\n"
)

# Patch Dock itself.
dock = MADEIRA / "madeira-dock/src/launch.c"
text = dock.read_text()
def dock_replace(old, new):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"madeira-dock/src/launch.c: expected one match, found {count}")
    text = text.replace(old, new, 1)

dock_replace(
    '''static bool method_is(HMODULE module, void *object, unsigned slot, uintptr_t rva)
{
    return dock_method_is((uintptr_t)module, object, slot, rva);
}

''',
    '''static bool method_is(HMODULE module, void *object, unsigned slot, uintptr_t rva)
{
    return dock_method_is((uintptr_t)module, object, slot, rva);
}

/* Steam's config.launch keys are numeric but need not start at zero. The app
 * selects the same Windows/default entry as its direct-start path and exports
 * that exact key. Missing/invalid keeps the historical option-0 behaviour. */
static uint32_t read_launch_option(const struct sh_observer *o)
{
    wchar_t text[16] = {0};
    DWORD length = GetEnvironmentVariableW(L"MADEIRA_STEAM_HOST_LAUNCH_OPTION", text, 16);
    if (!length) return 0;
    if (length >= 16) {
        o->event("launch-option-invalid", 1);
        return 0;
    }
    uint64_t value = 0;
    for (DWORD i = 0; i < length; ++i) {
        if (text[i] < L'0' || text[i] > L'9') {
            o->event("launch-option-invalid", 1);
            return 0;
        }
        value = value * 10 + (uint64_t)(text[i] - L'0');
        if (value > UINT32_MAX) {
            o->event("launch-option-invalid", 1);
            return 0;
        }
    }
    o->event("launch-option", value <= INT32_MAX ? (int32_t)value : -1);
    return (uint32_t)value;
}

'''
)
dock_replace(
    '''    uint64_t gameid = appid;
    uint64_t call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, 0, 0, "");
''',
    '''    uint64_t gameid = appid;
    uint32_t launch_option = read_launch_option(o);
    uint64_t call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, launch_option, 0, "");
'''
)
dock_replace(
    '''            call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, 0, 0, "");
''',
    '''            call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, launch_option, 0, "");
'''
)
dock.write_text(text)
print("patched madeira-dock/src/launch.c")

# Sanity checks aimed at P3R's exact failure.
appinfo = (MADEIRA / "app/Madeira/SwiftSteam/Library/SteamAppInfo.swift").read_text()
content = (MADEIRA / "app/Madeira/ContentView.swift").read_text()
dock_text = dock.read_text()
assert "var index: Int? = nil" in appinfo
assert "for (numericKey, key) in keys.prefix(32)" in appinfo
assert "launchOption: launchOption" in content
assert 'GetEnvironmentVariableW(L"MADEIRA_STEAM_HOST_LAUNCH_OPTION"' in dock_text
assert "manager, &gameid, launch_option, 0" in dock_text
print("Persona 3 launch-option patch applied successfully")
