# Frontier Map

A personal iOS app: a worldwide interactive map in an original hand-inked, parchment Western style, with GPS, compass, place search, saved waypoints, offline areas and a spoken "frontier guide".

The style is original and *inspired by* the look of Western game maps. It uses no Rockstar/Red Dead artwork, fonts, audio or character voices.

## Status: be clear about this

| | |
|---|---|
| Written | All Swift code, map style, unit tests, XcodeGen project spec, GitHub Actions build |
| Checked | The style JSON parses (24 layers). Nothing else. |
| **Not** compiled, run or tested | It was written on Windows with no Swift/Xcode. Your first CI run is the first compile. Expect to fix a small error or two from MapLibre API details. |

## What it does

- **World map**: MapLibre Native + MapTiler vector tiles (OpenStreetMap data) in a custom parchment style (`Sources/frontier-style.json`), with hillshading, inked shorelines and dashed borders and trails.
- **My location + compass**: the arrow button follows you with heading. The compass shows when the map is rotated.
- **Search**: type a place and press Search. Results use Apple's MapKit search (no extra key). Tap one to fly there.
- **Waypoints**: long-press the map to drop and name a pin. Pins are saved on your phone. Tap a pin, then ⓘ, and the guide speaks distance and direction. The Journal (book button) lists pins with "x miles northeast", and you swipe to delete one.
- **Directions**: tap 🚗 on a pin's popup or a search result, or tap a Journal waypoint. You get a dashed red trail, travel time, distance and arrival time, a Car/Walk switch and the list of turns. Tap **Start** to begin: the map zooms in and follows your direction of travel, a next-turn banner replaces the search bar, and the guide reads each turn aloud about 300 m ahead (50 m on foot) and says when you've arrived. The screen stays on while a route is active. Routes and ETAs come from Apple Maps (no extra key). Driving ETAs include current traffic, but traffic isn't drawn on the map.
- **Offline areas**: the download button saves what's on screen plus 3 zoom levels deeper. Delete saved areas from the Journal.
- **Frontier guide voice**: original lines ("Camp lies 3.2 miles northeast. Ride steady.") spoken by the built-in iOS voice with a lower, slower delivery. For a better voice, download an *Enhanced* English voice under iPhone Settings › Accessibility › Spoken Content › Voices.

## Accounts and services you need

| What | Cost | Why |
|---|---|---|
| [MapTiler](https://cloud.maptiler.com) account + API key | Free tier (monthly request cap) | Map tiles, hillshade, label fonts |
| GitHub account, **private** repo | Free; macOS minutes count 10× against your private-repo allowance | Builds the app on a Mac, since you only have Windows |
| Apple ID (free) | Free | Signing to install on your own iPhone |
| Optional: [Appetize.io](https://appetize.io) | Free tier | Runs the simulator build in your browser from Windows |
| Optional: Apple Developer Program | $99/yr | Apps stop expiring after 7 days, and you can use TestFlight |

## Configure the key (securely)

The key is **never** in source code. `Config/Base.xcconfig` holds only the placeholder `YOUR_MAPTILER_KEY`. The real value comes from either:

- **CI (your setup)**: GitHub repo › Settings › Secrets and variables › Actions › New secret named `MAPTILER_KEY`. The workflow writes it into `Config/Secrets.xcconfig` at build time.
- **A Mac, if you get one later**: `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and paste the key. That file is in `.gitignore`.

At runtime the app reads the key from Info.plist and injects it into the map style.

**Honest caveat:** any key shipped inside an app can be extracted from the app file by someone determined. For a personal app that's acceptable if you:
1. keep the repo and its build artifacts **private** (the `.ipa` and `.zip` contain the key);
2. use a dedicated key just for this app, and turn on any restrictions MapTiler offers for it;
3. watch usage in the MapTiler dashboard, and regenerate the key if it ever leaks.

If you skip the secret, the app still builds and shows "No MapTiler key set".

## Build (from Windows, via GitHub Actions)

1. Create a **private** GitHub repo and push this folder to it.
2. Add the `MAPTILER_KEY` secret (above).
3. The push triggers **Actions › iOS**, or you can run it manually. It:
   generates the Xcode project → runs the unit tests on a simulator → builds `FrontierMap-simulator.zip` and `FrontierMap-unsigned.ipa`.
4. Download the `FrontierMap-builds` artifact from the run page.

If the build fails, open the failed step's log and paste it to me.

## Test in a simulator (no Mac)

- **Appetize.io**: upload `FrontierMap-simulator.zip` and it runs in your browser. Note this uploads your key-containing build to a third party. To fake a location, use Appetize's location setting.
- **A cloud Mac** (e.g. MacinCloud), or any Mac: install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), add `Config/Secrets.xcconfig`, run `xcodegen generate`, open `FrontierMap.xcodeproj`, choose an iPhone simulator and press ⌘R. Fake GPS with Simulator › Features › Location › Custom Location. Tests run with ⌘U.

The simulator has no compass, so heading only works on a real phone.

## Install on your iPhone (from Windows)

1. Install Apple's **Apple Devices** app (or iTunes) from the Microsoft Store so Windows can see the phone.
2. Install [Sideloadly](https://sideloadly.io) (a third-party tool: it asks for your Apple ID, so consider a secondary Apple ID).
3. Plug in the iPhone, drag in `FrontierMap-unsigned.ipa` and sign in with your Apple ID. Sideloadly signs and installs it.
4. On the iPhone: Settings › Privacy & Security › **Developer Mode** › On (it restarts). Then Settings › General › VPN & Device Management › trust your Apple ID.
5. With a free Apple ID the app **expires after 7 days**. Re-sideload to renew it.

## Permissions

- **Location, When In Use**: asked the first time the map shows your location. It's used only on-device for the blue dot, heading and waypoint distances. There's no background tracking. If you deny it, the map and search still work, and the follow button tells you how to re-enable location.
- No microphone, contacts or photos access. Waypoints stay on the phone (UserDefaults) and aren't synced.

## Limitations

- **Global coverage**: the whole world is mapped, but detail depends on OpenStreetMap. Cities are rich, while rural areas and some countries are sparse. Labels show in Latin script (e.g. "Tokyo", not "東京").
- **Connectivity**: the map streams tiles and search needs internet. Places you've recently viewed stay in MapLibre's small automatic cache, but don't rely on that.
- **Offline**: only areas you explicitly saved work offline, and only down to the zoom you saved (max 15). Downloads count against your MapTiler quota. Large areas take many tiles, so save regions, not countries. Check MapTiler's terms for offline use on your plan. If you change the key, previously saved areas stop matching and must be re-saved. Search and the guide's directions don't need the map, but search does need a connection.
- **Directions**: needs a connection and your location. Apple routing doesn't cover every country, and you'll see "No trail found" where it doesn't. There's no automatic re-routing: if you go off course, tap Directions again. Turns are only spoken while the app is open on screen (no background navigation). Only car and walking are supported.
- **Look**: this is a styled vector map (parchment colors, inked lines, vignette), not hand-painted artwork. A closer "painted" look would need original illustrated textures and icons (`fill-pattern`, custom sprites), which you could add later.
- **Map style untested**: layer and field names follow the OpenMapTiles schema that MapTiler serves. If the hillshade source or a font name doesn't resolve, that layer simply won't draw.

## Project layout

```
project.yml                  XcodeGen spec (generates the .xcodeproj)
Config/Base.xcconfig         placeholder key + optional include of Secrets.xcconfig
Config/Secrets.example.xcconfig
Sources/FrontierMapApp.swift app entry
Sources/ContentView.swift    UI: search, buttons, naming alert, Journal sheet
Sources/MapView.swift        MapLibre map, style + key injection, pins, long-press
Sources/AppModel.swift       state: waypoints, search, follow, offline packs
Sources/Waypoints.swift      waypoint storage + bearing math
Sources/Guide.swift          frontier-guide speech
Sources/frontier-style.json  the Western map style
Tests/GeoTests.swift         unit tests for bearing, compass points, waypoint saving
.github/workflows/ios.yml    Mac build in CI
```
