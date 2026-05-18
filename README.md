# DunenDashboard iOS

This project builds a simple DUNEN BLE dashboard.

## Build with GitHub Actions

1. Make a new GitHub repository.
2. Upload all files from this folder.
3. Go to `Actions`.
4. Open `Build iOS IPA`.
5. Press `Run workflow`.
6. Download the artifact named `DunenDashboard-unsigned-ipa`.

## Install on iPhone from Windows

The GitHub Actions file makes an **unsigned IPA**.

Try installing/signing it with:
- Sideloadly on Windows
- AltStore/SideStore

You will sign it with your Apple ID during sideloading.

If Sideloadly refuses unsigned IPA:
- extract the IPA
- keep the `Payload/DunenDashboard.app`
- re-zip the Payload folder as `.ipa`
- try again

Free Apple ID sideloads usually expire after 7 days.
