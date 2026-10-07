# Testing Folder Publisher in Lightroom Classic

The automated tests (`tests/`) run the plug-in against a stand-in for the
Lightroom SDK. This checklist covers what only the real Lightroom can show.
Run it before each release, and whenever SDK-facing code changes.

**Work on a copy.** Use a copy of your catalog (*File ▸ Open Catalog* on a
duplicated `.lrcat`) and an empty test folder, never your real publish folder,
until the import section.

Note the Lightroom version and OS you tested with. If something fails, attach
`Documents/LrClassicLogs/FolderPublisher.log`.

## 1. Installation

- [ ] *File ▸ Plug-in Manager ▸ Add* the `FolderPublisher.lrplugin` folder.
      The status is green and there is no error.
- [ ] *Library ▸ Plug-in Extras* lists the four Folder Publisher commands.
- [ ] With Lightroom in French, the menu items, dialogs and messages are in
      French.

## 2. Service settings dialog

In the Publish Services panel, click *Set Up…* next to Folder Publisher.

- [ ] All sections show: Destination, File Names, Republish When Metadata
      Changes, Removing Photos, After Publishing.
- [ ] *Save* stays disabled until a folder is chosen. *Choose…* and
      *Show in Finder/Explorer* work.
- [ ] With a photo selected in the Library, the example under Destination
      shows its path and the target path. It updates when you change *Mirror
      folders from*, *Strip leading folders*, *Limit depth* or the file-name
      template.
- [ ] The template field is only enabled for *With a template*, and the token
      help only shows then.
- [ ] *All* / *None* tick and untick every republish trigger.
- [ ] Save, then open *Edit Settings…* again: every value is kept.

## 3. Collections

- [ ] *Create Published Collection* and *Create Published Smart Collection*
      both show the Folder Publisher box with a live example.
- [ ] Changing *Strip leading/trailing*, *Add before/after* or *Flat* updates
      the example. Typing `{Collection}` uses the name being typed.
- [ ] Edit an existing, published collection and change *Add before the
      path*: its photos move to *Modified Photos to Re-Publish* within a few
      seconds.

## 4. Publishing

- [ ] Add about 20 photos, including a RAW+JPEG pair, a virtual copy and a
      video. Publish.
- [ ] The tree on disk mirrors the Lightroom folders. The RAW+JPEG pair gives
      `NAME.jpg` and `NAME-2.jpg`. The virtual copy gives `NAME (Copy 1).jpg`.
- [ ] A summary appears ("N new photos published"). Set *Show a summary* to
      *Never* and publish again: no summary.
- [ ] Edit one photo in Develop and publish: the summary says "1 photo
      updated", and the file is rewritten in place.
- [ ] Change a photo's caption: it goes to *Modified Photos to Re-Publish*.
      Change its rating with *Rating* unticked: it does not.
- [ ] *Photo capture time* as file date: the file's date in Finder/Explorer
      is the capture time (Windows: also the creation date).
- [ ] Right-click a published photo, then *Show in Finder/Explorer*: the
      file is selected.
- [ ] File Format *Original* with a raw file: the `.xmp` sidecar is published
      next to it.

## 5. Renames, moves, removals

- [ ] In Lightroom, rename a published photo (*Library ▸ Rename Photo*) and
      move another one to a different folder. Run *Folder Publisher: Check &
      Publish…*. Both files move on disk, the old ones disappear, and the
      combined summary mentions them.
- [ ] Delete a published file by hand, then run *Find Moved, Renamed or
      Missing Photos…*: it reports one missing file and marks the photo.
- [ ] Remove a photo from a collection and publish: its file is deleted (or
      goes to the Trash, depending on the setting). Empty folders are
      removed.
- [ ] Put the same photo in two collections that map to the same path.
      Remove it from one and publish: the file stays. Remove it from the
      other and publish: the file goes.
- [ ] *When it is deleted from the catalog: Don't allow deleting published
      photos*: deleting a published photo from the catalog is refused, with
      an explanation.
- [ ] Put a stray file in the publish folder, then run *Clean Up Orphaned
      Files…*: only the stray file is listed and removed.

## 6. Offline drive

- [ ] Publish photos from an external drive, then edit one of them and
      disconnect the drive. Publish: the photo is skipped and listed in the
      summary, and it stays in *Modified Photos to Re-Publish*.
- [ ] Reconnect the drive and publish: it is published.
- [ ] Point the service at a folder on a disconnected drive and publish: you
      are asked before the folder is created, and *Cancel* stops cleanly.

## 7. Import from jf Folder Publisher

Use a catalog copy that has a working jf Folder Publisher service.

- [ ] Create a Folder Publisher service pointing at the **same folder**, with
      the same format and size.
- [ ] Run *Import from Another Publish Service…*. The confirmation lists each
      collection with "N/M at the expected path". Most files should be at the
      expected path.
- [ ] After the import, the collections, smart collections (open their rules)
      and collection sets exist in the new service. The photos show as
      *Published*. Photos that were pending in the old service are pending
      here too.
- [ ] Publish the new service: only new and modified photos are exported, and
      no file is duplicated or moved unexpectedly. Compare the file count of
      the folder before and after.

## 8. Windows-specific

- [ ] A root on a network share (`\\server\share\folder`) works.
- [ ] Folder and file names with accents publish correctly. With *Photo
      capture time* as file date, their date is set too.
- [ ] *Move to Recycle Bin* works on a local disk. On a network share, it
      falls back to the explanation dialog.
