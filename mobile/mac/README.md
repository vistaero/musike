# Musike for Mac

This target uses Mac Catalyst and the SwiftUI interface shared with iOS. The
catalog, player and library run on the Mac; it does not require a Musike server.
The Mac library is independent of iOS and of the existing Electron app. Saved
online songs and album membership, playlists, and favorites are included in
the JSON backup in Settings. Music imported from local files is copied into
`~/Library/Application Support/Musike Native/`. Back up that whole folder as
well to preserve the audio files and their local identifiers; the JSON backup
does not contain the audio itself. Importing a file never moves the original.

On first launch, songs from the previous Mac version's favorites and playlists
are added to the new library. The collection can then be browsed by song,
artist, album, favorites and playlist. Songs and albums from online search can
be added to the library; local and online songs share the player and queues.

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
