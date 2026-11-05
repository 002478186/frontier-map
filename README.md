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

**Map and search**
- **World map**: MapLibre Native + MapTiler vector tiles (OpenStreetMap data). Pick a style from the layers button: **Frontier** (the original hand-inked parchment style, `Sources/frontier-style.json`), **Modern** (MapTiler streets) or **Topo** (MapTiler outdoor: contours, hiking paths, peaks).
- **Night mode**: Auto (after sunset, or when the phone is in dark mode), Always or Never. The Frontier map gets a moonlit version made from the same style, and the controls go dark too.
- **Search with autocomplete**: suggestions as you type (addresses, businesses, categories like "coffee"), biased to where you are. With the box empty it shows **Home**, **Work** and your recent places.
- **Place details**: tap a result for its address, distance, **open now / closed** (with when it closes or opens, from OpenStreetMap hours), phone, website, Directions / Add stop / Save pin / Share, and Apple's own place card with opening hours, photos and ratings (iOS 18+).
- **Nearby finds**: chips find saloons, grub, stores, doctors, fuel, lodging and camps within 5 km.
- **Weather & daylight** chip ([Open-Meteo](https://open-meteo.com/), free, no key, non-commercial). Tap it and the guide reads it out.
- **Map furniture**: a white arrowhead turns with your heading; an engraved compass rose turns with the map (tap to face north).

**Navigation**
- **Car, Walk or Bike**, with **alternate routes** (each with its time and distance) and a **transit time** that opens in Apple Maps. Driving times include current traffic.
- **Start**: the map flies to you, tilts and follows. The turn banner shows the arrow, distance, your speed and the **posted speed limit** (OpenStreetMap, via the Overpass API); the guide warns you once if you're well over it. Turns are spoken ~300 m ahead (50 m on foot), including "take the bridge/flyover". It **re-routes** on its own, keeps talking with the **screen locked**, and **Re-center** brings you back if you pan away.
- **Road trips**: add stops from any place, or let the guide add fuel, food, coffee or a lookout near the halfway point. The Stops sheet shows arrival times at each stop and the whole day's estimate; swipe to remove, Edit to reorder.
- **Scenic route**: finds a park, beach or waterfront near the middle of the trip that adds at most 40% to the time, and offers it as another route.
- **Elevation profile** of the route, with total climb.
- **Off-grid**: with no road route (no signal, or nowhere near a road) you get a straight line and the guide calls the compass bearing and distance; it switches back to roads when it can. Save a Topo area for offline use before you go.
- **Share your ETA**, a place, or where you are. (A one-off message with the arrival time and a map link; live-updating ETA would need a server.)
- **Avoid tolls / highways** (layers sheet), applied to every route and to commute times.
- **Plain map while driving**: during car navigation the parchment map, fog and vignette give way to the clear street map; browsing and route preview keep the frontier look. Toggle in the layers sheet.
- **Favorites**: switch on Favorite in a pin's editor and it's one tap from the empty search box, next to Home and Work.
- **Leave-by alerts**: pick an arrival time and get "Leave by 8:12" on weekdays, ten minutes before you should go, from your Home pin to your Work pin using Apple's traffic forecast. Refreshed whenever you open or close the app.
- **Parking memory**: when a drive ends (any ride averaging over 25 km/h), a Parked car pin is dropped where it ended; the empty search box offers to walk you back.
- **Fuel and EV chargers along the route**: from the Stops sheet or by asking the guide.

**Ask the guide** (wand button): "plan a 3-hour drive with a lunch stop and a lookout point", "find a quiet coffee shop on my way to work". It builds the route with real stops. It reads the request with Apple's on-device model where available (needs an Xcode 26 build and Apple Intelligence), otherwise with keyword rules; either way nothing but place searches leaves the phone.

**Explorer**
- **Fog of war**: places you haven't been stay hazy and clear as you travel (cells of about 220 m). Toggle it in the layers sheet.
- **Weekly logbook** at the top of the Journal: distance, rides, time on the road and new discoveries in the last 7 days.
- **AI co-pilot**: tap Speak in Ask the guide (it starts listening on its own mid-trip) and say "find gas on my way", "add a Tim Hortons stop" or "what's the traffic like to work?". Speech is transcribed on the phone where iOS supports it.
- **Trail diary** in the Journal: rides log themselves (start once you've moved 200 m, end after 3 minutes still), with distance and time; tap one to see its trail on the map. Totals for miles ridden, rides, discoveries and area explored.
- **Discoveries**: parks, historic sites, scenic spots and trails near you appear as faded pins; get close and they're collected.
- **Achievements**: Greenhorn, Park Ranger, Historian, Cartographer, Legend of the Road (a famous highway) and more.
- **Waypoints**: long-press to drop a pin, pick its kind (now including Home, Work, park, viewpoint, historic site, trail), add notes and a photo. Tap a pin's popup to edit it any time; the speaker asks the guide which way.
- **Privacy**: everything above is stored only on the phone, with no account, ads or tracking, and the Journal can erase it all.

**Frontier guide voices**: pick a guide in the Journal (tap one to hear it): The Drifter (weary gunslinger, a rough blend of two Kokoro voices built in CI by `scripts/blend_voice.py`, pitched down), The Boss (silver-tongued gang leader) or The Old-Timer (cranky prospector). Original characters in the spirit of outlaw westerns, each with their own lines and a natural on-device AI voice ([Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), both Apache-2.0, offline). CI downloads the model (~170 MB in the app); without it the app falls back to the iOS voice.

**Not included**, and why:
- **Lane guidance**: Apple's routing API doesn't expose lanes.
- **CarPlay**: needs a CarPlay navigation entitlement from Apple, which a free Apple ID can't get.
- **Live traffic on the map**: only the ETA includes traffic; there's no free traffic layer.
- **Live ETA sharing, time saved by reroutes, "open now" filtering**: need a server, or data Apple's API doesn't give.
- **Community spots and upvotes**: needs a shared server and moderation. Pins with notes and photos are the on-phone version for now.

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
- **A cloud Mac** (e.g. MacinCloud), or any Mac: install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), add `Config/Secrets.xcconfig`, run `xcodegen generate`, open `FrontierMap.xcodeproj`, choose an iPhone simulator and press ⌘R. For the guide voices, first fetch `Kokoro/` and `Frameworks/` with the commands in the "Fetch Kokoro" step of `.github/workflows/ios.yml`. To install on your own iPhone, put `DEVELOPMENT_TEAM = <your team ID>` in `Config/Secrets.xcconfig` (a free Apple ID's Personal Team works; the install lasts 7 days), pick the phone as the destination and press ⌘R. Fake GPS with Simulator › Features › Location › Custom Location. Tests run with ⌘U.

The simulator has no compass, so heading only works on a real phone.

## Install on your iPhone (from Windows)

1. Install Apple's **Apple Devices** app (or iTunes) from the Microsoft Store so Windows can see the phone.
2. Install [Sideloadly](https://sideloadly.io) (a third-party tool: it asks for your Apple ID, so consider a secondary Apple ID).
3. Plug in the iPhone, drag in `FrontierMap-unsigned.ipa` and sign in with your Apple ID. Sideloadly signs and installs it.
4. On the iPhone: Settings › Privacy & Security › **Developer Mode** › On (it restarts). Then Settings › General › VPN & Device Management › trust your Apple ID.
5. With a free Apple ID the app **expires after 7 days**. Re-sideload to renew it.

## Permissions

- **Location, When In Use**: asked the first time the map shows your location. It's used on-device for the arrow, the trail diary, fog of war and discoveries. While a route is running it keeps updating with the screen locked (the blue indicator shows), and stops when the route ends. Coordinates are sent to Apple Maps, MapTiler, Open-Meteo and Overpass only to answer searches, tiles, weather/elevation, speed limits and opening hours. If you deny it, the map and search still work, and the follow button tells you how to re-enable location.
- **Photos**: only the photo you pick for a pin, through the system picker (no library access). No contacts. Everything stays on the phone and isn't synced.
- **Microphone and speech recognition**: only when you tap Speak (or open Ask the guide mid-trip).
- **Notifications**: only if you turn on leave-by alerts.

## Limitations

- **Global coverage**: the whole world is mapped, but detail depends on OpenStreetMap. Cities are rich, while rural areas and some countries are sparse. Labels show in Latin script (e.g. "Tokyo", not "東京").
- **Connectivity**: the map streams tiles and search needs internet. Places you've recently viewed stay in MapLibre's small automatic cache, but don't rely on that.
- **Offline**: only areas you explicitly saved work offline, and only down to the zoom you saved (max 15). Downloads count against your MapTiler quota. Large areas take many tiles, so save regions, not countries. Check MapTiler's terms for offline use on your plan. If you change the key, previously saved areas stop matching and must be re-saved. Search and the guide's directions don't need the map, but search does need a connection.
- **Directions**: needs a connection and your location. Apple routing doesn't cover every country, and you'll see "No trail found" where it doesn't. Bike routes use Apple's walking routes timed at 16 km/h, because cycling routes need the iOS 26 SDK. Transit is a time estimate that opens Apple Maps. Speed limits are only as good as OpenStreetMap's tags near you.
- **Look**: this is a styled vector map (parchment colors, inked lines, vignette), not hand-painted artwork. A closer "painted" look would need original illustrated textures and icons (`fill-pattern`, custom sprites), which you could add later.
- **Map style untested**: layer and field names follow the OpenMapTiles schema that MapTiler serves. If the hillshade source or a font name doesn't resolve, that layer simply won't draw.

## Project layout

```
project.yml                  XcodeGen spec (generates the .xcodeproj)
Config/                      placeholder key + optional Secrets.xcconfig
Sources/FrontierMapApp.swift app entry
Sources/ContentView.swift    main screen: search, turn banner, route panel, tools
Sources/Sheets.swift         pin editor, place details, layers, assistant, stops, elevation, Journal, turns
Sources/MapView.swift        MapLibre map, styles + night style, pins, route/trail layers
Sources/AppModel.swift       state: routes, trips, discoveries, achievements, search, offline
Sources/Navigation.swift     Route (multi-leg), StepTracker, path sampling
Sources/Planner.swift        trip assistant: request parsing (+ Apple on-device model)
Sources/Explorer.swift       on-device storage, trip recorder, fog, discoveries, achievements
Sources/Lookups.swift        speed limits and opening hours (Overpass), elevation (Open-Meteo), share links
Sources/Waypoints.swift      waypoints, pin kinds, geometry
Sources/Weather.swift        Open-Meteo weather
Sources/Guide.swift          guide characters and speech
Sources/Kokoro.swift         on-device neural voice
Sources/Markers.swift        pins, player arrow, compass rose, fog overlay, speed sign
Sources/frontier-style.json  the Western map style
Tests/                       unit tests
.github/workflows/ios.yml    Mac build in CI
```
