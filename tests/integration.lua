-- End-to-end tests of the publish service against a stubbed Lightroom SDK
-- and a real temporary folder. Run from the repository root with:
--   lua5.1 tests/integration.lua

package.path = 'FolderPublisher.lrplugin/?.lua;tests/?.lua;' .. package.path

local stub = require 'lrstub'
local FPSettings = require 'FPSettings'
local FPCore = require 'FPCore'

local passed, failed = 0, 0

local base = stub.lines( 'mktemp -d' )[1]
local LIB = base .. '/lib/Photos'

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
	-- Most tests were written with the top-level folder name included.
	if not ( settingsOverrides and settingsOverrides.fp_folderBase ) then
		settings.fp_folderBase = 'lrRoot'
	end
	-- Summaries are tested on their own.
	if not ( settingsOverrides and settingsOverrides.fp_showSummary ) then
		settings.fp_showSummary = 'never'
	end
	stub.prefs = {}
	stub.loadLanguage( nil )
	settings.fp_root = stub.root
	local collections = {}
	for i, spec in ipairs( collectionSpecs or { { name = 'Mirrored Photos' } } ) do
		collections[i] = stub.newCollection( i, spec.name, spec.settings, spec.parent )
	end
	local service = stub.newService( 'Mirror', settings, collections )
	stub.catalog = stub.newCatalog( { LIB, base .. '/other' }, { service } )
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
stub.provider = provider
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
	stub.setPath( c, LIB .. '/2025/New Name/IMG_2b.CR3' )
	stub.publish( provider, service, cols[1], { c } )
	eq( treeOf(), 'Photos/2025/New Name/IMG_2b.jpg' )
	check( not exists( 'Photos/2024' ), 'empty folders pruned' )
end )

test( 'pruning can be disabled', function()
	local service, cols = setup { fp_pruneEmptyFolders = false }
	local c = stub.newPhoto( 3, LIB .. '/2024/Other/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { c } )
	stub.setPath( c, LIB .. '/2025/IMG_2.CR3' )
	stub.publish( provider, service, cols[1], { c } )
	check( exists( 'Photos/2024/Other' ), 'folder kept' )
	check( not exists( 'Photos/2024/Other/IMG_2.jpg' ), 'old file removed' )
end )

test( 'folder base, skip and depth options', function()
	local service, cols = setup { fp_folderBase = 'lrRootContents', fp_skipLevels = 1, fp_maxDepth = 1 }
	local a = stub.newPhoto( 1, LIB .. '/2024/Trip/Day 1/Morning/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	eq( treeOf(), 'Trip/IMG_1.jpg' )

	local depth = #FPCore.splitPath( base )
	service, cols = setup { fp_folderBase = 'full', fp_skipLevels = depth }
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, base .. '/somewhere/else/IMG_9.NEF' ) } )
	eq( treeOf(), 'somewhere/else/IMG_9.jpg' )

	service, cols = setup { fp_folderBase = 'lrRootContents' }
	stub.publish( provider, service, cols[1], { stub.newPhoto( 1, LIB .. '/2024/IMG_1.CR3' ) } )
	eq( treeOf(), '2024/IMG_1.jpg', 'default layout, as in the original plug-in' )
	eq( FPSettings.default( 'fp_folderBase' ), 'lrRootContents' )
end )

test( 'collection sub-folder, flatten and extra skip', function()
	local service, cols = setup( nil, {
		{ name = 'Best', settings = { subfolder = '{CollectionPath}', structure = 'flatten' },
			parent = { getName = function() return 'Portfolio' end, getParent = function() end } },
		{ name = 'Web', settings = { subfolder = 'web/{YYYY}', extraSkipLevels = 2 } },
		{ name = 'Small', settings = { subfolder = 'Web', extraSkipLevels = 1, trailingSkipLevels = 1,
			append = 'small/{Collection}' } },
	} )
	local a = stub.newPhoto( 1, LIB .. '/2024/Trip/IMG_1.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	stub.publish( provider, service, cols[2], { a } )
	eq( treeOf(), 'Portfolio/Best/IMG_1.jpg\nweb/2001/Trip/IMG_1.jpg' )
	-- Photos/2024/Trip -> strip 1 leading, 1 trailing -> 2024
	stub.publish( provider, service, cols[3], { a } )
	check( exists( 'Web/2024/small/Small/IMG_1.jpg' ), treeOf() )
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
	stub.setPath( b, LIB .. '/z/IMG_2.CR3' )
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

	stub.setPath( c, LIB .. '/y/IMG_3.CR3' ) -- moved in Lightroom
	stub.run( 'rm ' .. stub.shq( stub.root .. '/Photos/x/IMG_1-2.jpg' ) ) -- deleted on disk
	stub.messages = {}
	FPMaintenance.checkService( service )
	check( stub.messages[1].text:match( '^1 photo was renamed' ), stub.messages[1].text )
	check( stub.messages[1].text:match( '1 published file is missing' ), stub.messages[1].text )
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
	local t = provider.metadataThatTriggersRepublish( defaults { fp_trig_default = true, fp_trig_title = false,
		fp_trig_creator = true } )
	eq( t.default, true )
	eq( t.title, false )
	eq( t.keywords, true )
	eq( t.creatorEmail, true )
	local d = provider.metadataThatTriggersRepublish( nil )
	eq( d.caption, true )
	eq( d.gpsAltitude, true )
	eq( d.city, true )
	eq( d.rating, false )
	eq( d.default, false )
	-- every key is one documented by the SDK
	local documented = {}
	for k in ( 'default rating label title caption gps gpsAltitude creator creatorJobTitle creatorAddress '
		.. 'creatorCity creatorStateProvince creatorPostalCode creatorCountry creatorPhone creatorEmail '
		.. 'creatorUrl headline iptcSubjectCode descriptionWriter iptcCategory iptcOtherCategories '
		.. 'dateCreated intellectualGenre scene location city stateProvince country isoCountryCode '
		.. 'jobIdentifier instructions provider source copyright rightsUsageTerms copyrightInfoUrl '
		.. 'copyrightStatus keywords customMetadata' ):gmatch( '%S+' ) do
		documented[ k ] = true
	end
	for k in pairs( d ) do
		check( documented[ k ], 'undocumented key ' .. k )
	end
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

test( 'dialogs build, with live examples', function()
	local service = setup()
	local FPDialogs = require 'FPDialogs'
	local props = stub.observable( defaults { LR_format = 'JPEG', fp_root = '' } )
	FPDialogs.startDialog( props )
	check( props.LR_cantExportBecause, 'empty root blocks saving' )
	check( props.fp_exampleDest:match( 'Select a photo' ), props.fp_exampleDest )

	stub.catalog.targetPhoto = stub.newPhoto( 1, LIB .. '/2024/IMG_7.CR3' )
	props.fp_root = stub.root -- observers re-validate and refresh the example
	eq( props.LR_cantExportBecause, nil )
	eq( props.fp_exampleSource, LIB .. '/2024/IMG_7.CR3' )
	eq( props.fp_exampleDest, stub.root .. '/2024/IMG_7.jpg' )
	props.fp_folderBase = 'lrRoot'
	eq( props.fp_exampleDest, stub.root .. '/Photos/2024/IMG_7.jpg' )

	local f = stub.factory
	eq( #FPDialogs.sectionsForTopOfDialog( f, props ), 2 )
	eq( #FPDialogs.sectionsForBottomOfDialog( f, props ), 3 )

	-- collection dialog: example follows the settings as they are edited
	local cs = stub.observable()
	local ctx = stub.observable()
	local info = { collectionSettings = cs, pluginContext = ctx, name = 'Best', parents = { { name = 'Set' } } }
	service.settings.LR_format = 'JPEG'
	provider.viewForCollectionSettings( f, service.settings, info )
	eq( cs.structure, 'mirror' )
	eq( ctx.fp_exampleDest, stub.root .. '/Photos/2024/IMG_7.jpg' )
	cs.subfolder = '{CollectionPath}'
	eq( ctx.fp_exampleDest, stub.root .. '/Set/Best/Photos/2024/IMG_7.jpg' )
	cs.trailingSkipLevels = 1
	cs.append = 'x'
	eq( ctx.fp_exampleDest, stub.root .. '/Set/Best/Photos/x/IMG_7.jpg' )
	eq( cs.fp_exampleDest, nil, 'example not stored in the collection settings' )
end )

test( 'offline originals are skipped, not rendered', function()
	local service, cols = setup { fp_showSummary = 'problems' }
	local a = stub.newPhoto( 1, LIB .. '/a.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/b.CR3' )
	stub.run( 'rm ' .. stub.shq( b.raw.path ) )
	stub.publish( provider, service, cols[1], { a, b } )
	eq( treeOf(), 'Photos/a.jpg' )
	eq( cols[1]:entryFor( b ).remoteId, nil, 'b stays unpublished' )
	eq( #stub.messages, 1 )
	check( stub.messages[1].text:match( '1 photo skipped: original offline' ), stub.messages[1].text )
	check( stub.messages[1].text:match( 'b%.CR3' ), 'offline path listed' )
	eq( stub.messages[1].kind, 'warning' )
end )

test( 'publish summary', function()
	local service, cols = setup { fp_showSummary = 'always' }
	local a = stub.newPhoto( 1, LIB .. '/a.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/b.CR3' )
	stub.publish( provider, service, cols[1], { a, b } )
	eq( #stub.messages, 1 )
	eq( stub.messages[1].title, 'Published "Mirrored Photos"' )
	eq( stub.messages[1].text, '2 new photos published' )

	-- Lightroom removes first (deleteFirstOnPublish), then renders.
	eq( provider.deleteFirstOnPublish(), true )
	stub.messages = {}
	cols[1]:removeRemoteId( 'Photos/b.jpg' )
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/b.jpg' }, function() end, 1 )
	stub.setPath( a, LIB .. '/moved/a.CR3' )
	stub.publish( provider, service, cols[1], { a } )
	eq( stub.messages[1].text, '1 photo moved or renamed\n1 file removed' )

	-- an old removal is not attributed to a later publish
	provider.deletePhotosFromPublishedCollection( service.settings, { 'Photos/moved/a.jpg' }, function() end, 1 )
	stub.clockOffset = 3600
	stub.messages = {}
	stub.publish( provider, service, cols[1], { a } )
	stub.clockOffset = nil
	eq( stub.messages[1].text, '1 photo updated' )

	-- "only when something needs attention"
	service.settings.fp_showSummary = 'problems'
	stub.messages = {}
	stub.publish( provider, service, cols[1], { a } )
	eq( #stub.messages, 0 )
end )

test( 'check & publish', function()
	local service, cols = setup( { fp_showSummary = 'always' }, { { name = 'A' }, { name = 'B' } } )
	local a = stub.newPhoto( 1, LIB .. '/a.CR3' )
	local b = stub.newPhoto( 2, LIB .. '/b.CR3' )
	local c = stub.newPhoto( 3, LIB .. '/c.CR3' )
	stub.publish( provider, service, cols[1], { a, b } )
	cols[2]:add( c ) -- new, not yet published
	stub.setPath( a, LIB .. '/renamed/a2.CR3' ) -- Lightroom doesn't flag this
	stub.run( 'rm ' .. stub.shq( stub.root .. '/Photos/b.jpg' ) ) -- deleted by hand
	stub.messages = {}
	stub.publishedNow = 0

	FPMaintenance.checkAndPublish( service )

	eq( stub.publishedNow, 2, 'each collection published' )
	eq( treeOf(), 'Photos/b.jpg\nPhotos/c.jpg\nPhotos/renamed/a2.jpg' )
	eq( #stub.messages, 1, 'one combined summary' )
	eq( stub.messages[1].title, 'Check & Publish finished for "Mirror"' )
	local text = stub.messages[1].text
	check( text:match( '1 new photo published' ), text )
	check( text:match( '1 photo updated' ), text )
	check( text:match( '1 photo moved or renamed' ), text )
	check( text:match( '1 photo found renamed or moved in Lightroom' ), text )
	check( text:match( '1 published file was missing and was re%-created' ), text )
	eq( stub.prefs.batchStarted, nil, 'batch closed' )
end )

test( 'French translation', function()
	setup()
	stub.loadLanguage( 'fr' )
	local FPText = require 'FPText'
	eq( FPText.T( 'Common/Cancel', 'Cancel' ), 'Annuler' )
	eq( FPText.count( 3, 'Summary/New', '^1 new photo published', '^1 new photos published' ),
		'3 nouvelles photos publiées' )
	eq( FPText.T( 'Root/Cancelled', 'Publishing cancelled: the folder ^1 was not found.', 'X:' ),
		'Publication annulée : le dossier X: est introuvable.' )
	eq( FPText.T( 'Import/Intro', 'x' ):match( '^[^\n]*' ),
		'Copie les collections et collections dynamiques d’un autre service de publication' )
	-- unknown keys fall back to English, non-ASCII defaults are encoded
	eq( FPText.T( 'Nope/Nope', 'Choose… ▸ “x”' ), 'Choose… ▸ “x”' )
	eq( FPText.encode( 'é…' ), '^U+00E9^U+2026' )
	stub.loadLanguage( nil )
end )

test( 'Info.lua', function()
	local info = dofile( 'FolderPublisher.lrplugin/Info.lua' )
	eq( info.LrToolkitIdentifier, _PLUGIN.id )
	eq( #info.LrLibraryMenuItems, 4 )
	eq( info.LrLibraryMenuItems[1].title, 'Folder Publisher: Check & Publish…' )
	for _, item in ipairs( info.LrLibraryMenuItems ) do
		check( io.open( 'FolderPublisher.lrplugin/' .. item.file ), item.file .. ' exists' )
	end
end )

test( 'deleting published photos from the catalog', function()
	stub.messages = {}
	eq( provider.shouldDeletePhotosFromServiceOnDeleteFromCatalog( defaults(), 3 ), 'delete' )
	eq( provider.shouldDeletePhotosFromServiceOnDeleteFromCatalog( defaults { fp_onCatalogDelete = 'keep' }, 3 ), 'ignore' )
	eq( provider.shouldDeletePhotosFromServiceOnDeleteFromCatalog( defaults { fp_onCatalogDelete = 'block' }, 3 ), 'cancel' )
	eq( #stub.messages, 1 )
end )

test( 'import from another folder-publishing service', function()
	local FPMigration = require 'FPMigration'
	local _, cols = setup( { fp_folderBase = 'lrRootContents' }, { { name = 'Mirrored Photos' } } )
	local dest = stub.catalog.services[1]
	cols[1].isDefault = true
	local root = stub.root

	local lib = base .. '/lib/Lightroom sync'
	stub.catalog.topFolders = { lib }
	local a = stub.newPhoto( 11, lib .. '/Guilde/2025 Weekend/DSC1.ARW' )
	local b = stub.newPhoto( 12, lib .. '/Guilde/2025 Weekend/DSC2.ARW' )
	local c = stub.newPhoto( 13, lib .. '/Guilde/Other/DSC3.ARW', { rating = 4 } )
	local d = stub.newPhoto( 14, lib .. '/Guilde/Other/DSC4.ARW' )
	stub.catalog.allPhotos = { a, b, c, d }
	for _, rel in ipairs { 'Guilde/2025 Weekend/DSC1.jpg', 'Guilde/2025 Weekend/DSC2.jpg', 'Web/Guilde/Other/DSC3.jpg' } do
		stub.touch( root .. '/' .. rel )
	end

	-- the old service: absolute ids, or only a file:// URL
	local oldDefault = stub.newCollection( 1, 'Default', { jf_whatever = 1 } )
	oldDefault.isDefault = true
	oldDefault:add( a ).remoteId = root .. '/Guilde/2025 Weekend/DSC1.jpg'
	local eb = oldDefault:add( b )
	eb.remoteId, eb.url, eb.edited = 42, FPCore.fileUrl( root .. '/Guilde/2025 Weekend/DSC2.jpg' ), true
	local stars = stub.newCollection( 2, 'Stars' )
	stars.searchDesc = { criteria = 'rating', operation = '>=', value = 3,
		match = function( p ) return ( p.raw.rating or 0 ) >= 3 end }
	stars:add( c ).remoteId = root .. '/Web/Guilde/Other/DSC3.jpg'
	local old = stub.newService( 'jf Folder Publisher', { root = root }, { oldDefault, stars }, 'info.regex.lightroom.folder-publisher' )
	local sub = stub.newCollection( 3, 'Sub' )
	sub:add( d ).remoteId = root .. '/Guilde/Other/DSC4.jpg' -- file is missing
	old.sets = { { name = 'Sets', collections = { sub }, sets = {},
		getName = function() return 'Sets' end,
		getChildCollections = function( self ) return self.collections end,
		getChildCollectionSets = function() return {} end } }
	table.insert( stub.catalog.services, 1, old )

	stub.confirmAnswers = { 'ok' }
	FPMigration.run()

	local final = stub.messages[ #stub.messages ]
	check( final and final.title == 'Import finished', final and final.text )
	-- default collection: both photos published in place, b still needs republishing
	eq( cols[1]:entryFor( a ).remoteId, 'Guilde/2025 Weekend/DSC1.jpg' )
	eq( cols[1]:entryFor( a ).edited, false )
	eq( cols[1]:entryFor( b ).remoteId, 'Guilde/2025 Weekend/DSC2.jpg' )
	eq( cols[1]:entryFor( b ).edited, true )
	eq( cols[1].settings.subfolder, '' )
	-- smart collection: rules copied, layout "Web/" detected, photo published in place
	local newStars = dest.collections[2]
	eq( newStars.name, 'Stars' )
	eq( newStars.searchDesc, stars.searchDesc )
	eq( newStars.settings.subfolder, 'Web' )
	eq( newStars:entryFor( c ).remoteId, 'Web/Guilde/Other/DSC3.jpg' )
	-- set and collection recreated; the photo without a file waits to be published
	local newSub = dest.sets[1].collections[1]
	eq( newSub.name, 'Sub' )
	check( newSub:entryFor( d ), 'd added' )
	eq( newSub:entryFor( d ).remoteId, nil )
	-- nothing was written to the folder
	eq( treeOf(), 'Guilde/2025 Weekend/DSC1.jpg\nGuilde/2025 Weekend/DSC2.jpg\nWeb/Guilde/Other/DSC3.jpg' )

	-- publishing afterwards keeps the existing files where they are
	stub.publish( provider, dest, cols[1], { b } )
	eq( cols[1]:entryFor( b ).remoteId, 'Guilde/2025 Weekend/DSC2.jpg' )
	eq( treeOf(), 'Guilde/2025 Weekend/DSC1.jpg\nGuilde/2025 Weekend/DSC2.jpg\nWeb/Guilde/Other/DSC3.jpg' )
end )

--------------------------------------------------------------------------------

stub.run( 'rm -rf ' .. stub.shq( base ) )
print( string.format( '%d passed, %d failed', passed, failed ) )
os.exit( failed == 0 and 0 or 1 )
