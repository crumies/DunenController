# DUNEN Dashboard Liquid Glass

Custom iPhone dashboard for DUNEN FFE0 / FFE1 BLE controllers.

Features:
- Liquid glass bottom tab slider
- Info / Advanced / Settings tabs
- DUNEN/Aptum color scheme
- Animated splash with logo, bike, spinning wheels, flashing light
- BLE-only dashboard values, no phone GPS speed
- RPM in the speedometer corner
- Brake sensor indicators
- KM/H / MPH setting
- KM / Miles setting
- Demo mode
- Raw packet viewer for decoding DUNEN telemetry

## Build

Upload all files to GitHub root.

Make sure your repo has:
- project.yml
- Sources/
- Assets.xcassets/
- .github/workflows/build-ios.yml

Delete old:
- DunenDashboard.xcodeproj
- old iOS app builder workflow

Then run GitHub Actions: `Build iOS IPA`.

Install the artifact IPA with Sideloadly on Windows.

## Important

The BLE parser has placeholder best-guess byte offsets. The app will connect and show raw packets, but RPM/speed/brakes may need correction after you send raw packets from your real controller.
