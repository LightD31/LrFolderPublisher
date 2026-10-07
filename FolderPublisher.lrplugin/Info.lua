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
			title = 'Folder Publisher: Find Moved, Renamed or Missing Photos…',
			file = 'MenuCheck.lua',
		},
		{
			title = 'Folder Publisher: Clean Up Orphaned Files…',
			file = 'MenuOrphans.lua',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
