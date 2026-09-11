-- Configure only the mounted staging volume. Finder must run in a logged-in session.
on run argv
    set mountPath to item 1 of argv
    set diskFolder to POSIX file mountPath as alias
    tell application "Finder"
        open diskFolder
        delay 1
        my configureWindow(diskFolder)
        my placeItems(diskFolder)
        update diskFolder without registering applications
        delay 2
        close container window of diskFolder
        delay 2
        open diskFolder
        delay 2
        -- Finder can inherit icon options on its first reopen. Reapply the
        -- complete view configuration and anchors after its content has loaded.
        my configureWindow(diskFolder)
        my placeItems(diskFolder)
        update diskFolder without registering applications
        delay 2
        if (count argv) is 1 then close container window of diskFolder
        delay 2
    end tell
end run

on configureWindow(diskFolder)
    tell application "Finder"
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
    end tell
end configureWindow

-- Anchors match the measured ImageGen landing zones. Smaller icons use 24-point padding.
on placeItems(diskFolder)
    -- Finder's filtered folder collection omits some invisible system folders.
    set rootNames to list folder diskFolder with invisibles
    tell application "Finder"
        set position of item "GOAT.app" of diskFolder to {222, 180}
        set position of item "Applications" of diskFolder to {499, 180}
        set position of item "CLI Tools" of diskFolder to {303, 246}
        set position of item "Licence" of diskFolder to {638, 375}
        set position of item ".background" of diskFolder to {532, 375}
        set extraX to 316
        repeat with rootName in rootNames
            set supportName to contents of rootName
            if supportName starts with "." and supportName is not ".background" then
                set supportFolder to item supportName of diskFolder
                if class of supportFolder is folder then
                    if supportName is ".fseventsd" then
                        set position of supportFolder to {426, 375}
                    else
                        if extraX < 60 then error "Too many hidden support folders for the installer footer"
                        set position of supportFolder to {extraX, 375}
                        set extraX to extraX - 110
                    end if
                end if
            end if
        end repeat
    end tell
end placeItems
