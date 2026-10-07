# Folder Publisher for Lightroom Classic

A free, open-source **publish service** for Adobe Lightroom Classic that mirrors
your catalog's **folder hierarchy** to a folder on disk, as JPEGs or any other
export format, and keeps it in sync.

It is a modern rewrite inspired by Jeffrey Friedl's
[“Folder Publisher”](https://regex.info/blog/lightroom-goodies/folder-publisher)
plug-in, which is no longer maintained. It shares no code with the original
and is not affiliated with its author.

> Typical uses: a lightweight JPEG copy of your library for a NAS, a media
> server, a digital frame or a family member's computer; a "best of" tree built
> from a smart collection; a phone-sized copy for syncing with Syncthing,
> rclone, Dropbox…

## Features

- **Mirrors Lightroom's folders.** With the top-level folder `D:\Photos`,
  `D:\Photos\2024\Trip\IMG_1.CR3` becomes `<root>\2024\Trip\IMG_1.jpg`,
  the same layout as the original plug-in.
  - Include the top-level folder's name, or start from the full path on disk.
  - Strip leading folders and limit the depth of the tree.
  - Every settings dialog shows a **live example**: where a real photo from
    your catalog will land, updated as you type.
- **Stays in sync.** Publishing adds new photos, updates edited ones and
  removes photos taken out of the service.
  - Photos **renamed or moved** in Lightroom are moved on disk, and their old
    copies are removed.
  - Folders left empty are removed (optional).
- **Per-collection layout.** Each published collection (including smart
  collections) can strip leading or trailing folders, add folders before or
  after the path (e.g. `{Collection}` or `web/{YYYY}`), or flatten the tree.
  When you change these settings, the affected photos are marked for
  republishing automatically.
- **Predictable file names.** By default the published file keeps the
  **original file name**. This avoids Lightroom's habit of renaming duplicates
  behind the plug-in's back. You can also use Lightroom's File Naming section,
  or a template:
  - `{YYYY}/{MM}/{Title|FilenameBase}` with fallbacks and `/` for sub-folders.
  - Virtual copies get their copy name appended: `IMG_1234 (B&W).jpg`.
  - Name clashes (RAW+JPEG pairs, names that differ only in case) get `-2`,
    `-3`… and keep that name on later publishes.
- **You choose what counts as a change.** Pick which metadata changes mark
  photos for republishing: title, caption, headline, keywords, rating, label,
  capture date, GPS and location, creator, copyright, IPTC fields, job and
  instructions, plug-in metadata, or everything. All/None buttons included.
  Develop edits always count.
- **Safe removal.** Removed photos can be deleted, moved to the Trash/Recycle
  Bin, or left on disk.
  - Photos deleted from the catalog can follow that rule, keep their file, or
    be protected: the service can refuse to let published photos be deleted.
  - A file used by several collections of the same service is kept until the
    last one lets go of it.
  - The plug-in never touches anything outside the publish root.
- **Offline originals are skipped.** If a photo's original is unavailable (an
  unplugged drive), it isn't rendered from a lower-quality Smart Preview.
  It stays queued, you get a list at the end, and it's published next time.
- **File dates.** Published files can carry the photo's capture time as their
  modification date (and creation date on Windows).
- **Originals and video.** Video is supported. With File Format set to
  *Original*, raw files are published together with their `.xmp` sidecar.
- **Relocatable.** Published files are tracked by their path *relative to the
  root*. If you move the published tree, point the service at the new location
  and nothing needs to be republished. A root such as `~/Pictures/Mirror` works
  too.
- **Import from Jeffrey Friedl's plug-in** (or another folder publisher):
  see [Switching from jf Folder Publisher](#switching-from-jf-folder-publisher).
- **Maintenance tools** (*Library ▸ Plug-in Extras*, and buttons in the
  service settings):
  - **Find Moved, Renamed or Missing Photos…** marks for republishing every
    photo whose published file is missing, or whose target path changed.
  - **Clean Up Orphaned Files…** lists files in the publish folder that no
    published photo uses, and moves them to the Trash or deletes them.
- **Show in Finder / Explorer** from a published photo or collection.
- **Free and open source.** No registration, no nag screens, no expiry.

## Installation

1. Download `FolderPublisher.lrplugin.zip` from the
   [latest release](https://github.com/LightD31/LrFolderPublisher/releases)
   (or clone this repository) and unzip it somewhere permanent, for example
   `Documents/Lightroom Plugins/FolderPublisher.lrplugin`.
2. In Lightroom Classic choose *File ▸ Plug-in Manager… ▸ Add* and select the
   `FolderPublisher.lrplugin` folder.
3. In the Library module's **Publish Services** panel (bottom left), click
   **Set Up…** next to *Folder Publisher*.

Supported: Lightroom Classic on macOS and Windows. It should also work with
Lightroom 6 or later.

## Usage

1. **Set up the service:** give it a name, choose the folder to *publish to*
   (preferably an empty folder), and choose the format and size of the
   published copies as you would for an export.
2. **Choose photos:** drag photos into *Mirrored Photos*, or create a smart
   collection inside the service (for example "rating ≥ 3 stars").
3. Click **Publish**. Do it again whenever you like; only the changes are
   written.

### Collection options

Right-click a collection in the service and choose *Edit Collection…*:

| Option | Effect |
|---|---|
| Folder structure | *Mirror Lightroom folders* (default) or *Flat*. |
| Strip leading / trailing folders | Drop folders from the start or the end of the mirrored path. |
| Add before the path | Folders in front, e.g. `{Collection}`, `{CollectionPath}`, `Web`. |
| Add after the path | Folders after the mirrored path, e.g. `small` or `{YYYY}`. |

Template tokens are allowed in the two "Add" fields. The dialog shows where a
real photo (from the collection, or the selected one) will be published.

If the same photo is in two collections that map it to the same path, the two
collections share one file.

### Template tokens

Tokens work in the file name template and in the collection sub-folder. Token
names are case-insensitive.

| Token | Value |
|---|---|
| `{Filename}` `{FilenameBase}` `{Ext}` | Original file name, without extension, extension |
| `{CopyName}` | Virtual copy name |
| `{Folder}` `{FolderPath}` | Name of the photo's folder, mirrored folder path |
| `{YYYY}` `{YY}` `{MM}` `{DD}` `{HH}` `{MIN}` `{SS}` `{Date}` | Capture date and time (`{Date}` = `YYYY-MM-DD`) |
| `{Title}` `{Caption}` `{Headline}` `{Label}` `{Rating}` | Metadata |
| `{Camera}` `{Lens}` `{ISO}` `{Keywords}` | Metadata |
| `{City}` `{State}` `{Country}` `{Location}` `{Creator}` `{JobIdentifier}` | IPTC metadata |
| `{Collection}` `{CollectionPath}` `{Service}` | Published collection, its collection-set path, the service name |
| `{Meta:key}` | Any [formatted metadata key](https://helpx.adobe.com/lightroom-classic/sdk.html), e.g. `{Meta:cameraSerialNumber}` |
| `{Raw:key}` | Any raw metadata key, e.g. `{Raw:pickStatus}` |

- `{A|B}` uses `B` when `A` is empty.
- `{A|"text"}` uses literal text, e.g. `{YYYY|"Undated"}`.
- `/` creates sub-folders.
- Characters that aren't allowed in file names are replaced with `_`.

The example at the bottom of the section shows the result for a real photo as you type.

### Switching from jf Folder Publisher

You don't need to republish everything:

1. Install Folder Publisher next to the old plug-in. Create a Folder Publisher
   service that publishes to the **same folder** as your old service, with
   the same format and size settings.
2. Choose *Library ▸ Plug-in Extras ▸ Folder Publisher: Import from Another
   Publish Service…*. Pick the old service and the new one.
3. The import:
   - recreates the collection sets, collections and smart collections, with
     their rules;
   - works out how each collection laid out its files and sets the matching
     collection options;
   - marks every photo whose file is already in the folder as published, so
     nothing is re-rendered. Photos that were waiting to be republished are
     still marked that way.

   Before anything changes, it shows what it found, including how many files
   already sit exactly where Folder Publisher would put them.
4. Publish the new service once. Only new and modified photos are exported.
5. When you're happy with the result, disable the old plug-in or delete the
   old service. Don't remove photos or collections from the old service
   first: that would delete the published files.

If the old service renamed files (Lightroom's File Naming, or its Enhanced
File Renaming), set the new service's file names to match before importing.
Files that don't match stay where they are until the photo is next
republished.

### Changing the root folder

Move the published folder wherever you like, then edit the publish service and
point *Publish to folder* at the new location. If Lightroom asks whether to
republish everything, you can choose *Leave as Is*: paths are stored relative
to the root.

If the root can't be found when you publish (for example, an unplugged
external drive), the plug-in asks before creating it. This avoids filling your
system disk by accident.

## Differences from the original plug-in

Most of the original's everyday features are here. A few were left out on
purpose:

- **FTP sync.** Use a dedicated tool (rclone, Syncthing, FreeFileSync…) on the
  publish folder.
- **"Smart Preview export" mode**, which the original labelled experimental,
  and publishing from Smart Previews when originals are offline. Such photos
  are skipped and published once the originals are back.
- **ExifTool-based and Lua-script template tokens.**
- **Import/export of service settings.** Lightroom's own *Create Another
  Publish Service* covers most uses.

New compared to the original:

- importing an existing service without republishing;
- live path examples in every dialog;
- files tracked by relative paths (relocatable roots, `~` support);
- orphan clean-up and a "move to Trash" option;
- safe handling of files shared between collections;
- automatic re-check after collection edits;
- tokens in the per-collection path options;
- no registration.

## Troubleshooting

- Logs are written to `FolderPublisher.log` in Lightroom's log folder
  (`Documents/LrClassicLogs`).
- Photos that keep landing in *Modified Photos to Re-Publish* for no visible
  reason is a long-standing Lightroom behaviour, mostly with smart
  collections. The plug-in can't influence it.
- Publishing tens of thousands of photos at once can be slow in Lightroom.
  Select a batch and Alt/Option-click **Publish** to publish only the
  selection.

## Development

The plug-in is plain Lua 5.1, as used by Lightroom:

```
FolderPublisher.lrplugin/
  Info.lua                          plug-in manifest
  FolderPublishServiceProvider.lua  publish service callbacks
  FPCore.lua                        pure logic: paths, templates, collisions (no SDK)
  FPMapping.lua                     photo/collection -> target path
  FPFiles.lua                       file operations
  FPDialogs.lua                     settings UI
  FPMaintenance.lua                 Plug-in Extras commands
  FPMigration.lua                   import from another publish service
  FPSettings.lua                    settings and defaults
tests/
  run.lua                           unit tests for FPCore
  integration.lua                   end-to-end tests against a stubbed SDK
  lrstub.lua                        minimal Lightroom SDK stand-in
```

Run the tests (requires `lua5.1`; the integration tests need a POSIX shell):

```sh
lua5.1 tests/run.lua
lua5.1 tests/integration.lua
```

The stub is not a real Lightroom. Check changes to SDK-facing code in
Lightroom Classic before releasing.

To release, push a tag such as `v1.0.0`. GitHub Actions attaches
`FolderPublisher.lrplugin.zip` to a release.

## License

[MIT](LICENSE)
