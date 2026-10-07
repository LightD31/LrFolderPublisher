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
local logger = require 'FPLog'

local provider = {}

--------------------------------------------------------------------------------
-- General service description

provider.supportsIncrementalPublish = 'only'
provider.hideSections = { 'exportLocation' }
provider.canExportVideo = true
provider.exportPresetFields = FPSettings.exportPresetFields
provider.small_icon = 'icon.png'
provider.titleForGoToPublishedCollection = MAC_ENV and 'Show in Finder' or 'Show in Explorer'
provider.titleForGoToPublishedPhoto = MAC_ENV and 'Show in Finder' or 'Show in Explorer'
provider.supportsCustomSortOrder = false

provider.startDialog = FPDialogs.startDialog
provider.sectionsForTopOfDialog = FPDialogs.sectionsForTopOfDialog
provider.sectionsForBottomOfDialog = FPDialogs.sectionsForBottomOfDialog

function provider.getCollectionBehaviorInfo( publishSettings )
	return {
		defaultCollectionName = 'Mirrored Photos',
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
	}
end

function provider.metadataThatTriggersRepublish( publishSettings )
	local triggers = {}
	for _, trigger in ipairs( FPSettings.republishTriggers ) do
		local value = publishSettings and publishSettings[ 'fp_trig_' .. trigger.key ]
		if value == nil then
			for _, field in ipairs( FPSettings.exportPresetFields ) do
				if field.key == 'fp_trig_' .. trigger.key then
					value = field.default
				end
			end
		end
		triggers[ trigger.key ] = value and true or false
	end
	return triggers
end

--------------------------------------------------------------------------------
-- Per-collection settings

function provider.viewForCollectionSettings( f, publishSettings, info )
	local collectionSettings = assert( info.collectionSettings )
	FPSettings.applyCollectionDefaults( collectionSettings )
	return FPDialogs.collectionSettingsView( f, collectionSettings )
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
	recheckLater( info, { settings = info.collectionSettings } )
end

function provider.renamePublishedCollection( publishSettings, info )
	recheckLater( info, { name = info.name } )
end

--------------------------------------------------------------------------------
-- Publishing

local function resolveRoot( publishSettings )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	if root == '' then
		LrErrors.throwUserError( 'No root folder is set for this publish service. '
			.. 'Edit the publish service settings and choose one.' )
	end
	if not FPFiles.isDirectory( root ) then
		local answer = LrDialogs.confirm(
			'The publish root folder does not exist',
			root .. '\n\nIf it is on an external or network drive, make sure the drive is '
				.. 'connected before publishing. Otherwise the folder can be created now.',
			'Create Folder', 'Cancel' )
		if answer ~= 'ok' then
			LrErrors.throwUserError( 'Publishing cancelled: the root folder ' .. root .. ' was not found.' )
		end
		LrFileUtils.createAllDirectories( root )
		if not FPFiles.isDirectory( root ) then
			LrErrors.throwUserError( 'Could not create the root folder ' .. root )
		end
	end
	return root
end

function provider.processRenderedPhotos( functionContext, exportContext )
	local exportSession = exportContext.exportSession
	local settings = exportContext.propertyTable
	local catalog = LrApplication.activeCatalog()

	local nPhotos = exportSession:countRenditions()
	local progressScope = exportContext:configureProgress {
		title = nPhotos > 1 and string.format( 'Publishing %d photos to folder', nPhotos )
			or 'Publishing one photo to folder',
	}

	local root = resolveRoot( settings )
	local topFolders = FPMapping.topFolders( catalog )

	local service = exportContext.publishService
	local collection = exportContext.publishedCollection
	local colCtx
	if collection then
		colCtx = FPMapping.collectionContext( collection )
	else
		local info = exportContext.publishedCollectionInfo or {}
		logger:warn( 'No published collection in export context; using default collection settings' )
		colCtx = FPMapping.collectionContext( nil, { name = info.name } )
	end
	local serviceName = service and service:getName() or ''
	local claims = service and FPMapping.buildClaims( service ) or {}

	-- "Leave on disk" applies to photos removed from the service; a photo that
	-- merely moved would otherwise leave a stale duplicate behind.
	local onMove = settings.fp_onRemove == 'trash' and 'trash' or 'delete'
	local prune = settings.fp_pruneEmptyFolders ~= false
	local setCaptureDate = settings.fp_fileDate == 'capture'

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local photo = rendition.photo
		local ok, pathOrMessage = rendition:waitForRender()

		if progressScope:isCanceled() then
			break
		end

		if not ok then
			rendition:uploadFailed( pathOrMessage )
		else
			local success, err = LrTasks.pcall( function()
				local ownerId = photo.localIdentifier
				local stem = FPMapping.targetStem( photo, settings, colCtx, topFolders, pathOrMessage, serviceName )
				local ext = LrPathUtils.extension( pathOrMessage )
				local wanted = stem .. ( ext ~= '' and ( '.' .. string.lower( ext ) ) or '' )

				local previous = rendition.publishedPhotoId
				if previous and not FPCore.isSafeRelative( previous ) then
					previous = nil
				end

				-- Keep the previous name if it is still the right target (it may
				-- carry a collision suffix such as "-2").
				local rel
				if previous and FPCore.matchesTarget( previous, wanted ) then
					rel = previous
				else
					rel = FPCore.resolveCollision( wanted, ownerId, claims )
				end

				local dest = FPFiles.absolute( root, rel )
				local placed, placeErr = FPFiles.place( pathOrMessage, dest )
				if not placed then
					error( placeErr, 0 )
				end

				-- Raw originals come with an .xmp sidecar.
				local sidecar = LrPathUtils.replaceExtension( pathOrMessage, 'xmp' )
				if FPCore.usesXmpSidecar( ext ) and FPFiles.exists( sidecar ) then
					FPFiles.place( sidecar, LrPathUtils.replaceExtension( dest, 'xmp' ) )
				end

				if setCaptureDate then
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
							local old = FPFiles.absolute( root, previous )
							FPFiles.removePublished( old, onMove )
							if prune then
								FPFiles.pruneEmptyFolders( LrPathUtils.parent( old ), root )
							end
						end
					end
				end

				rendition:recordPublishedPhotoId( rel )
				rendition:recordPublishedPhotoUrl( FPCore.fileUrl( dest ) )
			end )

			if not success then
				logger:error( 'Publishing ' .. tostring( photo:getRawMetadata( 'path' ) ) .. ' failed: ' .. tostring( err ) )
				rendition:uploadFailed( tostring( err ) )
			end
		end
	end

	progressScope:done()
end

--------------------------------------------------------------------------------
-- Removing photos

local function removeRemoteIds( publishSettings, remoteIds, refs, removedCallback, progress )
	local root = FPFiles.expandRoot( publishSettings.fp_root )
	local mode = publishSettings.fp_onRemove or 'delete'
	local prune = publishSettings.fp_pruneEmptyFolders ~= false
	local failures = {}
	local dirs = {}

	for i, remoteId in ipairs( remoteIds ) do
		local removed = true
		if mode ~= 'keep' and root ~= '' and FPCore.isSafeRelative( remoteId )
			and not refs[ FPCore.pathKey( remoteId ) ] then
			local path = FPFiles.absolute( root, remoteId )
			removed = FPFiles.removePublished( path, mode )
			if removed then
				dirs[ LrPathUtils.parent( path ) ] = true
			else
				failures[ #failures + 1 ] = path
			end
		end
		if removed and removedCallback then
			removedCallback( remoteId )
		end
		if progress then
			progress:setPortionComplete( i, #remoteIds )
		end
	end

	if prune and mode ~= 'keep' then
		for dir in pairs( dirs ) do
			FPFiles.pruneEmptyFolders( dir, root )
		end
	end

	if #failures > 0 then
		local list = table.concat( failures, '\n', 1, math.min( #failures, 10 ) )
		LrDialogs.message( 'Some published files could not be removed',
			list .. ( #failures > 10 and '\n…' or '' )
				.. '\n\nThey stay listed as "Deleted Photos to Remove" so you can retry. If moving to '
				.. 'the Trash is not supported on this drive, change the removal option '
				.. 'in the publish service settings.',
			'warning' )
	end
end

function provider.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	local refs = {}
	if publishSettings.fp_onRemove ~= 'keep' then
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
	removeRemoteIds( publishSettings, arrayOfPhotoIds, refs, deletedCallback )
end

function provider.deletePublishedCollection( publishSettings, info )
	if publishSettings.fp_onRemove == 'keep' or not info or not info.photoIds then
		return
	end
	LrFunctionContext.callWithContext( 'FolderPublisher.deletePublishedCollection', function( context )
		local progress = LrDialogs.showModalProgressDialog {
			title = 'Removing published files of "' .. tostring( info.name ) .. '"',
			functionContext = context,
		}
		-- Files still used by another collection of the service are kept. If
		-- Lightroom doesn't tell us which collection is going away, its own
		-- entries count as references too, so nothing is deleted: the
		-- "Clean Up Orphaned Files" command can remove those files later.
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
		removeRemoteIds( publishSettings, info.photoIds, refs, nil, progress )
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
		LrDialogs.message( 'The published file was not found', path, 'info' )
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
		LrDialogs.message( 'The publish folder was not found', target, 'info' )
	end
end

return provider
