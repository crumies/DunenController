# Aptum Dashboard Final Patched 4.5

Fixes:
- Removed duplicate Current in metrics card.
- Removed useless Motor metric from metrics.
- Metrics now show Voltage, Odometer, Current, Power, Battery, Pack.
- Redline no longer appears fully at start; red only appears after high RPM.
- Replaced motor temperature icon with custom electric motor drawing.
- Demo throttle/brake now smooths speed and does not force lean full left/right.
- Brake light turns on when demo brake > 15%.
- Uses uploaded MP3s:
  - startup.mp3
  - scanning.mp3
  - connected.mp3
- Scanning sound plays when scan starts.
- Connected sound plays when BLE connects.
- Developer options include Live Activity status check and force update.
- Live Activity note: iOS does not show a normal permission popup for this; it must be enabled in Settings and requires the widget extension embedded.
- Project target forced to iOS 16.2+ and Swift 6 mode.
- Widget dependency embedded when widget target is present.
- Robust IPA workflow.


Build Fix 4.6:
- Added missing demoSpeedKmh to DunenBLEManager.
- Marked SoundManager as @MainActor for Swift 6.
- Marked LiveActivityManager as @MainActor for Swift 6.
- Added SWIFT_STRICT_CONCURRENCY: minimal.


Build Fix 4.7:
- Removed @MainActor from DunenBLEManager to satisfy CoreBluetooth delegate protocols.
- Added @preconcurrency to CoreBluetooth delegate conformances.
- Wrapped SoundManager and LiveActivityManager calls in Task { @MainActor in ... }.
- Kept SoundManager/LiveActivityManager @MainActor.
- Fixed Swift 6 timer closure mutations.


v5.3 fixes:
- Redline gradient moved to the RIGHT side only.
- Redline starts 400 rpm before the mode limit.
- RPM bar display max is mode limit + 500 rpm, so there is wiggle room.
- Eco limit 4000, XC 6000, Sports 8000.
- Demo power cap raised to 10.5 kW so it can show above 8 kW.
- Bundled startup/scanning/connected MP3s and added different fallback sound IDs.
- Ensured Resources are bundled into IPA.
- Added Bluetooth permission strings.
- Re-asserted AppIcon settings.
