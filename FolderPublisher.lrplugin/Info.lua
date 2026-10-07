--[[----------------------------------------------------------------------------
Info.lua
Folder Publisher: a Lightroom Classic publish service that mirrors your
catalog's folder hierarchy to a folder on disk.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'io.github.lightd31.folderpublisher',
	LrPluginName = 'Folder Publisher',
	LrPluginInfoUrl = 'https://github.com/LightD31/LrFolderPublisher',

	LrExportServiceProvider = {
		title = 'Folder Publisher',
		file = 'FolderPublishServiceProvider.lua',
	},

	LrLibraryMenuItems = {
		{
			title = LOC '$$$/FolderPublisher/Menu/CheckPublish=Folder Publisher: Check & Publish^.',
			file = 'MenuCheckPublish.lua',
		},
		{
			title = LOC '$$$/FolderPublisher/Menu/Check=Folder Publisher: Find Moved, Renamed or Missing Photos^.',
			file = 'MenuCheck.lua',
		},
		{
			title = LOC '$$$/FolderPublisher/Menu/Orphans=Folder Publisher: Clean Up Orphaned Files^.',
			file = 'MenuOrphans.lua',
		},
		{
			title = LOC '$$$/FolderPublisher/Menu/Import=Folder Publisher: Import from Another Publish Service^.',
			file = 'MenuImport.lua',
		},
	},

	VERSION = { major = 1, minor = 2, revision = 0, build = 3 },
}
