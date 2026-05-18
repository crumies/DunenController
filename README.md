# DunenDashboard iOS

This version uses XcodeGen, so there is no broken hand-written `.pbxproj`.

## GitHub Actions build

1. Upload all files to a GitHub repo.
2. Go to Actions.
3. Run `Build iOS IPA`.
4. Download `DunenDashboard-unsigned-ipa`.
5. Sign/install with Sideloadly on Windows.

Free Apple ID sideload usually expires after 7 days.


IMPORTANT: Delete any old `DunenDashboard.xcodeproj` from your GitHub repo before uploading this version. The workflow also removes it automatically before generating a clean one.
