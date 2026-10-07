--[[----------------------------------------------------------------------------
FPSettings.lua
Publish-service settings (stored by Lightroom with the service) and
per-collection settings defaults.
------------------------------------------------------------------------------]]

local FPSettings = {}

--- Metadata that can mark published photos as modified. Each entry is one
-- checkbox; `keys` are the metadataThatTriggersRepublish keys it controls.
FPSettings.republishTriggers = {
	{ id = 'title', label = 'Title', keys = { 'title' }, default = true },
	{ id = 'caption', label = 'Caption', keys = { 'caption' }, default = true },
	{ id = 'headline', label = 'Headline', keys = { 'headline' } },
	{ id = 'keywords', label = 'Keywords (exported ones)', keys = { 'keywords' }, default = true },
	{ id = 'rating', label = 'Rating', keys = { 'rating' } },
	{ id = 'label', label = 'Color label', keys = { 'label' } },
	{ id = 'dateCreated', label = 'Capture date', keys = { 'dateCreated' }, default = true },
	{ id = 'gps', label = 'GPS and location', default = true, keys = {
		'gps', 'gpsAltitude', 'location', 'city', 'stateProvince', 'country', 'isoCountryCode',
	} },
	{ id = 'creator', label = 'Creator info', keys = {
		'creator', 'creatorJobTitle', 'creatorAddress', 'creatorCity', 'creatorStateProvince',
		'creatorPostalCode', 'creatorCountry', 'creatorPhone', 'creatorEmail', 'creatorUrl',
	} },
	{ id = 'copyright', label = 'Copyright and usage', keys = {
		'copyright', 'copyrightStatus', 'copyrightInfoUrl', 'rightsUsageTerms',
	} },
	{ id = 'iptc', label = 'IPTC subject, genre, scene', keys = {
		'iptcSubjectCode', 'iptcCategory', 'iptcOtherCategories', 'intellectualGenre', 'scene',
		'descriptionWriter',
	} },
	{ id = 'workflow', label = 'Job, instructions, provider, source', keys = {
		'jobIdentifier', 'instructions', 'provider', 'source',
	} },
	{ id = 'customMetadata', label = 'Plug-in metadata', keys = { 'customMetadata' } },
	{ id = 'default', label = 'Anything else Lightroom writes to XMP', keys = { 'default' } },
}

FPSettings.exportPresetFields = {
	-- Destination
	{ key = 'fp_root', default = '' },
	{ key = 'fp_folderBase', default = 'lrRootContents' }, -- lrRootContents | lrRoot | full
	{ key = 'fp_skipLevels', default = 0 },
	{ key = 'fp_maxDepth', default = 0 },

	-- File naming
	{ key = 'fp_fileNaming', default = 'library' },     -- library | lightroom | template
	{ key = 'fp_template', default = '{FilenameBase}' },
	{ key = 'fp_virtualCopySuffix', default = true },

	-- Housekeeping
	{ key = 'fp_onRemove', default = 'delete' },        -- delete | trash | keep
	{ key = 'fp_onCatalogDelete', default = 'remove' }, -- remove | keep | block
	{ key = 'fp_pruneEmptyFolders', default = true },
	{ key = 'fp_fileDate', default = 'export' },        -- export | capture
	{ key = 'fp_showSummary', default = 'always' },     -- always | problems | never
}

for _, trigger in ipairs( FPSettings.republishTriggers ) do
	table.insert( FPSettings.exportPresetFields,
		{ key = 'fp_trig_' .. trigger.id, default = trigger.default == true } )
end

--- Default value of a publish setting.
function FPSettings.default( key )
	for _, field in ipairs( FPSettings.exportPresetFields ) do
		if field.key == key then
			return field.default
		end
	end
end

--- Reads a publish setting, falling back to its default.
function FPSettings.get( settings, key )
	local value = settings and settings[ key ]
	if value == nil then
		return FPSettings.default( key )
	end
	return value
end

FPSettings.collectionDefaults = {
	subfolder = '',          -- template prepended to the path, e.g. "{Collection}"
	append = '',             -- template appended to the folder path
	structure = 'mirror',    -- mirror | flatten
	extraSkipLevels = 0,     -- leading folders to strip
	trailingSkipLevels = 0,  -- trailing folders to strip
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
