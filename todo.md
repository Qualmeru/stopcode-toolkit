# TODO

## High priority

- [x] Add focused tests for the dump parsers, covering valid headers and truncated or malformed input. Use small synthetic fixtures rather than committing real dumps.
- [x] Run the test suite before each Git commit, blocking the commit if tests fail or a suitable Python is unavailable.
- [x] Confirm the GitHub Actions test workflow succeeds after it is pushed.
- [ ] Smoke-test setup on a clean Windows 10/11 machine with Windows PowerShell 5.1. Verify the scheduled tasks install, run, report their status, and uninstall as documented.
  - Checked script syntax and mocked the install/start/status/uninstall flows locally; a real clean-machine test is still needed.

## Gaming mode

- [x] Discover all installed Steam games from `appmanifest_*.acf` files, not only the hand-written profiles (`-Games`, `-Game <name|key|appid>`).
- [x] Add `-HighPriority` to set a running game to High priority, or after `-Launch`. It matches every process running from the game's install folder.
- [x] Test `-HighPriority` against a stand-in game process: Normal -> High, `-WhatIf` changes nothing, and lookup by Steam app id works.
- [x] Test waiting for a delayed game start: a simulated launcher started the game after 5 s and it was set to High within the wait window.
- [x] Make a plain `-Game <name>` run set the game to High priority too: right away if it is running, after `-Launch` once it starts. Add `-NoHighPriority` to opt out.
- [x] Test `-Game witcher3` with a stand-in process in the Witcher 3 folder: not running shows a hint, `-WhatIf` reports WOULD SET and leaves it Normal, a real run sets it to High, and `-NoHighPriority` skips the step.
- [ ] Confirm `-Game <name> -Launch` with a real Steam game, including games that relaunch through Steam or hand off from a launcher.
- [x] Add a Steam game picker to the Control Panel, with **Launch at High priority** (through Steam) and **Set High priority**. The game list loads in the background and the last game chosen is remembered.
- [x] Test the panel's game features: the list matches `-Games -AsJson`, the XAML loads, a stand-in game that started 5 s late was raised to High, and a game that never starts times out with a warning.
- [x] Fix tool folders being treated as games: Skyrim SE was listed only because the Creation Kit shares its folder, and launching it would have opened the Creation Kit.
- [ ] Click through the Control Panel game row by hand with a real game: dropdown look, launch through Steam, priority shown in Task Manager.
- [ ] Add commit-size profiles for games found through Steam that show `?` in `-Games`.

## Follow-up

- [ ] Verify which scripts require elevation and that each reports or requests it as documented; include unelevated and elevated checks in the setup validation.
- [ ] Review machine-specific process recommendations and vendor notes, and make sure users can identify what they should customize before relying on them.
- [ ] Check that monitoring and diagnostic outputs stay within `diag\` and that the documented removal steps leave no scheduled tasks or shortcuts behind.
