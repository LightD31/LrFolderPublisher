--[[----------------------------------------------------------------------------
FPSettings.lua
Publish-service settings (stored by Lightroom with the service) and
per-collection settings defaults.
------------------------------------------------------------------------------]]

local FPSettings = {}

FPSettings.exportPresetFields = {
	-- Destination
	{ key = 'fp_root', default = '' },
	{ key = 'fp_folderBase', default = 'lrRoot' },      -- lrRoot | lrRootContents | full
	{ key = 'fp_skipLevels', default = 0 },
	{ key = 'fp_maxDepth', default = 0 },

	-- File naming
	{ key = 'fp_fileNaming', default = 'library' },     -- library | lightroom | template
	{ key = 'fp_template', default = '{FilenameBase}' },
	{ key = 'fp_virtualCopySuffix', default = true },

	-- Metadata that triggers a republish
	{ key = 'fp_trig_title', default = true },
	{ key = 'fp_trig_caption', default = true },
	{ key = 'fp_trig_keywords', default = true },
	{ key = 'fp_trig_gps', default = true },
	{ key = 'fp_trig_gpsAltitude', default = false },
	{ key = 'fp_trig_dateCreated', default = true },
	{ key = 'fp_trig_default', default = false },
	{ key = 'fp_trig_customMetadata', default = false },

	-- Housekeeping
	{ key = 'fp_onRemove', default = 'delete' },        -- delete | trash | keep
	{ key = 'fp_pruneEmptyFolders', default = true },
	{ key = 'fp_fileDate', default = 'export' },        -- export | capture
}

FPSettings.republishTriggers = {
	{ key = 'title', label = 'Title' },
	{ key = 'caption', label = 'Caption' },
	{ key = 'keywords', label = 'Keywords' },
	{ key = 'gps', label = 'GPS location' },
	{ key = 'gpsAltitude', label = 'GPS altitude' },
	{ key = 'dateCreated', label = 'Capture date' },
	{ key = 'customMetadata', label = 'Plug-in metadata' },
	{ key = 'default', label = 'Any other metadata (rating, label, IPTC, ...)' },
}

FPSettings.collectionDefaults = {
	subfolder = '',          -- template, e.g. "{Collection}"
	structure = 'mirror',    -- mirror | flatten
	extraSkipLevels = 0,
}

--- Fills missing collection settings with defaults (works on plain and
-- observable tables).
function FPSettings.applyCollectionDefaults( settings )
	for k, v in pairs( FPSettings.collectionDefaults ) do
		if settings[ k ] == nil then
			settings[ k ] = v
		end
	end
	return settings
end

--- Returns a plain table of collection settings with defaults applied.
function FPSettings.collectionSettings( raw )
	local out = {}
	for k, v in pairs( FPSettings.collectionDefaults ) do
		local value = raw and raw[ k ]
		if value == nil then
			value = v
		end
		out[ k ] = value
	end
	return out
end

return FPSettings
