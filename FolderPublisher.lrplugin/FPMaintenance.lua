--[[----------------------------------------------------------------------------
FPMaintenance.lua
Maintenance commands (Library > Plug-in Extras):
  * find photos whose published file is missing, or whose target path
    changed (photo renamed or moved in Lightroom, settings changed), and mark
    them for republishing;
  * find files in the publish tree that no published photo refers to;
  * check, then publish every collection of a service in one go.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local FPCore = require 'FPCore'
local FPFiles = require 'FPFiles'
local FPMapping = require 'FPMapping'
local FPSettings = require 'FPSettings'
local FPSummary = require 'FPSummary'
local FPText = require 'FPText'
local logger = require 'FPLog'

local T = FPText.T

local FPMaintenance = {}

local PLUGIN_TITLE = 'Folder Publisher'

--------------------------------------------------------------------------------
-- Choosing a publish service

--- Lets the user pick one of this plug-in's publish services.
-- Returns the service, or nil if there is none / the user cancelled.
function FPMaintenance.chooseService( actionTitle )
	local catalog = LrApplication.activeCatalog()
	local services = catalog:getPublishServices( _PLUGIN.id )
	if #services == 0 then
		LrDialogs.message( PLUGIN_TITLE, T( 'Maint/NoService',
			'There is no Folder Publisher publish service in this catalog yet.' ), 'info' )
		return nil
	end
	if #services == 1 then
		return services[1]
	end

	local chosen
	LrFunctionContext.callWithContext( 'FolderPublisher.chooseService', function( context )
		local props = LrBinding.makePropertyTable( context )
		local items = {}
		for i, service in ipairs( services ) do
			items[i] = { title = service:getName(), value = i }
		end
		props.index = 1
		local f = LrView.osFactory()
		local result = LrDialogs.presentModalDialog {
			title = actionTitle,
			contents = f:row {
				bind_to_object = props,
				f:static_text { title = T( 'Maint/ServiceLabel', 'Publish service:' ) },
				f:popup_menu { value = LrView.bind 'index', items = items },
			},
		}
		if result == 'ok' then
			chosen = services[ props.index ]
		end
	end )
	return chosen
end

local function rootOf( service )
	local settings = service:getPublishSettings()
	local root = FPFiles.expandRoot( settings.fp_root )
	if root == '' or not FPFiles.isDirectory( root ) then
		return nil, settings, root
	end
	return root, settings
end

local function stripExtension( rel )
	local dir, file = rel:match( '^(.*/)([^/]*)$' )
	if not dir then
		dir, file = '', rel
	end
	return dir .. ( FPCore.splitExtension( file ) )
end

local function dirOf( rel )
	return rel:match( '^(.*)/[^/]*$' ) or ''
end

--------------------------------------------------------------------------------
-- Moved / renamed / missing photos

--- Checks the published photos of one collection.
-- Returns arrays of LrPublishedPhoto: moved, missing.
local function checkCollection( service, collection, root, settings, topFolders, overrides, progress )
	local colCtx = FPMapping.collectionContext( collection, overrides )
	local serviceName = service:getName()
	local moved, missing = {}, {}
	if progress then
		progress:setCaption( collection:getName() )
	end

	for _, pp in ipairs( collection:getPublishedPhotos() ) do
		if progress and progress:isCanceled() then
			break
		end

		local rel = pp:getRemoteId()
		if rel and FPCore.isSafeRelative( rel ) then
			local photo = pp:getPhoto()
			local ok, stem, nameKnown = LrTasks.pcall( FPMapping.targetStem, photo, settings, colCtx,
				topFolders, nil, serviceName )
			if ok then
				local _, ext = FPCore.splitExtension( rel:match( '[^/]*$' ) )
				local expected = stem .. ( ext and ( '.' .. ext ) or '' )
				local matches
				if nameKnown then
					matches = FPCore.matchesTarget( rel, expected )
				else
					matches = FPCore.pathKey( dirOf( rel ) ) == FPCore.pathKey( dirOf( stripExtension( expected ) ) )
				end
				if not matches then
					moved[ #moved + 1 ] = pp
				elseif root and not FPFiles.exists( FPFiles.absolute( root, rel ) ) then
					missing[ #missing + 1 ] = pp
				end
			else
				logger:warn( 'Could not compute target of ' .. tostring( rel ) .. ': ' .. tostring( stem ) )
			end
		end
	end

	return moved, missing
end

local function markForRepublish( publishedPhotos )
	local toMark = {}
	for _, pp in ipairs( publishedPhotos ) do
		if not pp:getEditedFlag() then
			toMark[ #toMark + 1 ] = pp
		end
	end
	if #toMark == 0 then
		return 0
	end
	LrApplication.activeCatalog():withWriteAccessDo( T( 'Maint/MarkUndo', 'Mark Photos to Republish' ), function()
		for _, pp in ipairs( toMark ) do
			pp:setEditedFlag( true )
		end
	end, { timeout = 60 } )
	return #toMark
end

--- Called after a collection's settings or name changed: silently marks the
-- photos whose target moved.
function FPMaintenance.recheckCollection( service, collection, overrides )
	local root, settings = rootOf( service )
	local catalog = LrApplication.activeCatalog()
	local moved = checkCollection( service, collection, nil, settings, FPMapping.topFolders( catalog ), overrides )
	local n = markForRepublish( moved )
	if n > 0 then
		logger:info( string.format( '%d photo(s) of "%s" marked for republishing after a settings change',
			n, collection:getName() ) )
	end
	return n, root
end

local function rootMissing( wantedRoot )
	LrDialogs.message( PLUGIN_TITLE,
		T( 'Maint/RootMissing', 'The publish folder was not found:\n^1\n\nConnect the drive, or fix the '
			.. 'folder in the publish service settings.', tostring( wantedRoot ) ),
		'warning' )
end

--- Finds the published photos of a service that were renamed or moved, or
-- whose file is missing. Returns moved, missing, canceled.
local function scanService( service, root, settings )
	local catalog = LrApplication.activeCatalog()
	local topFolders = FPMapping.topFolders( catalog )
	local progress = LrProgressScope {
		title = T( 'Maint/CheckProgress', 'Checking published photos of "^1"', service:getName() ),
	}

	local collections = {}
	FPMapping.eachCollection( service, function( c ) collections[ #collections + 1 ] = c end )

	local moved, missing = {}, {}
	for i, collection in ipairs( collections ) do
		if progress:isCanceled() then
			break
		end
		local m, x = checkCollection( service, collection, root, settings, topFolders, nil, progress )
		for _, pp in ipairs( m ) do moved[ #moved + 1 ] = pp end
		for _, pp in ipairs( x ) do missing[ #missing + 1 ] = pp end
		progress:setPortionComplete( i, #collections )
	end
	local canceled = progress:isCanceled()
	progress:done()
	return moved, missing, canceled, collections
end

local function concat( a, b )
	local out = {}
	for _, x in ipairs( a ) do out[ #out + 1 ] = x end
	for _, x in ipairs( b ) do out[ #out + 1 ] = x end
	return out
end

--- Menu command: checks every collection of a service.
function FPMaintenance.checkService( service )
	local root, settings, wantedRoot = rootOf( service )
	if not root then
		rootMissing( wantedRoot )
		return
	end

	local moved, missing, canceled = scanService( service, root, settings )
	if canceled then
		return
	end
	local all = concat( moved, missing )
	local marked = markForRepublish( all )

	if #all == 0 then
		LrDialogs.message( PLUGIN_TITLE, T( 'Maint/AllGood', 'All published files are where they should be.' ), 'info' )
	else
		LrDialogs.message( PLUGIN_TITLE,
			FPText.count( #moved, 'Maint/Moved', '1 photo was renamed, moved or now maps to a different path.',
				'^1 photos were renamed, moved or now map to a different path.' ) .. '\n'
			.. FPText.count( #missing, 'Maint/Missing', '1 published file is missing on disk.',
				'^1 published files are missing on disk.' ) .. '\n\n'
			.. FPText.count( marked, 'Maint/Marked',
				'1 photo was marked for republishing. Publish the service to update the folder.',
				'^1 photos were marked for republishing. Publish the service to update the folder.' ),
			'info' )
	end
end

--- Menu command: finds renamed, moved and missing photos, then publishes
-- every collection of the service, one after the other, with one summary.
function FPMaintenance.checkAndPublish( service )
	local root, settings, wantedRoot = rootOf( service )
	if not root then
		rootMissing( wantedRoot )
		return
	end

	local moved, missing, canceled, collections = scanService( service, root, settings )
	if canceled then
		return
	end
	markForRepublish( concat( moved, missing ) )

	local progress = LrProgressScope {
		title = T( 'Maint/PublishProgress', 'Publishing "^1"', service:getName() ),
	}
	FPSummary.beginBatch { flagged = #moved, missing = #missing }
	local ok, err = LrTasks.pcall( function()
		for i, collection in ipairs( collections ) do
			if progress:isCanceled() then
				break
			end
			progress:setCaption( collection:getName() )
			local done = false
			collection:publishNow( function() done = true end )
			while not done do
				LrTasks.sleep( 0.5 )
			end
			progress:setPortionComplete( i, #collections )
		end
	end )
	progress:done()
	FPSummary.endBatch( service:getName(), FPSettings.get( settings, 'fp_showSummary' ) )
	if not ok then
		error( err, 0 )
	end
end

--------------------------------------------------------------------------------
-- Orphaned files

--- Menu command: lists files under the root that no published photo uses and
-- offers to remove them.
function FPMaintenance.cleanOrphans( service )
	local root, _, wantedRoot = rootOf( service )
	if not root then
		rootMissing( wantedRoot )
		return
	end

	local progress = LrProgressScope {
		title = T( 'Maint/OrphanProgress', 'Looking for orphaned files in "^1"', service:getName() ),
	}

	local known, knownStems = {}, {}
	FPMapping.eachCollection( service, function( collection )
		for _, pp in ipairs( collection:getPublishedPhotos() ) do
			local rel = pp:getRemoteId()
			if rel then
				known[ FPCore.pathKey( rel ) ] = true
				knownStems[ FPCore.pathKey( stripExtension( rel ) ) ] = true
			end
		end
	end )

	local orphans = {}
	for path in LrFileUtils.recursiveFiles( root ) do
		if progress:isCanceled() then
			break
		end
		local below = FPCore.componentsBelow( path, root )
		if below and #below > 0 and not FPFiles.isJunkFile( path ) then
			local rel = table.concat( below, '/' )
			local key = FPCore.pathKey( rel )
			local isSidecar = string.lower( LrPathUtils.extension( path ) ) == 'xmp'
				and knownStems[ FPCore.pathKey( stripExtension( rel ) ) ]
			if not known[ key ] and not isSidecar then
				orphans[ #orphans + 1 ] = path
			end
		end
	end
	local canceled = progress:isCanceled()
	progress:done()
	if canceled then
		return
	end

	if #orphans == 0 then
		LrDialogs.message( PLUGIN_TITLE, T( 'Maint/NoOrphans', 'No orphaned files were found in\n^1', root ), 'info' )
		return
	end

	local shown = {}
	for i = 1, math.min( #orphans, 15 ) do
		shown[i] = '  ' .. table.concat( FPCore.componentsBelow( orphans[i], root ), '/' )
	end
	local answer = LrDialogs.confirm(
		FPText.count( #orphans, 'Maint/OrphansFound',
			'1 file in the publish folder is not used by any published photo',
			'^1 files in the publish folder are not used by any published photo' ),
		table.concat( shown, '\n' ) .. ( #orphans > 15 and '\n  …' or '' ) .. '\n\n'
			.. T( 'Maint/OrphansWhy', 'They may be left over from earlier publishes, or files you put there yourself.' ),
		MAC_ENV and T( 'Common/MoveToTrash', 'Move to Trash' ) or T( 'Common/MoveToRecycleBin', 'Move to Recycle Bin' ),
		T( 'Common/Cancel', 'Cancel' ),
		T( 'Common/Delete', 'Delete' ) )
	if answer == 'cancel' then
		return
	end
	local mode = answer == 'ok' and 'trash' or 'delete'

	local failed = 0
	local dirs = {}
	for _, path in ipairs( orphans ) do
		if FPFiles.remove( path, mode ) then
			dirs[ LrPathUtils.parent( path ) ] = true
		else
			failed = failed + 1
		end
	end
	for dir in pairs( dirs ) do
		FPFiles.pruneEmptyFolders( dir, root )
	end

	local text = FPText.count( #orphans - failed, 'Maint/OrphansRemoved', '1 file removed.', '^1 files removed.' )
	if failed > 0 then
		text = text .. ' ' .. FPText.count( failed, 'Maint/OrphansFailed', '1 could not be removed (see the log).',
			'^1 could not be removed (see the log).' )
	end
	LrDialogs.message( PLUGIN_TITLE, text, 'info' )
end

return FPMaintenance
