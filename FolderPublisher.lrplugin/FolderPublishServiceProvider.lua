--[[----------------------------------------------------------------------------
FolderPublishServiceProvider.lua
Lightroom Classic publish service that mirrors the catalog's folder hierarchy
to a folder on disk.

Each published photo's "remote id" is its path relative to the publish root,
using '/' as separator. Because ids are relative, the root folder can be
moved and the service pointed at the new location without republishing.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrErrors = import 'LrErrors'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrShell = import 'LrShell'
local LrTasks = import 'LrTasks'

local FPCore = require 'FPCore'
local FPDialogs = require 'FPDialogs'
local FPFiles = require 'FPFiles'
local FPMaintenance = require 'FPMaintenance'
local FPMapping = require 'FPMapping'
local FPSettings = require 'FPSettings'
local FPSummary = require 'FPSummary'
local FPText = require 'FPText'
local logger = require 'FPLog'

local T = FPText.T

local provider = {}

--------------------------------------------------------------------------------
-- Diagnostics

-- Runs fn( step, ... ) in protected mode. fn calls step( 'what it does' ) as
-- it goes. If an error escapes, it is logged with the last step and raised
-- again for Lightroom to report: errors raised inside Lightroom itself carry
-- no file or line ("?:0: ..."), so the step is the only clue to where they
-- came from.
local function traced( operation, fn, ... )
	local current = 'starting'
	local function step( what )
		current = what
	end
	local ok, err = LrTasks.pcall( fn, step, ... )
	if not ok then
		if LrErrors.isCanceledError and LrErrors.isCanceledError( err ) then
			logger:info( operation .. ' canceled while ' .. current )
		else
			logger:error( string.format( '%s failed while %s: %s', operation, current, tostring( err ) ) )
		end
		error( err, 0 )
	end
end

local function lightroomVersion()
	local ok, version = LrTasks.pcall( LrApplication.versionString )
	return ok and tostring( version ) or '?'
end

--------------------------------------------------------------------------------
-- General service description

provider.supportsIncrementalPublish = 'only'
provider.hideSections = { 'exportLocation' }
provider.canExportVideo = true
provider.exportPresetFields = FPSettings.exportPresetFields
provider.small_icon = 'icon.png'
provider.titleForGoToPublishedPhoto = MAC_ENV and T( 'Reveal/Finder', 'Show in Finder' )
	or T( 'Reveal/Explorer', 'Show in Explorer' )
provider.supportsCustomSortOrder = false

-- Remove files of photos taken out of the service before writing new ones:
-- frees space first, and lets the publish summary include removals.
function provider.deleteFirstOnPublish()
	return true
end

provider.startDialog = FPDialogs.startDialog
provider.sectionsForTopOfDialog = FPDialogs.sectionsForTopOfDialog
provider.sectionsForBottomOfDialog = FPDialogs.sectionsForBottomOfDialog

function provider.getCollectionBehaviorInfo( publishSettings )
	return {
		defaultCollectionName = T( 'Service/DefaultCollection', 'Mirrored Photos' ),
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
	}
end

function provider.metadataThatTriggersRepublish( publishSettings )
	local triggers = {}
	for _, trigger in ipairs( FPSettings.republishTriggers ) do
		local on = FPSettings.get( publishSettings, 'fp_trig_' .. trigger.id ) and true or false
		for _, key in ipairs( trigger.keys ) do
			triggers[ key ] = on
		end
	end
	return triggers
end

-- Deleting photos from the catalog that are published here.
function provider.shouldDeletePhotosFromServiceOnDeleteFromCatalog( publishSettings, nPhotos )
	local mode = FPSettings.get( publishSettings, 'fp_onCatalogDelete' )
	if mode == 'keep' then
		return 'ignore'
	elseif mode == 'block' then
		LrDialogs.message( T( 'Delete/BlockedTitle', 'These photos are published with Folder Publisher' ),
			T( 'Delete/BlockedText', 'This publish service is set to prevent deleting published photos from '
				.. 'the catalog. Remove them from the publish service first, or change "When it is deleted '
				.. 'from the catalog" under Removing Photos in the service settings.' ),
			'info' )
		return 'cancel'
	end
	return 'delete'
end

--------------------------------------------------------------------------------
-- Per-collection settings

function provider.viewForCollectionSettings( f, publishSettings, info )
	logger:info( 'Collection settings dialog opened for "' .. tostring( info.name ) .. '"' )
	local collectionSettings = assert( info.collectionSettings )
	FPSettings.applyCollectionDefaults( collectionSettings )
	return FPDialogs.collectionSettingsView( f, publishSettings, info )
end

function provider.endDialogForCollectionSettings( publishSettings, info )
	logger:info( string.format( 'Collection settings dialog for "%s" closed (%s)',
		tostring( info and info.name ), tostring( info and info.why ) ) )
	FPDialogs.endCollectionSettings( info )
end

local function recheckLater( info, overrides )
	local service = info and info.publishService
	local collection = info and info.publishedCollection
	if not service or not collection then
		return
	end
	LrTasks.startAsyncTask( function()
		local ok, err = LrTasks.pcall( FPMaintenance.recheckCollection, service, collection, overrides )
		if not ok then
			logger:error( 'Re-checking collection failed: ' .. tostring( err ) )
		end
	end )
end

-- When a collection's path settings or name change, mark the photos whose
-- target path changed so the next publish moves them.
function provider.updateCollectionSettings( publishSettings, info )
	logger:info( 'Settings of collection "' .. tostring( info and info.name ) .. '" changed' )
	recheckLater( info, { settings = info.collectionSettings } )
end

function provider.renamePublishedCollection( publishSettings, info )
	logger:info( 'Collection renamed to "' .. tostring( info and info.name ) .. '"' )
	recheckLater( info, { name = info.name } )
end

--------------------------------------------------------------------------------
-- Publishing

local function resolveRoot( publishSettings )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	if root == '' then
		LrErrors.throwUserError( T( 'Root/NotSet', 'No folder is set for this publish service. '
			.. 'Edit the publish service settings and choose one.' ) )
	end
	if not FPFiles.isDirectory( root ) then
		local answer = LrDialogs.confirm(
			T( 'Root/MissingTitle', 'The publish folder does not exist' ),
			T( 'Root/MissingText', '^1\n\nIf it is on an external or network drive, connect the drive '
				.. 'before publishing. Otherwise the folder can be created now.', root ),
			T( 'Root/Create', 'Create Folder' ), T( 'Common/Cancel', 'Cancel' ) )
		if answer ~= 'ok' then
			LrErrors.throwUserError( T( 'Root/Cancelled', 'Publishing cancelled: the folder ^1 was not found.', root ) )
		end
		LrFileUtils.createAllDirectories( root )
		if not FPFiles.isDirectory( root ) then
			LrErrors.throwUserError( T( 'Root/CreateFailed', 'Could not create the folder ^1', root ) )
		end
	end
	return root
end

local function publishRenderedPhotos( step, exportContext )
	local exportSession = exportContext.exportSession
	local settings = exportContext.propertyTable
	local catalog = LrApplication.activeCatalog()
	local service = exportContext.publishService
	local collection = exportContext.publishedCollection

	step( 'reading the service and collection names' )
	local serviceName = service and service:getName() or ''
	local collectionName = collection and collection:getName()
		or ( exportContext.publishedCollectionInfo or {} ).name or '?'
	logger:info( string.format( 'Publishing "%s" of service "%s" (Lightroom %s)',
		tostring( collectionName ), tostring( serviceName ), lightroomVersion() ) )

	step( 'checking the publish folder' )
	local root = resolveRoot( settings )
	step( 'listing the top-level Lightroom folders' )
	local topFolders = FPMapping.topFolders( catalog )

	-- Photos whose original is offline are left for a later publish rather
	-- than being rendered from a (lower quality) Smart Preview.
	local stats = FPSummary.emptyStats()
	local nListed = 0
	step( 'listing the photos to publish' )
	for photo in exportSession:photosToExport() do
		nListed = nListed + 1
		step( 'checking whether the original of photo #' .. nListed .. ' is online' )
		local path = photo:getRawMetadata( 'path' )
		if not FPFiles.exists( path ) then
			stats.offline = stats.offline + 1
			if #stats.offlinePaths < 10 then
				stats.offlinePaths[ #stats.offlinePaths + 1 ] = path
			end
			step( 'skipping the offline photo ' .. tostring( path ) )
			exportSession:removePhoto( photo )
		end
		step( 'listing the photos to publish' )
	end

	step( 'counting the photos to render' )
	local nPhotos = exportSession:countRenditions()
	logger:info( string.format( '%d photo(s) to publish, %d skipped because their original is offline',
		nPhotos, stats.offline ) )
	step( 'setting up the progress bar' )
	local progressScope = exportContext:configureProgress {
		title = FPText.count( nPhotos, 'Publish/Progress', 'Publishing one photo to folder',
			'Publishing ^1 photos to folder' ),
	}

	step( 'reading the collection settings' )
	local colCtx
	if collection then
		colCtx = FPMapping.collectionContext( collection )
	else
		logger:warn( 'No published collection in export context; using default collection settings' )
		colCtx = FPMapping.collectionContext( nil, { name = collectionName } )
	end
	step( 'reading the files already published by the service' )
	local claims = service and FPMapping.buildClaims( service ) or {}

	-- "Leave on disk" applies to photos removed from the service; a photo that
	-- merely moved would otherwise leave a stale duplicate behind.
	local onMove = settings.fp_onRemove == 'trash' and 'trash' or 'delete'
	local prune = settings.fp_pruneEmptyFolders ~= false
	local setCaptureDate = settings.fp_fileDate == 'capture'

	local nRendition = 0
	step( 'starting to render' )
	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		nRendition = nRendition + 1
		local photo = rendition.photo
		local label = 'photo #' .. nRendition
		step( 'reading the path of ' .. label )
		local photoPath = tostring( photo:getRawMetadata( 'path' ) )
		label = label .. ' (' .. photoPath .. ')'

		step( 'waiting for Lightroom to render ' .. label )
		local ok, pathOrMessage = rendition:waitForRender()

		if progressScope:isCanceled() then
			break
		end

		if not ok then
			stats.failed = stats.failed + 1
			logger:warn( 'Lightroom could not render ' .. photoPath .. ': ' .. tostring( pathOrMessage ) )
			step( 'reporting the failed render of ' .. label )
			rendition:uploadFailed( pathOrMessage )
		else
			step( 'publishing ' .. label )
			local doing = 'computing its target path'
			local success, err = LrTasks.pcall( function()
				local ownerId = photo.localIdentifier
				local stem = FPMapping.targetStem( photo, settings, colCtx, topFolders, pathOrMessage, serviceName )
				local ext = LrPathUtils.extension( pathOrMessage )
				local wanted = stem .. ( ext ~= '' and ( '.' .. string.lower( ext ) ) or '' )

				doing = 'reading its previous published path'
				local previous = rendition.publishedPhotoId
				if previous and not FPCore.isSafeRelative( previous ) then
					previous = nil
				end

				-- Keep the previous name if it is still the right target (it may
				-- carry a collision suffix such as "-2").
				doing = 'choosing a file name'
				local rel
				if previous and FPCore.matchesTarget( previous, wanted ) then
					rel = previous
				else
					rel = FPCore.resolveCollision( wanted, ownerId, claims )
				end

				doing = 'copying the rendered file to ' .. rel
				local dest = FPFiles.absolute( root, rel )
				local placed, placeErr = FPFiles.place( pathOrMessage, dest )
				if not placed then
					error( placeErr, 0 )
				end

				-- Raw originals come with an .xmp sidecar.
				doing = 'copying its .xmp sidecar'
				local sidecar = LrPathUtils.replaceExtension( pathOrMessage, 'xmp' )
				if FPCore.usesXmpSidecar( ext ) and FPFiles.exists( sidecar ) then
					FPFiles.place( sidecar, LrPathUtils.replaceExtension( dest, 'xmp' ) )
				end

				if setCaptureDate then
					doing = 'setting the file date'
					FPFiles.setFileTime( dest, FPMapping.captureTime( photo ) )
				end

				if not previous or FPCore.pathKey( previous ) ~= FPCore.pathKey( rel ) then
					FPCore.claim( claims, rel, ownerId )
					if previous then
						FPCore.unclaim( claims, previous, ownerId )
						-- The photo moved (renamed, moved in Lightroom, or settings
						-- changed): remove the stale copy unless something else
						-- still uses it.
						if not FPCore.isClaimed( claims, previous ) then
							doing = 'removing its previous file ' .. previous
							local old = FPFiles.absolute( root, previous )
							FPFiles.removePublished( old, onMove )
							if prune then
								FPFiles.pruneEmptyFolders( LrPathUtils.parent( old ), root )
							end
						end
					end
				end

				doing = 'recording it as published in Lightroom'
				rendition:recordPublishedPhotoId( rel )
				rendition:recordPublishedPhotoUrl( FPCore.fileUrl( dest ) )

				if not previous then
					stats.new = stats.new + 1
				elseif FPCore.pathKey( previous ) ~= FPCore.pathKey( rel ) then
					stats.moved = stats.moved + 1
				else
					stats.updated = stats.updated + 1
				end
			end )

			if not success then
				stats.failed = stats.failed + 1
				logger:error( 'Publishing ' .. photoPath .. ' failed while ' .. doing .. ': ' .. tostring( err ) )
				step( 'reporting the failed publish of ' .. label )
				rendition:uploadFailed( tostring( err ) )
			end
		end
		step( 'getting the next photo from Lightroom (after ' .. label .. ')' )
	end

	step( 'closing the progress bar' )
	progressScope:done()

	logger:info( string.format( 'Finished "%s": %d new, %d updated, %d moved, %d failed, %d offline',
		tostring( colCtx.name ), stats.new, stats.updated, stats.moved, stats.failed, stats.offline ) )
	step( 'showing the summary' )
	FPSummary.publishFinished( colCtx.name, stats, FPSettings.get( settings, 'fp_showSummary' ) )
end

function provider.processRenderedPhotos( functionContext, exportContext )
	traced( 'Publishing', publishRenderedPhotos, exportContext )
end

--------------------------------------------------------------------------------
-- Removing photos

local function removeRemoteIds( step, publishSettings, remoteIds, refs, removedCallback, progress )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	local mode = publishSettings.fp_onRemove or 'delete'
	local prune = publishSettings.fp_pruneEmptyFolders ~= false
	local failures = {}
	local dirs = {}
	local nRemoved = 0

	for i, remoteId in ipairs( remoteIds ) do
		local removed = true
		step( 'removing the file of ' .. tostring( remoteId ) )
		if mode ~= 'keep' and root ~= '' and FPCore.isSafeRelative( remoteId )
			and not refs[ FPCore.pathKey( remoteId ) ] then
			local path = FPFiles.absolute( root, remoteId )
			removed = FPFiles.removePublished( path, mode )
			if removed then
				nRemoved = nRemoved + 1
				dirs[ LrPathUtils.parent( path ) ] = true
			else
				failures[ #failures + 1 ] = path
			end
		end
		if removed and removedCallback then
			step( 'telling Lightroom that ' .. tostring( remoteId ) .. ' was removed' )
			removedCallback( remoteId )
		end
		if progress then
			progress:setPortionComplete( i, #remoteIds )
		end
	end

	step( 'removing empty folders' )
	if prune and mode ~= 'keep' then
		for dir in pairs( dirs ) do
			FPFiles.pruneEmptyFolders( dir, root )
		end
	end

	FPSummary.recordRemoved( nRemoved )
	logger:info( string.format( '%d file(s) removed, %d could not be removed', nRemoved, #failures ) )

	if #failures > 0 then
		step( 'showing the files that could not be removed' )
		local list = table.concat( failures, '\n', 1, math.min( #failures, 10 ) )
		LrDialogs.message( T( 'Remove/FailedTitle', 'Some published files could not be removed' ),
			list .. ( #failures > 10 and '\n…' or '' ) .. '\n\n'
				.. T( 'Remove/FailedText', 'They stay listed as "Deleted Photos to Remove" so you can retry. '
					.. 'If moving to the Trash is not supported on this drive, change the removal option '
					.. 'in the publish service settings.' ),
			'warning' )
	end
end

local function deletePhotos( step, publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	logger:info( string.format( 'Removing %d photo(s) from collection %s (Lightroom %s)',
		#arrayOfPhotoIds, tostring( localCollectionId ), lightroomVersion() ) )
	local refs = {}
	if publishSettings.fp_onRemove ~= 'keep' then
		step( 'looking for files shared with other collections' )
		local ok, result = LrTasks.pcall( function()
			local catalog = LrApplication.activeCatalog()
			local collection = catalog:getPublishedCollectionByLocalIdentifier( localCollectionId )
			local service = collection and collection:getService()
			return service and FPMapping.collectReferences( service, localCollectionId ) or {}
		end )
		if ok then
			refs = result
		else
			logger:warn( 'Could not check for shared files: ' .. tostring( result ) )
		end
	end
	removeRemoteIds( step, publishSettings, arrayOfPhotoIds, refs, deletedCallback )
end

function provider.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	traced( 'Removing photos', deletePhotos, publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
end

function provider.deletePublishedCollection( publishSettings, info )
	if publishSettings.fp_onRemove == 'keep' or not info or not info.photoIds then
		return
	end
	LrFunctionContext.callWithContext( 'FolderPublisher.deletePublishedCollection', function( context )
		traced( 'Deleting collection "' .. tostring( info.name ) .. '"', function( step )
			step( 'opening the progress dialog' )
			local progress = LrDialogs.showModalProgressDialog {
				title = T( 'Remove/Progress', 'Removing published files of "^1"', tostring( info.name ) ),
				functionContext = context,
			}
			-- Files still used by another collection of the service are kept. If
			-- Lightroom doesn't tell us which collection is going away, its own
			-- entries count as references too, so nothing is deleted: the
			-- "Clean Up Orphaned Files" command can remove those files later.
			step( 'looking for files shared with other collections' )
			local refs = {}
			local collection = info.publishedCollection
			local service = info.publishService or ( collection and collection:getService() )
			if service then
				local ok, result = LrTasks.pcall( FPMapping.collectReferences, service,
					collection and collection.localIdentifier )
				if ok then
					refs = result
				end
			end
			removeRemoteIds( step, publishSettings, info.photoIds, refs, nil, progress )
		end )
	end )
end

--------------------------------------------------------------------------------
-- "Show in Finder / Explorer"

function provider.goToPublishedPhoto( publishSettings, info )
	local remoteId = info.remoteId or ( info.publishedPhoto and info.publishedPhoto:getRemoteId() )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	if remoteId and FPCore.isSafeRelative( remoteId ) then
		local path = FPFiles.absolute( root, remoteId )
		if FPFiles.exists( path ) then
			LrShell.revealInShell( path )
			return
		end
		LrDialogs.message( T( 'Reveal/FileMissing', 'The published file was not found' ), path, 'info' )
	end
end

function provider.goToPublishedCollection( publishSettings, info )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	local target = root
	local collection = info and info.publishedCollection
	if collection then
		local colCtx = FPMapping.collectionContext( collection )
		local subfolder, unknown = FPCore.expandTemplate( colCtx.settings.subfolder or '', {
			collection = colCtx.name,
			collectionPath = colCtx.path,
		} )
		local parts = FPCore.sanitizeRelative( subfolder )
		if #unknown == 0 and #parts > 0 then
			local candidate = FPFiles.absolute( root, table.concat( parts, '/' ) )
			if FPFiles.isDirectory( candidate ) then
				target = candidate
			end
		end
	end
	if FPFiles.isDirectory( target ) then
		LrShell.revealInShell( target )
	else
		LrDialogs.message( T( 'Reveal/FolderMissing', 'The publish folder was not found' ), target, 'info' )
	end
end

return provider
