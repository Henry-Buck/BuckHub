# BuckHub

- `BuckHub.lua` detects the current Roblox `PlaceId` and loads the matching entry from its raw GitHub URL.
- `Individual/GuessAndSlap.lua` is the standalone Guess & Slap script for PlaceId `100975894126710`.
- Before use, publish the individual file and replace the placeholder URL in `BuckHub.lua` with the file's raw GitHub URL.
- Run `BuckHub.lua` from a compatible client/executor that supports `loadstring`, `game:HttpGet`, and (for this module) `getgenv`.
