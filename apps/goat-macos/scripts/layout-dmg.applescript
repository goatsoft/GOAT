-- Configure only the mounted staging volume. Finder must run in a logged-in session.
on run argv
    set mountPath to item 1 of argv
    set diskFolder to POSIX file mountPath as alias
    tell application "Finder"
        open diskFolder
        delay 1
        set installWindow to container window of diskFolder
        set current view of installWindow to icon view
        set toolbar visible of installWindow to false
        set statusbar visible of installWindow to false
        -- Finder bounds include the 32-point title bar on the supported macOS host.
        set bounds of installWindow to {100, 100, 820, 612}
        set viewOptions to icon view options of installWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background color of viewOptions to {0, 0, 0}
        set background picture of viewOptions to file ".background:background.tiff" of diskFolder
        set position of item "GOAT.app" of diskFolder to {215, 235}
        set position of item "Applications" of diskFolder to {505, 235}
        -- The smaller footer artwork sits 24 points below its item centre.
        set position of item "CLI Tools" of diskFolder to {520, 401}
        set position of item "Licence" of diskFolder to {630, 401}
        update diskFolder without registering applications
        delay 2
        close installWindow
        delay 2
        open diskFolder
        delay 2
        -- A fresh Finder window can recalculate item geometry on its first
        -- reopen. Reapply the anchors once its background and icons are loaded.
        set position of item "GOAT.app" of diskFolder to {215, 235}
        set position of item "Applications" of diskFolder to {505, 235}
        set position of item "CLI Tools" of diskFolder to {520, 401}
        set position of item "Licence" of diskFolder to {630, 401}
        update diskFolder without registering applications
        delay 2
        if (count argv) is 1 then close container window of diskFolder
        delay 2
    end tell
end run
