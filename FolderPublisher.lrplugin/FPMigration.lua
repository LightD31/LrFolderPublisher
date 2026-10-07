--[[----------------------------------------------------------------------------
FPMigration.lua
Imports a publish service of another folder-publishing plug-in (typically
Jeffrey Friedl's "jf Folder Publisher") into a Folder Publisher service:

  * recreates its collection sets, collections and smart collections (with
    their rules);
  * detects how each collection laid files out, and sets the equivalent
    collection options;
  * registers every photo whose published file exists under the new
    service's folder as already published, so nothing is re-rendered.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local FPCore = require 'FPCore'
local FPFiles = require 'FPFiles'
local FPMapping = require 'FPMapping'
local FPSettings = require 'FPSettings'
local FPText = require 'FPText'
local logger = require 'FPLog'

local T = FPText.T

local FPMigration = {}

local TITLE = T( 'Import/Title', 'Import from Another Publish Service' )
local SAMPLE_SIZE = 200

--------------------------------------------------------------------------------
-- Choosing services

local function looksLikeFolderPublisher( service )
	local id = string.lower( service:getPluginId() or '' )
	return id:find( 'folder' ) or id:find( 'jfriedl' ) or id:find( 'regex' ) or id:find( 'tree' )
end

-- Shows one dialog to choose the source and destination services.
local function chooseServices( catalog )
	local mine, others = {}, {}
	for _, service in ipairs( catalog:getPublishServices( nil ) ) do
		local id = service:getPluginId() or ''
		if id == _PLUGIN.id or id:sub( 1, #_PLUGIN.id + 1 ) == _PLUGIN.id .. '.' then
			mine[ #mine + 1 ] = service
		else
			others[ #others + 1 ] = service
		end
	end

	if #others == 0 then
		LrDialogs.message( TITLE, T( 'Import/NoSource', 'There is no other publish service in this catalog to import.' ),
			'info' )
		return nil
	end
	if #mine == 0 then
		LrDialogs.message( TITLE,
			T( 'Import/NoDest', 'Create a Folder Publisher service first.\n\nIn the Publish Services panel, '
				.. 'click "Set Up…" next to Folder Publisher, choose the SAME folder as the service you are '
				.. 'importing, then run this command again.' ),
			'info' )
		return nil
	end

	-- Most likely source first.
	table.sort( others, function( a, b )
		local la, lb = looksLikeFolderPublisher( a ) and 1 or 0, looksLikeFolderPublisher( b ) and 1 or 0
		if la ~= lb then
			return la > lb
		end
		return a:getName() < b:getName()
	end )

	local source, destination
	LrFunctionContext.callWithContext( 'FolderPublisher.chooseImport', function( context )
		local props = LrBinding.makePropertyTable( context )
		local sourceItems, destItems = {}, {}
		for i, s in ipairs( others ) do
			sourceItems[i] = { title = s:getName() .. '   (' .. tostring( s:getPluginId() ) .. ')', value = i }
		end
		for i, s in ipairs( mine ) do
			local settings = s:getPublishSettings() or {}
			destItems[i] = { title = s:getName() .. '   → ' .. tostring( settings.fp_root ), value = i }
		end
		props.source = 1
		props.destination = 1

		local f = LrView.osFactory()
		local labelWidth = LrView.share 'importLabel'
		local result = LrDialogs.presentModalDialog {
			title = TITLE,
			actionVerb = T( 'Common/Continue', 'Continue' ),
			contents = f:column {
				bind_to_object = props,
				spacing = f:control_spacing(),
				f:static_text {
					title = T( 'Import/Intro', 'Copies the collections and smart collections of another publish '
						.. 'service into a\nFolder Publisher service. Photos whose files are already in the '
						.. 'destination\nfolder are marked as published, so nothing needs to be exported again.\n'
						.. 'The other service is not changed.' ),
					height_in_lines = 4,
				},
				f:row {
					f:static_text { title = T( 'Import/From', 'Import from:' ), alignment = 'right', width = labelWidth },
					f:popup_menu { value = LrView.bind 'source', items = sourceItems },
				},
				f:row {
					f:static_text { title = T( 'Import/Into', 'Into:' ), alignment = 'right', width = labelWidth },
					f:popup_menu { value = LrView.bind 'destination', items = destItems },
				},
			},
		}
		if result == 'ok' then
			source = others[ props.source ]
			destination = mine[ props.destination ]
		end
	end )
	return source, destination
end

--------------------------------------------------------------------------------
-- Reading the source service

local function isAbsolute( path )
	return path:match( '^[\\/]' ) or path:match( '^%a:[\\/]' )
end

local function fromFileUrl( url )
	local p = tostring( url or '' ):match( '^file://(.*)$' )
	if not p then
		return nil
	end
	p = p:gsub( '%%(%x%x)', function( h ) return string.char( tonumber( h, 16 ) ) end )
	if p:match( '^/%a:/' ) then
		p = p:sub( 2 )
	end
	return p
end

-- Folders mentioned in the source service's settings: candidates for the
-- root its relative ids (if any) are relative to.
local function candidateRoots( settings )
	local roots = {}
	for _, value in pairs( settings or {} ) do
		if type( value ) == 'string' and isAbsolute( value ) and FPFiles.isDirectory( value ) then
			roots[ #roots + 1 ] = value
		end
	end
	return roots
end

-- Absolute path of the file a published photo of the source service points to.
local function publishedPath( published, roots )
	local candidates = {}
	local id = published:getRemoteId()
	if type( id ) == 'string' and id ~= '' then
		candidates[ #candidates + 1 ] = id
	end
	local url = published:getRemoteUrl()
	if url and url ~= '' then
		candidates[ #candidates + 1 ] = fromFileUrl( url ) or url
	end
	for _, c in ipairs( candidates ) do
		if isAbsolute( c ) then
			if FPFiles.exists( c ) then
				return c
			end
		else
			for _, root in ipairs( roots ) do
				local path = FPFiles.absolute( root, c )
				if FPFiles.exists( path ) then
					return path
				end
			end
		end
	end
	return nil, candidates[1]
end

-- Walks a container (service or set) into a tree of plain tables.
local function readTree( container, roots, destRoot, progress )
	local node = { sets = {}, collections = {} }
	for _, collection in ipairs( container:getChildCollections() ) do
		local summary = collection:getCollectionInfoSummary() or {}
		local entry = {
			name = collection:getName(),
			isDefault = summary.isDefaultCollection,
			isSmart = collection:isSmartCollection(),
			photos = {},
		}
		if entry.isSmart then
			entry.searchDesc = collection:getSearchDescription()
		end
		for _, published in ipairs( collection:getPublishedPhotos() ) do
			local path, rawId = publishedPath( published, roots )
			local rel
			if path then
				local below = FPCore.componentsBelow( path, destRoot )
				if below and #below > 0 then
					rel = table.concat( below, '/' )
				end
			end
			entry.photos[ #entry.photos + 1 ] = {
				photo = published:getPhoto(),
				path = path,
				rawId = rawId,
				rel = rel,
				edited = published:getEditedFlag(),
			}
		end
		node.collections[ #node.collections + 1 ] = entry
		if progress then
			progress:setCaption( entry.name )
			if progress:isCanceled() then
				return node
			end
		end
	end
	for _, set in ipairs( container:getChildCollectionSets() ) do
		local child = readTree( set, roots, destRoot, progress )
		child.name = set:getName()
		node.sets[ #node.sets + 1 ] = child
	end
	return node
end

local function eachEntry( node, fn )
	for _, entry in ipairs( node.collections ) do
		fn( entry )
	end
	for _, set in ipairs( node.sets ) do
		eachEntry( set, fn )
	end
end

--------------------------------------------------------------------------------
-- Layout detection

local function dirComponents( rel )
	local comps = {}
	for part in rel:gmatch( '[^/]+' ) do
		comps[ #comps + 1 ] = part
	end
	table.remove( comps ) -- file name
	return comps
end

-- Works out the collection settings that reproduce the existing layout.
local function detectSettings( entry, destSettings, topFolders )
	local samples = {}
	for _, p in ipairs( entry.photos ) do
		if p.rel then
			samples[ #samples + 1 ] = {
				mirrored = FPMapping.serviceFolders( p.photo:getRawMetadata( 'path' ), destSettings, topFolders ),
				actual = dirComponents( p.rel ),
			}
			if #samples >= SAMPLE_SIZE then
				break
			end
		end
	end
	local layout, matched = FPCore.detectLayout( samples )
	local settings = FPSettings.collectionSettings( nil )
	if layout then
		settings.subfolder = table.concat( layout.prefix, '/' )
		if layout.flatten then
			settings.structure = 'flatten'
		else
			settings.extraSkipLevels = layout.lead
			settings.trailingSkipLevels = layout.trail
			settings.append = table.concat( layout.suffix, '/' )
		end
	end
	return settings, matched, #samples
end

-- How many existing files sit exactly where Folder Publisher would put them.
local function countExactMatches( entry, destSettings, topFolders, serviceName )
	local colCtx = {
		name = entry.name,
		path = { entry.name },
		settings = entry.settings,
	}
	local exact, total = 0, 0
	for _, p in ipairs( entry.photos ) do
		if p.rel then
			total = total + 1
			local ok, stem = LrTasks.pcall( FPMapping.targetStem, p.photo, destSettings, colCtx,
				topFolders, nil, serviceName )
			if ok then
				local _, ext = FPCore.splitExtension( p.rel:match( '[^/]*$' ) )
				if FPCore.matchesTarget( p.rel, stem .. ( ext and ( '.' .. ext ) or '' ) ) then
					exact = exact + 1
				end
			end
		end
	end
	return exact, total
end

--------------------------------------------------------------------------------
-- Writing the destination service

local function findDefaultCollection( service )
	for _, collection in ipairs( service:getChildCollections() ) do
		local summary = collection:getCollectionInfoSummary()
		if summary and summary.isDefaultCollection then
			return collection
		end
	end
end

-- Creates sets and collections (inside a write gate). Stores the created
-- collection in entry.target. Regular collections get their photos here.
local function createTree( service, node, parent, defaultCollection, stats )
	for _, entry in ipairs( node.collections ) do
		local target
		if entry.isDefault and not parent and defaultCollection then
			target = defaultCollection
		elseif entry.isSmart then
			target = service:createPublishedSmartCollection( entry.name, entry.searchDesc, parent, true )
		else
			target = service:createPublishedCollection( entry.name, parent, true )
		end
		if target then
			entry.target = target
			target:setCollectionSettings( entry.settings )
			stats.collections = stats.collections + 1
			if not entry.isSmart then
				for _, p in ipairs( entry.photos ) do
					if p.rel then
						target:addPhotoByRemoteId( p.photo, p.rel, FPCore.fileUrl( p.path ), true )
						p.added = true
					else
						target:addPhotos { p.photo }
					end
				end
			end
		else
			stats.failedCollections[ #stats.failedCollections + 1 ] = entry.name
		end
	end
	for _, set in ipairs( node.sets ) do
		local targetSet = service:createPublishedCollectionSet( set.name, parent, true )
		if targetSet then
			createTree( service, set, targetSet, defaultCollection, stats )
		else
			stats.failedCollections[ #stats.failedCollections + 1 ] = T( 'Import/SetSuffix', '^1 (set)', set.name )
		end
	end
end

--------------------------------------------------------------------------------
-- Command

function FPMigration.run()
	local catalog = LrApplication.activeCatalog()
	local source, destination = chooseServices( catalog )
	if not source then
		return
	end

	local destSettings = destination:getPublishSettings() or {}
	local destRoot = FPFiles.expandRoot( destSettings.fp_root )
	if destRoot == '' or not FPFiles.isDirectory( destRoot ) then
		LrDialogs.message( TITLE, T( 'Import/DestMissing', 'The folder of "^1" was not found:\n^2',
			destination:getName(), tostring( destRoot ) ), 'warning' )
		return
	end

	-- 1. Read the source service.
	local progress = LrProgressScope { title = T( 'Import/Reading', 'Reading "^1"', source:getName() ) }
	local roots = candidateRoots( source:getPublishSettings() )
	local tree = readTree( source, roots, destRoot, progress )
	local canceled = progress:isCanceled()
	progress:done()
	if canceled then
		return
	end

	local topFolders = FPMapping.topFolders( catalog )
	local serviceName = destination:getName()
	local nCollections, nPhotos, nFound, nOutside, nMissing = 0, 0, 0, 0, 0
	local example
	eachEntry( tree, function( entry )
		nCollections = nCollections + 1
		entry.settings, entry.matched, entry.sampled = detectSettings( entry, destSettings, topFolders )
		entry.exact, entry.found = countExactMatches( entry, destSettings, topFolders, serviceName )
		for _, p in ipairs( entry.photos ) do
			nPhotos = nPhotos + 1
			if p.rel then
				nFound = nFound + 1
			elseif p.path then
				nOutside = nOutside + 1
				example = example or p.path
			else
				nMissing = nMissing + 1
			end
		end
	end )

	if nPhotos > 0 and nFound == 0 then
		LrDialogs.message( TITLE,
			T( 'Import/NoneInside', 'None of the published files of "^1" are inside\n^2', source:getName(), destRoot )
				.. '\n\n' .. ( example
					and T( 'Import/NoneInsideExample', 'For example, one is at:\n^1\n\nPoint "^2" at the same '
						.. 'folder and try again.', example, destination:getName() )
					or T( 'Import/NoneInsideUnknown', 'Their location could not be determined.' ) ),
			'warning' )
		return
	end

	-- 2. Confirm.
	local lines = {}
	eachEntry( tree, function( entry )
		local s = entry.settings
		local layout
		if s.structure == 'flatten' then
			layout = T( 'Import/LayoutFlat', 'flat' )
		else
			layout = T( 'Import/LayoutStrip', 'strip ^1 leading / ^2 trailing', s.extraSkipLevels, s.trailingSkipLevels )
		end
		if s.subfolder ~= '' then
			layout = layout .. T( 'Import/LayoutBefore', ', before: "^1"', s.subfolder )
		end
		if s.append ~= '' then
			layout = layout .. T( 'Import/LayoutAfter', ', after: "^1"', s.append )
		end
		lines[ #lines + 1 ] = '• ' .. T( 'Import/Line', '^1^2: ^3 photos, ^4/^5 at the expected path (^6)',
			entry.name, entry.isSmart and T( 'Import/Smart', ' (smart)' ) or '', #entry.photos, entry.exact,
			entry.found, layout )
	end )
	local shown = table.concat( lines, '\n', 1, math.min( #lines, 12 ) ) .. ( #lines > 12 and '\n…' or '' )

	local answer = LrDialogs.confirm(
		T( 'Import/Confirm', 'Import ^1 collection(s) and ^2 photo(s) into "^3"?', nCollections, nPhotos, serviceName ),
		T( 'Import/ConfirmFound', '^1 file(s) found in the folder will be marked as published.', nFound ) .. '\n'
			.. ( nOutside + nMissing > 0 and ( T( 'Import/ConfirmNoFile',
				'^1 photo(s) have no file there yet and will be published normally.', nOutside + nMissing ) .. '\n' )
				or '' )
			.. '\n' .. shown .. '\n\n'
			.. T( 'Import/ConfirmNote', 'Photos not "at the expected path" keep their current file until they are '
				.. 'next republished. If many are listed, check the File Names settings of the new service first '
				.. '(for example, use Lightroom\'s File Naming if the old service renamed files).' ),
		T( 'Import/Button', 'Import' ), T( 'Common/Cancel', 'Cancel' ) )
	if answer ~= 'ok' then
		return
	end

	-- 3. Create collections; regular ones get their photos right away.
	local stats = { collections = 0, failedCollections = {} }
	local defaultCollection = findDefaultCollection( destination )
	catalog:withWriteAccessDo( T( 'Import/Undo', 'Import Publish Service' ), function()
		createTree( destination, tree, nil, defaultCollection, stats )
	end, { timeout = 120 } )

	-- 4. Smart collections fill themselves; mark their photos as published.
	local smartPending = false
	eachEntry( tree, function( entry )
		if entry.isSmart and entry.target then
			smartPending = true
			entry.target:getPhotos() -- let Lightroom evaluate the rules
		end
	end )
	local notInSmart = 0
	if smartPending then
		catalog:withWriteAccessDo( T( 'Import/Undo', 'Import Publish Service' ), function()
			eachEntry( tree, function( entry )
				if entry.isSmart and entry.target then
					for _, p in ipairs( entry.photos ) do
						if p.rel then
							local ok = LrTasks.pcall( entry.target.addPhotoByRemoteId, entry.target,
								p.photo, p.rel, FPCore.fileUrl( p.path ), true )
							if ok then
								p.added = true
							else
								notInSmart = notInSmart + 1
							end
						end
					end
				end
			end )
		end, { timeout = 120 } )
	end

	-- 5. Photos that were waiting for a republish in the old service still are.
	local toFlag = {}
	eachEntry( tree, function( entry )
		if entry.target then
			local edited = {}
			for _, p in ipairs( entry.photos ) do
				if p.added and p.edited then
					edited[ p.photo.localIdentifier ] = true
				end
			end
			if next( edited ) then
				for _, published in ipairs( entry.target:getPublishedPhotos() ) do
					if edited[ published:getPhoto().localIdentifier ] then
						toFlag[ #toFlag + 1 ] = published
					end
				end
			end
		end
	end )
	if #toFlag > 0 then
		catalog:withWriteAccessDo( T( 'Import/Undo', 'Import Publish Service' ), function()
			for _, published in ipairs( toFlag ) do
				published:setEditedFlag( true )
			end
		end, { timeout = 60 } )
	end

	local marked = 0
	eachEntry( tree, function( entry )
		for _, p in ipairs( entry.photos ) do
			if p.added then
				marked = marked + 1
			end
		end
	end )

	logger:info( string.format( 'Imported "%s" into "%s": %d collections, %d photos marked published',
		source:getName(), serviceName, stats.collections, marked ) )

	local text = T( 'Import/DoneCreated', '^1 collection(s) created in "^2".', stats.collections, serviceName )
		.. '\n' .. T( 'Import/DoneMarked', '^1 photo(s) marked as already published.', marked )
	if #toFlag > 0 then
		text = text .. '\n' .. T( 'Import/DoneFlagged', '^1 of them were already waiting to be republished.', #toFlag )
	end
	if #stats.failedCollections > 0 then
		text = text .. '\n' .. T( 'Import/DoneFailed', 'Not created (name already used by a set or collection): ^1',
			table.concat( stats.failedCollections, ', ' ) )
	end
	if notInSmart > 0 then
		text = text .. '\n\n' .. T( 'Import/DoneNotInSmart',
			'^1 photo(s) were not (yet) in their smart collection; they will be published normally.', notInSmart )
	end
	text = text .. '\n\n' .. T( 'Import/DoneNext', 'Check the new service, then publish it once: only new and '
		.. 'modified photos are exported.\n\nWhen you are happy with it, disable the old plug-in in the Plug-in '
		.. 'Manager or delete the old service. Do not remove photos or collections from the old service first: '
		.. 'that would delete the published files.' )
	LrDialogs.message( T( 'Import/DoneTitle', 'Import finished' ), text, 'info' )
end

return FPMigration
