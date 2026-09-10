# Manage storage, reset preferences and uninstall

These controls are available in current candidate and development builds under **Settings → General → Manage**. They are not included in the published Kid build 1343. For that download, use the [manual reset and removal instructions](TROUBLESHOOTING.md#reset-goat-for-a-clean-installation).

Manage has two tabs: **Reset preferences** and **Uninstall GOAT**. Inspecting locations or reviewing choices does not remove anything.

## Inspect storage locations

Click **Storage locations on this Mac** anywhere across its header to show the storage tree. Root folders start collapsed. Click a root folder's row to expand it; its icon changes to an open folder.

**GOAT Home** contains connections and credentials, local memory, skills, themes, extensions and Pen metadata. Its usual location is `~/.goat`, but the tree shows the location your installation uses. **Application Support** holds the chat database and attachments separately. The tree also identifies the app copy and macOS preferences.

External Pen workspace folders are separate from GOAT's Pen metadata. Model engines and remote Hindsight banks belong to their own services. See [Storage and backups](../reference/STORAGE.md) for the full location reference.

## Reset appearance and general preferences

1. Select **Reset preferences**.
2. Read the defaults and the items that will be kept.
3. Click **Reset preferences**. The changes apply immediately and a completion message appears. There is no additional review or restart.

| Preference | Reset value |
| --- | --- |
| Theme and Dock icon | System |
| Chat and code fonts | Theme |
| Chat and code sizes | 14 and 13 |
| Transparency | 40% |
| Animations | On |
| New-chat effort | Trot |
| Automatic chat titles | On |
| Pens overview | Grid |
| Settings always on top | On |

This keeps GOAT Home, connections, credentials, chats, attachments, Pens, files and memory. Window positions, presentation unlock, privacy rules, tool permissions and extension settings are also kept. It does not clear all macOS app preferences or reset macOS privacy permissions.

## Choose what uninstall removes

Select **Uninstall GOAT**. The two radio options are on one line:

| Option | Initial selection |
| --- | --- |
| **Partial uninstall** (default) | Removes the app and macOS app preferences/window state; keeps GOAT Home data and chats/attachments. |
| **Uninstall all** | Removes the app and selects every data and preferences checkbox. |

**Checked means remove. Unchecked means keep.** Adjust the checkboxes to choose connections and credentials, local memory, skills/themes/extensions, Pen metadata, chats/attachments and macOS preferences/window state. Switching back to Partial restores its default selection; keeping any category changes All to Partial.

**Remove all GOAT Home data** selects its categories together. Chats and attachments have their own checkbox because they live in Application Support. Selecting Pen metadata for removal also selects its chats. Unchecking chats keeps their Pen metadata too.

The app copy shown on this tab is always included. A separately installed CLI is kept unless you use **Choose CLI copy…** to select it explicitly. **Keep CLI** clears that selection. External workspaces, model engines and remote memory are kept even with Uninstall all. Unrecognised files, shared locations and linked targets are also preserved or require manual review; empty directories can remain.

## Review and schedule uninstall

1. Click **Review choices**.
2. On **Are you sure?**, check **Will remove**, **Will keep** and the recovery folder. Use **Back** to change selections. **Change folder…** selects a different recovery parent; it must be outside the app and data locations, on the same volume as the data.
3. Click **Uninstall** to confirm. No additional confirmation dialog appears. GOAT prepares the request and stays open.
4. Finish chats, imports, command jobs and other work, then quit normally. Removal starts only after GOAT closes.

While waiting, return to **Manage** and choose **Cancel uninstall** to cancel. Closing the Manage window does not cancel a scheduled uninstall. The request expires after one hour. Other running GOAT copies block cleanup; do not open an older GOAT version until cleanup finishes.

Selected data and preferences move to a private recovery folder, normally under Downloads. The app and any selected CLI copy move to Trash. A temporary helper completes the work and removes itself. This is recoverable removal, not secure erasure.

## Recover data or check an incomplete uninstall

Keep the recovery folder private: it may contain credentials, conversations and memory. It is never deleted automatically. The folder contains instructions in `README.txt` after success, `plan.json` for original and recovery paths, `completed.json` for successful file moves and `trash.json` for app/CLI moves. Backed-up preferences are included when selected. If cleanup stops, read `UNINSTALL-STOPPED.txt` first.

If uninstall fails, inspect that report and the original locations before retrying. Some moves may already have completed. To restore, reinstall a compatible GOAT version, keep it closed, and restore reviewed data to the recorded locations. Check for newer files before replacing anything. Retained Pen memory stays in its original folder when Pen metadata is removed.

Keep a separate backup of data you need, including external workspaces and independently managed memory services. See [Back up safely](../reference/STORAGE.md#back-up-safely).
