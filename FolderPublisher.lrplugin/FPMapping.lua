--[[----------------------------------------------------------------------------
FPMapping.lua
Glue between Lightroom photos / collections and the pure path logic in
FPCore. Must be called from within an asynchronous task.
------------------------------------------------------------------------------]]

local LrDate = import 'LrDate'
local LrPathUtils = import 'LrPathUtils'

local FPCore = require 'FPCore'
local FPSettings = require 'FPSettings'
local logger = require 'FPLog'

local FPMapping = {}

--- Absolute paths of Lightroom's top-level folders (as in the Folders panel).
function FPMapping.topFolders( catalog )
	local out = {}
	for _, folder in ipairs( catalog:getFolders() ) do
		out[ #out + 1 ] = folder:getPath()
	end
	return out
end

--- Describes a published collection: name, path of collection-set names and
-- collection settings (with defaults applied).
-- @param overrides optional { name = ..., settings = ... } to use instead of
--        the values stored in the catalog (used right after an edit).
function FPMapping.collectionContext( collection, overrides )
	overrides = overrides or {}
	local name = overrides.name or ( collection and collection:getName() ) or ''
	local path = { name }
	local parent = collection and collection:getParent()
	while parent do
		table.insert( path, 1, parent:getName() )
		parent = parent:getParent()
	end

	local rawSettings = overrides.settings
	if not rawSettings and collection then
		local summary = collection:getCollectionInfoSummary()
		rawSettings = summary and summary.collectionSettings
	end

	return {
		name = name,
		path = path,
		settings = FPSettings.collectionSettings( rawSettings ),
	}
end

local function dateParts( lrTime )
	if not lrTime then
		return nil
	end
	local s = LrDate.timeToUserFormat( lrTime, '%Y %m %d %H %M %S' )
	local year, month, day, hour, min, sec = s:match( '^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+)' )
	if not year then
		return nil
	end
	return {
		year = tonumber( year ), month = tonumber( month ), day = tonumber( day ),
		hour = tonumber( hour ), min = tonumber( min ), sec = tonumber( sec ),
	}
end

--- Capture time of a photo as a Lightroom time value, or nil.
function FPMapping.captureTime( photo )
	return photo:getRawMetadata( 'dateTimeOriginal' )
		or photo:getRawMetadata( 'dateTimeDigitized' )
		or photo:getRawMetadata( 'dateTime' )
end

local function safeGetter( photo, method )
	local cache = {}
	return function( key )
		if cache[ key ] == nil then
			local ok, value = pcall( photo[ method ], photo, key )
			if not ok then
				value = nil
			end
			if value ~= nil and type( value ) ~= 'string' and type( value ) ~= 'number'
				and type( value ) ~= 'boolean' and method == 'getFormattedMetadata' then
				value = nil
			end
			cache[ key ] = { value }
		end
		return cache[ key ][1]
	end
end

local warnedTemplates = {}

--- Computes the target path of a photo relative to the publish root, WITHOUT
-- extension and without collision suffixes.
--
-- @param photo        LrPhoto
-- @param settings     publish settings (fp_* keys)
-- @param colCtx       result of FPMapping.collectionContext
-- @param topFolders   result of FPMapping.topFolders
-- @param renderedPath path of the rendered file (only needed in 'lightroom'
--                     naming mode, where Lightroom decides the file name)
-- @param serviceName  name of the publish service (for the {Service} token)
-- @return stem, nameKnown  -- nameKnown is false when the file name cannot be
--                             predicted (Lightroom naming without a rendition)
function FPMapping.targetStem( photo, settings, colCtx, topFolders, renderedPath, serviceName )
	local path = photo:getRawMetadata( 'path' )
	local colSettings = colCtx.settings

	local mirrored = FPCore.mirrorFolder(
		LrPathUtils.parent( path ),
		topFolders,
		settings.fp_folderBase or 'lrRoot',
		( tonumber( settings.fp_skipLevels ) or 0 ) + ( tonumber( colSettings.extraSkipLevels ) or 0 ),
		tonumber( settings.fp_maxDepth ) or 0 )

	local isVirtualCopy = photo:getRawMetadata( 'isVirtualCopy' )
	local copyName = isVirtualCopy and photo:getFormattedMetadata( 'copyName' ) or nil
	if copyName == '' then
		copyName = nil
	end

	local ctx = {
		filename = LrPathUtils.leafName( path ),
		copyName = copyName,
		folderName = LrPathUtils.leafName( LrPathUtils.parent( path ) ),
		folderPath = mirrored,
		date = dateParts( FPMapping.captureTime( photo ) ),
		collection = colCtx.name,
		collectionPath = colCtx.path,
		service = serviceName,
		formatted = safeGetter( photo, 'getFormattedMetadata' ),
		raw = safeGetter( photo, 'getRawMetadata' ),
	}

	local subfolder, unknownSub = FPCore.expandTemplate( colSettings.subfolder or '', ctx )

	local mode = settings.fp_fileNaming or 'library'
	local name, unknownName
	local nameKnown = true
	if mode == 'template' then
		name, unknownName = FPCore.expandTemplate( settings.fp_template or '{FilenameBase}', ctx )
	elseif mode == 'lightroom' then
		if renderedPath then
			name = LrPathUtils.removeExtension( LrPathUtils.leafName( renderedPath ) )
		else
			name = FPCore.splitExtension( ctx.filename )
			nameKnown = false
		end
	else
		name = FPCore.splitExtension( ctx.filename )
	end

	if copyName and settings.fp_virtualCopySuffix ~= false and mode ~= 'lightroom' then
		name = name .. ' (' .. copyName .. ')'
	end

	for _, list in ipairs { unknownSub or {}, unknownName or {} } do
		for _, token in ipairs( list ) do
			if not warnedTemplates[ token ] then
				warnedTemplates[ token ] = true
				logger:warn( 'Unknown template token: {' .. token .. '}' )
			end
		end
	end

	local folders = mirrored
	if colSettings.structure == 'flatten' then
		folders = {}
	end

	local stem = FPCore.buildRelativePath {
		subfolder = subfolder,
		folders = folders,
		name = name,
	}
	return stem, nameKnown
end

local FORMAT_EXTENSIONS = {
	JPEG = 'jpg', TIFF = 'tif', PSD = 'psd', DNG = 'dng', PNG = 'png',
	AVIF = 'avif', JXL = 'jxl', JPEGXL = 'jxl', HEIC = 'heic',
}

--- Best guess of the extension Lightroom will use (for previews only).
function FPMapping.guessExtension( settings, photo )
	local format = settings.LR_format
	if format == 'ORIGINAL' or not format then
		local _, ext = FPCore.splitExtension( LrPathUtils.leafName( photo:getRawMetadata( 'path' ) ) )
		return ext and string.lower( ext ) or ''
	end
	return FORMAT_EXTENSIONS[ format ] or string.lower( format )
end

--------------------------------------------------------------------------------
-- Walking a publish service

--- Calls fn( collection ) for every published collection in a service.
function FPMapping.eachCollection( container, fn )
	for _, collection in ipairs( container:getChildCollections() ) do
		fn( collection )
	end
	for _, set in ipairs( container:getChildCollectionSets() ) do
		FPMapping.eachCollection( set, fn )
	end
end

--- Builds the claim table (pathKey -> { [photoLocalId] = count }) of every
-- published file of a service.
function FPMapping.buildClaims( service )
	local claims = {}
	FPMapping.eachCollection( service, function( collection )
		for _, published in ipairs( collection:getPublishedPhotos() ) do
			local remoteId = published:getRemoteId()
			if remoteId then
				FPCore.claim( claims, remoteId, published:getPhoto().localIdentifier )
			end
		end
	end )
	return claims
end

--- Set of pathKeys referenced by collections of a service, optionally
-- ignoring one collection (by local identifier).
function FPMapping.collectReferences( service, excludeCollectionId )
	local refs = {}
	FPMapping.eachCollection( service, function( collection )
		if collection.localIdentifier ~= excludeCollectionId then
			for _, published in ipairs( collection:getPublishedPhotos() ) do
				local remoteId = published:getRemoteId()
				if remoteId then
					refs[ FPCore.pathKey( remoteId ) ] = true
				end
			end
		end
	end )
	return refs
end

return FPMapping
