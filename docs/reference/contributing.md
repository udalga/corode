# Working on Corode

Corode's source lives in this repository as `.luau` files. [Rojo](https://rojo.space) syncs them into Studio, so the files are the source of truth.

## Layout

| Path | What it is |
| --- | --- |
| `src/Corode/` | The framework. `init.luau` is the `Corode` ModuleScript, every other file is a child of it. |
| `src/Corode/ClientBoot.server.luau` | A Script whose `RunContext` is set to `Client` by `ClientBoot.meta.json`, so it runs on every device from ReplicatedStorage. |
| `tests/` | The test runner and specs, synced to `ServerStorage.CorodeTests`. |
| `default.project.json` | Builds Corode as a model (`Corode.rbxm`). |
| `place.project.json` | Syncs Corode and the tests into a place while you work. Local scripts in `examples/` (kept out of git) are synced too when they exist. |
| `docs/` | This site. `docs/api/` is generated, so don't edit it by hand. |

## Set up

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in the repository. That installs the Rojo version pinned in `rokit.toml`.
2. Install the Rojo plugin in Studio with `rojo plugin install`.
3. Run `rojo serve place.project.json`, open your place in Studio and click **Connect** in the Rojo plugin.

From now on, edit the `.luau` files. Rojo updates Studio as you save. Changes made inside Studio to synced scripts are overwritten, so make them in the files instead.

Rojo only manages what is listed in `place.project.json`. Your Workspace parts, the NPC templates in ServerStorage and everything else in the place are left alone.

## Tests

The tests live in `tests/` and sync to `ServerStorage.CorodeTests`. `tests/Runner.luau` is a small Jest-style runner with no dependencies:

```lua
return function(t)
	t.describe("Format", function()
		t.it("shortens numbers", function()
			t.expect(K.Format.Short(1500)).toBe("1.5K")
		end)
	end)
end
```

Each `*.spec.luau` file returns a function like this. Matchers: `toBe`, `toEqual`, `toBeNil`, `toBeTruthy`, `toBeFalsy`, `toContain`, `toBeCloseTo`, `toThrow`, plus `.never` for the opposite. `t.beforeEach`, `t.afterEach` and `t.skip(reason)` work too.

**Running them.** Press Play, then in the server's command bar (Test → Current: Server):

```lua
game.ServerStorage.CorodeTests:SetAttribute("RunRequest", tostring(os.clock()) .. "|")
```

The summary appears in the Output and in the folder's `RunResult` attribute. Put a filter after the `|` (like `"1|Economy"`) to run only matching specs.

Why the attribute? The command bar has its own copy of every module, so `require(Corode)` there gets a Corode that never started. `tests/TestHook.server.luau` (synced as `ServerScriptService.CorodeTestHook`) runs the tests inside the game instead, with the real players. It does nothing outside Studio.

**On every push.** GitHub Actions runs the tests on Roblox's own servers through [Open Cloud Luau execution](https://create.roblox.com/docs/cloud/reference/features/luau-execution). It builds `tests.project.json` (this commit's Corode plus the tests) into a model, sends it as the task's binary input, and `scripts/cloud-test-task.luau` swaps it into the place for that task only. Nothing is published and the place never changes. There are no players there, so tests that need one are skipped; run those in Studio.

To turn it on once:

1. In the [Creator Dashboard](https://create.roblox.com/dashboard/credentials), create an API key named "Corode CI".
2. Under **Access Permissions**, add **luau-execution-sessions**, pick the Corode experience and allow **Write**. Nothing else is needed.
3. Under **Security**, add `0.0.0.0/0` to the IP addresses, since GitHub's runners change addresses.
4. Save the key as the repository secret `ROBLOX_API_KEY` (GitHub → Settings → Secrets and variables → Actions).

Until the secret exists, the test job just notes that it was skipped. A release is only made when the tests didn't fail.

To run them from your own computer instead:

```sh
rojo build tests.project.json -o CorodeCI.rbxm
ROBLOX_API_KEY=... ROBLOX_UNIVERSE_ID=10773475257 ROBLOX_PLACE_ID=132170386245225 node scripts/run-cloud-tests.mjs CorodeCI.rbxm
```

**Writing them.** Corode's definitions are global and can't be undone, so:

- Name everything with `Helpers.unique("Coins")`, which never repeats.
- Define currencies and inventories with `Saved = false`, so tests never change saved player data.
- Get a player with `Helpers.player(t)`. Tests that need one are skipped when nobody is in the game.

## Build a model

```sh
rojo build default.project.json -o Corode.rbxm
```

Drag `Corode.rbxm` into ReplicatedStorage in any place to use Corode there.

## Releases

Push a tag like `v0.11.0`. GitHub Actions builds `Corode.rbxm` and attaches it to a GitHub release. Bump `Version` in `src/Corode/init.luau` first so the two match.

## Documentation

```sh
npm install
npm run docs:dev
```

The guide pages are in `docs/guide`, `docs/systems`, `docs/platform`, `docs/client` and `docs/reference`. The API reference is generated from each module's header comment and the comments above its public functions, so improving those comments improves the reference too.
