# Musike for Mac

This target uses Mac Catalyst and the SwiftUI interface shared with iOS. The
catalog, player and library run on the Mac; it does not require a Musike server.
The Mac library is independent of iOS and of the existing Electron app. Use the
backup import/export in Settings to move a library between installations.

Install the workspace's Node.js dependencies first, then open
`App/MusikeMac.xcodeproj` in Xcode and select **My Mac (Mac Catalyst)**. The
build phase creates the headless engine from the current sources automatically.
Node.js must be on Xcode's PATH; alternatively set the `MUSIKE_NODE` build
setting to the path of a working Node.js executable. Configure a development
team when signing an archive for distribution.

For a local unsigned build from the command line:

```sh
xcodebuild -project mobile/mac/App/MusikeMac.xcodeproj -scheme App \
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO build
```

The generated `Mac/public` and `web/dist-mac` directories are build artifacts;
they are recreated on every Xcode build and are not checked in.
