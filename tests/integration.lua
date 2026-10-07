-- End-to-end tests of the publish service against a stubbed Lightroom SDK
-- and a real temporary folder. Run from the repository root with:
--   lua5.1 tests/integration.lua

package.path = 'FolderPublisher.lrplugin/?.lua;tests/?.lua;' .. package.path

local stub = require 'lrstub'
local FPSettings = require 'FPSettings'

local passed, failed = 0, 0

local base = stub.lines( 'mktemp -d' )[1]
local LIB = '/lib/Photos'

local function exists( rel )
	return stub.run( 'test -e ' .. stub.shq( stub.root .. '/' .. rel ) )
end

local function treeOf()
	local out = {}
	for _, p in ipairs( stub.lines( 'cd ' .. stub.shq( stub.root ) .. ' && find . -type f | sort' ) ) do
		out[ #out + 1 ] = p:sub( 3 )
	end
	return table.concat( out, '\n' )
end

local function check( cond, msg )
	if not cond then
		error( msg or 'check failed', 2 )
	end
end

local function eq( a, b, msg )
	if a ~= b then
		error( ( msg or '' ) .. '\nexpected: ' .. tostring( b ) .. '\n     got: ' .. tostring( a ), 2 )
	end
end

local function defaults( overrides )
	local s = {}
	for _, field in ipairs( FPSettings.exportPresetFields ) do
		s[ field.key ] = field.default
	end
	for k, v in pairs( overrides or {} ) do
		s[ k ] = v
	end
	return s
end

local caseNo = 0
local provider

-- Fresh root/catalog for every test.
local function setup( settingsOverrides, collectionSpecs )
	caseNo = caseNo + 1
	stub.root = base .. '/root' .. caseNo
	stub.temp = base .. '/temp' .. caseNo
	stub.trash = base .. '/trash' .. caseNo
	stub.trashFails = false
	stub.messages = {}
	stub.confirmAnswers = {}
	stub.run( 'mkdir -p ' .. stub.shq( stub.root ) )
	local settings = defaults( settingsOverrides )
	settings.fp_root = stub.root
	local collections = {}
	for i, spec in ipairs( collectionSpecs or { { name = 'Mirrored Photos' } } ) do
		collections[i] = stub.newCollection( i, spec.name, spec.settings, spec.parent )
	end
	local service = stub.newService( 'Mirror', settings, collections )
	stub.catalog = stub.newCatalog( { LIB, '/other' }, { service } )
	return service, collections
end

local function test( name, fn )
	local ok, err = pcall( fn )
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		if type( err ) == 'table' then
			err = 'user error: ' .. tostring( err.userError )
		end
		print( 'FAIL: ' .. name .. '\n      ' .. tostring( err ) )
	end
end

provider = require 'FolderPublishServiceProvider'
local FPMaintenance = require 'FPMaintenance'

--------------------------------------------------------------------------------

test( 'publishes into a mirrored tree and resolves RAW+JPEG collisions', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/2024/Trip/IMG_1.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/2024/Trip/IMG_1.JPG' )
	local c = stub.newPhoto( 3, LIB .. '/2024/Other/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { a, b, c } )
	eq( #stub.failures, 0, table.concat( stub.failures, '\n' ) )
	eq( treeOf(), 'Photos/2024/Other/IMG_2.jpg\nPhotos/2024/Trip/IMG_1-2.jpg\nPhotos/2024/Trip/IMG_1.jpg' )
	eq( cols[1]:entryFor( b ).remoteId, 'Photos/2024/Trip/IMG_1-2.jpg' )
	check( cols[1]:entryFor( a ).url:match( '^file:///' ), 'url recorded' )

	-- Republishing keeps names stable, whatever the order.
	stub.publish( provider, service, cols[1], { b, a } )
	eq( cols[1]:entryFor( a ).remoteId, 'Photos/2024/Trip/IMG_1.jpg' )
	eq( cols[1]:entryFor( b ).remoteId, 'Photos/2024/Trip/IMG_1-2.jpg' )
	eq( treeOf(), 'Photos/2024/Other/IMG_2.jpg\nPhotos/2024/Trip/IMG_1-2.jpg\nPhotos/2024/Trip/IMG_1.jpg' )
end )

test( 'a photo moved in Lightroom moves on disk and empty folders are pruned', function()
	local service, cols = setup()
	local c = stub.newPhoto( 3, LIB .. '/2024/Other/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { c } )
	check( exists( 'Photos/2024/Other/IMG_2.jpg' ) )
	c.raw.path = LIB .. '/2025/New Name/IMG_2b.CR3'
	stub.publish( provider, service, cols[1], { c } )
	eq( treeOf(), 'Photos/2025/New Name/IMG_2b.jpg' )
	check( not exists( 'Photos/2024' ), 'empty folders pruned' )
end )

test( 'pruning can be disabled', function()
	local service, cols = setup { fp_pruneEmptyFolders = false }
	local c = stub.newPhoto( 3, LIB .. '/2024/Other/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { c } )
	c.raw.path = LIB .. '/2025/IMG_2.CR3'
	stub.publish( provider, service, cols[1], { c } )
	check( exists( 'Photos/2024/Other' ), 'folder kept' )
	check( not exists( 'Photos/2024/Other/IMG_2.jpg' ), 'old file removed' )
end )

test( 'folder base, skip and depth options', function()
	local service, cols = setup { fp_folderBase = 'lrRootContents', fp_skipLevels = 1, fp_maxDepth = 1 }
	local a = stub.newPhoto( 1, LIB .. '/2024/Trip/Day 1/Morning/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	eq( treeOf(), 'Trip/IMG_1.jpg' )

	service, cols = setup { fp_folderBase = 'full' }
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, '/somewhere/else/IMG_9.NEF' ) } )
	eq( treeOf(), 'somewhere/else/IMG_9.jpg' )
end )

test( 'collection sub-folder, flatten and extra skip', function()
	local service, cols = setup( nil, {
		{ name = 'Best', settings = { subfolder = '{CollectionPath}', structure = 'flatten' },
			parent = { getName = function() return 'Portfolio' end, getParent = function() end } },
		{ name = 'Web', settings = { subfolder = 'web/{YYYY}', extraSkipLevels = 2 } },
	} )
	local a = stub.newPhoto( 1, LIB .. '/2024/Trip/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	stub.publish( provider, service, cols[2], { a } )
	eq( treeOf(), 'Portfolio/Best/IMG_1.jpg\nweb/2001/Trip/IMG_1.jpg' )
end )

test( 'virtual copies and templates', function()
	local service, cols = setup { fp_fileNaming = 'template', fp_template = '{YYYY}/{Title|FilenameBase}' }
	local a = stub.newPhoto( 1, LIB .. '/IMG_1.CR3', { formatted = { title = 'Sun: set?' } } )
	local vc = stub.newPhoto( 2, LIB .. '/IMG_1.CR3', { isVirtualCopy = true, formatted = { copyName = 'BW' } } )
	stub.publish( provider, service, cols[1], { a, vc } )
	eq( treeOf(), 'Photos/2001/IMG_1 (BW).jpg\nPhotos/2001/Sun_ set_.jpg' )

	service, cols = setup { fp_virtualCopySuffix = false }
	stub.publish( provider, service, cols[1], { a, vc } )
	eq( treeOf(), 'Photos/IMG_1-2.jpg\nPhotos/IMG_1.jpg' )
end )

test( 'Lightroom file naming uses the rendered name', function()
	local service, cols = setup { fp_fileNaming = 'lightroom' }
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	eq( treeOf(), 'Photos/x/1-IMG_1.jpg' )
end )

test( 'raw originals keep their xmp sidecar', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a }, { ext = 'ORIGINAL', sidecar = true } )
	eq( treeOf(), 'Photos/x/IMG_1.cr3\nPhotos/x/IMG_1.xmp' )
	-- and the sidecar goes away with the photo
	local ids = { cols[1]:entryFor( a ).remoteId }
	provider.deletePhotosFromPublishedCollection( service.settings, ids, function( id )
		cols[1]:removeRemoteId( id )
	end, 1 )
	eq( treeOf(), '' )
end )

test( 'files shared by two collections survive removal from one', function()
	local service, cols = setup( nil, { { name = 'A' }, { name = 'B' } } )
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	stub.publish( provider, service, cols[2], { a } )
	eq( treeOf(), 'Photos/x/IMG_1.jpg' )
	eq( cols[2]:entryFor( a ).remoteId, 'Photos/x/IMG_1.jpg', 'same photo shares the file' )

	local removed = {}
	local function cb( id ) removed[ #removed + 1 ] = id end
	cols[1].entries = {} -- Lightroom has removed the photo from collection A
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/x/IMG_1.jpg' }, cb, 1 )
	eq( #removed, 1 )
	eq( treeOf(), 'Photos/x/IMG_1.jpg', 'still used by B' )

	cols[2].entries = {}
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/x/IMG_1.jpg' }, cb, 2 )
	eq( treeOf(), '' )
	check( not exists( 'Photos' ), 'pruned' )
end )

test( 'a photo moving out of a shared file leaves it to the other collection', function()
	local service, cols = setup( nil, { { name = 'A' }, { name = 'B' } } )
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	stub.publish( provider, service, cols[2], { a } )
	cols[1].settings = { subfolder = 'A' }
	stub.publish( provider, service, cols[1], { a } )
	eq( treeOf(), 'A/Photos/x/IMG_1.jpg\nPhotos/x/IMG_1.jpg' )
end )

test( 'removal modes: trash and keep', function()
	local service, cols = setup { fp_onRemove = 'trash' }
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/x/IMG_1.jpg' }, function() end, 1 )
	eq( treeOf(), '' )
	check( stub.run( 'test -e ' .. stub.shq( stub.trash .. '/1-IMG_1.jpg' ) ), 'moved to trash' )

	-- a failing trash keeps the photo listed and warns
	service, cols = setup { fp_onRemove = 'trash' }
	stub.publish( provider, service, cols[1], { a } )
	stub.trashFails = true
	local removed = 0
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/x/IMG_1.jpg' },
		function() removed = removed + 1 end, 1 )
	eq( removed, 0 )
	eq( #stub.messages, 1 )
	eq( treeOf(), 'Photos/x/IMG_1.jpg' )

	service, cols = setup { fp_onRemove = 'keep' }
	stub.publish( provider, service, cols[1], { a } )
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/x/IMG_1.jpg' }, function() end, 1 )
	eq( treeOf(), 'Photos/x/IMG_1.jpg' )

	-- ...but a photo that moves never leaves a duplicate behind
	local b = stub.newPhoto( 2, LIB .. '/y/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { b } )
	b.raw.path = LIB .. '/z/IMG_2.CR3'
	stub.publish( provider, service, cols[1], { b } )
	eq( treeOf(), 'Photos/x/IMG_1.jpg\nPhotos/z/IMG_2.jpg' )
end )

test( 'unsafe remote ids are never used to delete', function()
	local service = setup()
	stub.run( 'mkdir -p ' .. stub.shq( base .. '/victim' ) .. ' && touch ' .. stub.shq( base .. '/victim/f' ) )
	provider.deletePhotosFromPublishedCollection( service.settings, { '../victim/f', '/etc/passwd' }, function() end, 1 )
	check( stub.run( 'test -e ' .. stub.shq( base .. '/victim/f' ) ) )
end )

test( 'deleting a collection removes its files', function()
	local service, cols = setup( nil, { { name = 'A' }, { name = 'B' } } )
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/x/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { a, b } )
	stub.publish( provider, service, cols[2], { b } )
	provider.deletePublishedCollection( service.settings, {
		name = 'A', photoIds = { 'Photos/x/IMG_1.jpg', 'Photos/x/IMG_2.jpg' },
		publishService = service, publishedCollection = cols[1],
	} )
	eq( treeOf(), 'Photos/x/IMG_2.jpg' )
end )

test( 'missing root: cancel aborts, create works', function()
	local service, cols = setup()
	service.settings.fp_root = base .. '/not-there' .. caseNo
	stub.confirmAnswers = { 'cancel' }
	local ok, err = pcall( stub.publish, provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/a.CR3' ) } )
	check( not ok and type( err ) == 'table' and err.userError, 'user error raised' )
	check( not stub.run( 'test -e ' .. stub.shq( service.settings.fp_root ) ), 'not created' )

	stub.confirmAnswers = { 'ok' }
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/a.CR3' ) } )
	check( stub.run( 'test -e ' .. stub.shq( service.settings.fp_root .. '/Photos/a.jpg' ) ) )
end )

test( 'home-relative root', function()
	local service, cols = setup()
	stub.home = stub.root
	service.settings.fp_root = '~/tree'
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/a.CR3' ) } )
	check( exists( 'tree/Photos/a.jpg' ) )
end )

test( 'capture date is applied to the file', function()
	local service, cols = setup { fp_fileDate = 'capture' }
	-- 2020-01-02 03:04:05 local time, as a Lightroom (Cocoa-epoch) time
	local t = os.time { year = 2020, month = 1, day = 2, hour = 3, min = 4, sec = 5 } - 978307200
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/a.CR3', { dateTimeOriginal = t } ) } )
	local stamp = stub.lines( 'date -r ' .. stub.shq( stub.root .. '/Photos/a.jpg' ) .. ' +%Y%m%d%H%M%S' )[1]
	eq( stamp, '20200102030405' )
end )

test( 'publish replaces an existing file in place', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/a.CR3' )
	stub.publish( provider, service, cols[1], { a }, { content = 'v1' } )
	stub.publish( provider, service, cols[1], { a }, { content = 'v2' } )
	local f = io.open( stub.root .. '/Photos/a.jpg' )
	eq( f:read( '*a' ), 'photo 1 v2' )
	f:close()
end )

test( 'maintenance: detects moved, renamed and missing photos', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/x/IMG_1.JPG' )
	local c = stub.newPhoto( 3, LIB .. '/x/IMG_3.CR3' )
	stub.publish( provider, service, cols[1], { a, b, c } )

	FPMaintenance.checkService( service )
	check( stub.messages[1].text:match( 'where they should be' ), stub.messages[1].text )

	c.raw.path = LIB .. '/y/IMG_3.CR3'                   -- moved in Lightroom
	stub.run( 'rm ' .. stub.shq( stub.root .. '/Photos/x/IMG_1-2.jpg' ) ) -- deleted on disk
	stub.messages = {}
	FPMaintenance.checkService( service )
	check( stub.messages[1].text:match( '^1 photo%(s%) were renamed' ), stub.messages[1].text )
	check( stub.messages[1].text:match( '1 published file%(s%) are missing' ), stub.messages[1].text )
	eq( cols[1]:entryFor( a ).edited, false )
	eq( cols[1]:entryFor( b ).edited, true )
	eq( cols[1]:entryFor( c ).edited, true )
end )

test( 'maintenance: collection setting change marks photos', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	provider.updateCollectionSettings( service.settings, {
		collectionSettings = { subfolder = '' }, publishService = service, publishedCollection = cols[1],
	} )
	eq( cols[1]:entryFor( a ).edited, false )
	provider.updateCollectionSettings( service.settings, {
		collectionSettings = { subfolder = '{Collection}' }, publishService = service, publishedCollection = cols[1],
	} )
	eq( cols[1]:entryFor( a ).edited, true )
end )

test( 'maintenance: orphan clean-up', function()
	local service, cols = setup()
	local a = stub.newPhoto( 1, LIB .. '/x/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a }, { ext = 'ORIGINAL', sidecar = true } )
	stub.run( 'mkdir -p ' .. stub.shq( stub.root .. '/old/deep' ) )
	stub.run( 'touch ' .. stub.shq( stub.root .. '/old/deep/stray.jpg' ) .. ' '
		.. stub.shq( stub.root .. '/Photos/x/.DS_Store' ) .. ' '
		.. stub.shq( stub.root .. '/Photos/x/IMG_9.jpg' ) )
	stub.confirmAnswers = { 'other' } -- "Delete"
	FPMaintenance.cleanOrphans( service )
	check( stub.lastConfirm[1]:match( '^2 file' ), stub.lastConfirm[1] )
	eq( treeOf(), 'Photos/x/.DS_Store\nPhotos/x/IMG_1.cr3\nPhotos/x/IMG_1.xmp' )
	check( not exists( 'old' ), 'empty folders pruned' )
end )

test( 'republish triggers', function()
	local t = provider.metadataThatTriggersRepublish( defaults { fp_trig_default = true, fp_trig_title = false } )
	eq( t.default, true )
	eq( t.title, false )
	eq( t.keywords, true )
	local d = provider.metadataThatTriggersRepublish( nil )
	eq( d.caption, true )
	eq( d.gpsAltitude, false )
end )

test( 'show in Finder', function()
	local service, cols = setup( nil, { { name = 'Best', settings = { subfolder = '{Collection}' } } } )
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/a.CR3' ) } )
	stub.revealed = {}
	provider.goToPublishedPhoto( service.settings, { remoteId = 'Best/Photos/a.jpg' } )
	provider.goToPublishedCollection( service.settings, { publishedCollection = cols[1] } )
	eq( stub.revealed[1], stub.root .. '/Best/Photos/a.jpg' )
	eq( stub.revealed[2], stub.root .. '/Best' )
end )

test( 'dialogs build and preview works', function()
	local service = setup()
	local FPDialogs = require 'FPDialogs'
	local props = defaults { LR_format = 'JPEG' }
	props.fp_root = ''
	function props:addObserver() end
	FPDialogs.startDialog( props )
	check( props.LR_cantExportBecause, 'empty root blocks saving' )
	props.fp_root = stub.root
	FPDialogs.startDialog( props )
	eq( props.LR_cantExportBecause, nil )

	local f = stub.factory
	local top = FPDialogs.sectionsForTopOfDialog( f, props )
	local bottom = FPDialogs.sectionsForBottomOfDialog( f, props )
	eq( #top, 2 )
	eq( #bottom, 2 )

	-- find and press the preview button
	local function find( node, title )
		if type( node ) ~= 'table' then return nil end
		if node.title == title and node.action then return node end
		for _, child in pairs( node ) do
			local found = find( child, title )
			if found then return found end
		end
	end
	local button = assert( find( top, 'Preview with Selected Photo' ) )
	button.action()
	check( props.fp_preview:match( 'Select a photo' ), props.fp_preview )
	stub.catalog.targetPhoto = stub.newPhoto( 1, LIB .. '/2024/IMG_7.CR3' )
	button.action()
	eq( props.fp_preview, 'Photos/2024/IMG_7.jpg' )

	local cs = {}
	provider.viewForCollectionSettings( f, service.settings, { collectionSettings = cs } )
	eq( cs.structure, 'mirror' )
end )

--------------------------------------------------------------------------------

stub.run( 'rm -rf ' .. stub.shq( base ) )
print( string.format( '%d passed, %d failed', passed, failed ) )
os.exit( failed == 0 and 0 or 1 )
