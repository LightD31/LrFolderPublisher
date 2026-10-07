-- Minimal stand-in for the parts of the Lightroom Classic SDK used by the
-- plug-in, backed by the real (POSIX) file system. Good enough to run the
-- publish / delete / maintenance code paths in CI; it is NOT a faithful
-- emulation of Lightroom.

local stub = {
	messages = {},
	confirmAnswers = {},
	revealed = {},
}

local function shq( s )
	return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'"
end

local function run( cmd )
	local status = os.execute( cmd )
	return status == 0 or status == true
end

local function lines( cmd )
	local out = {}
	local p = io.popen( cmd )
	for line in p:lines() do
		out[ #out + 1 ] = line
	end
	p:close()
	return out
end

--------------------------------------------------------------------------------

local LrPathUtils = {}
function LrPathUtils.child( a, b )
	if a:sub( -1 ) == '/' then
		return a .. b
	end
	return a .. '/' .. b
end
function LrPathUtils.parent( p )
	local r = p:match( '^(.*)/[^/]+/?$' )
	if r == '' then
		return '/'
	end
	return r
end
function LrPathUtils.leafName( p )
	return p:match( '([^/]+)/?$' ) or p
end
function LrPathUtils.extension( p )
	return LrPathUtils.leafName( p ):match( '.%.([^%.]+)$' ) or ''
end
function LrPathUtils.removeExtension( p )
	local ext = LrPathUtils.extension( p )
	if ext == '' then
		return p
	end
	return p:sub( 1, #p - #ext - 1 )
end
function LrPathUtils.replaceExtension( p, e )
	return LrPathUtils.removeExtension( p ) .. '.' .. e
end
function LrPathUtils.getStandardFilePath( which )
	return stub.home or os.getenv( 'HOME' )
end

local LrFileUtils = {}
function LrFileUtils.exists( p )
	if run( 'test -d ' .. shq( p ) ) then
		return 'directory'
	end
	if run( 'test -e ' .. shq( p ) ) then
		return 'file'
	end
	return false
end
function LrFileUtils.createAllDirectories( p )
	return run( 'mkdir -p ' .. shq( p ) )
end
function LrFileUtils.delete( p )
	return run( 'rm -rf ' .. shq( p ) )
end
function LrFileUtils.moveToTrash( p )
	if stub.trashFails then
		return false, 'no trash here'
	end
	run( 'mkdir -p ' .. shq( stub.trash ) )
	stub.trashed = ( stub.trashed or 0 ) + 1
	return run( 'mv ' .. shq( p ) .. ' ' .. shq( stub.trash .. '/' .. stub.trashed .. '-' .. LrPathUtils.leafName( p ) ) )
end
function LrFileUtils.move( a, b )
	assert( run( 'mv ' .. shq( a ) .. ' ' .. shq( b ) ), 'move failed' )
end
function LrFileUtils.copy( a, b )
	return run( 'cp ' .. shq( a ) .. ' ' .. shq( b ) )
end
function LrFileUtils.directoryEntries( p )
	local entries = lines( 'ls -A ' .. shq( p ) )
	local i = 0
	return function()
		i = i + 1
		return entries[i] and ( p .. '/' .. entries[i] )
	end
end
function LrFileUtils.recursiveFiles( p )
	local entries = lines( 'find ' .. shq( p ) .. ' -type f | sort' )
	local i = 0
	return function()
		i = i + 1
		return entries[i]
	end
end

local LrTasks = {
	pcall = pcall,
	sleep = function() end,
	execute = function( cmd )
		stub.lastExecute = cmd
		return run( cmd ) and 0 or 1
	end,
	startAsyncTask = function( fn ) fn() end,
}

local COCOA_EPOCH = 978307200
local LrDate = {
	timeToUserFormat = function( t, fmt )
		return os.date( fmt, t + COCOA_EPOCH )
	end,
	currentTime = function()
		return os.time() - COCOA_EPOCH + ( stub.clockOffset or 0 )
	end,
}

stub.prefs = {}
local LrPrefs = {
	prefsForPlugin = function() return stub.prefs end,
}

local function progressScope()
	local p = { canceled = false }
	function p:isCanceled() return self.canceled end
	function p:setPortionComplete() end
	function p:setCaption() end
	function p:done() end
	return p
end

local LrDialogs = {
	message = function( title, text, kind )
		stub.messages[ #stub.messages + 1 ] = { title = title, text = text, kind = kind }
	end,
	confirm = function( ... )
		local answer = table.remove( stub.confirmAnswers, 1 ) or 'ok'
		stub.lastConfirm = { ... }
		return answer
	end,
	showModalProgressDialog = function() return progressScope() end,
	runOpenPanel = function() return nil end,
	presentModalDialog = function() return 'ok' end,
}

local LrErrors = {
	throwUserError = function( msg ) error( { userError = msg }, 0 ) end,
}

local LrFunctionContext = {
	callWithContext = function( name, fn, ... ) return fn( {}, ... ) end,
}

local LrShell = {
	revealInShell = function( p ) stub.revealed[ #stub.revealed + 1 ] = p end,
}

local logger = {}
for _, level in ipairs { 'enable', 'trace', 'info', 'warn', 'error', 'debug' } do
	logger[ level ] = function( self, msg )
		if level == 'error' and stub.verbose then
			print( 'LOG ERROR: ' .. tostring( msg ) )
		end
	end
end
local LrLogger = function() return logger end

-- View factory: every control is a table remembering its arguments.
local factory = setmetatable( {}, {
	__index = function( _, kind )
		return function( _, args )
			args = args or {}
			args._kind = kind
			return args
		end
	end,
} )
local LrView = {
	osFactory = function() return factory end,
	bind = function( arg )
		if type( arg ) == 'string' then
			return { bind = arg }
		end
		return { bind = arg.key, transform = arg.transform }
	end,
	share = function( name ) return { share = name } end,
}

--- A table that calls observers registered with addObserver on writes.
function stub.observable( initial )
	local data, observers = {}, {}
	for k, v in pairs( initial or {} ) do
		data[ k ] = v
	end
	local t = {}
	function t:addObserver( key, a, b )
		observers[ key ] = observers[ key ] or {}
		table.insert( observers[ key ], b or a )
	end
	function t:pairs() return pairs( data ) end
	return setmetatable( t, {
		__index = data,
		__newindex = function( _, k, v )
			data[ k ] = v
			for _, fn in ipairs( observers[ k ] or {} ) do
				fn( t, k, v )
			end
		end,
	} )
end

local LrBinding = {
	makePropertyTable = function() return stub.observable() end,
}

local LrColor = function( ... ) return { ... } end

local LrProgressScope = setmetatable( {}, {
	__call = function() return progressScope() end,
} )

local LrApplication = {
	activeCatalog = function() return stub.catalog end,
}

local namespaces = {
	LrApplication = LrApplication,
	LrBinding = LrBinding,
	LrColor = LrColor,
	LrDate = LrDate,
	LrDialogs = LrDialogs,
	LrErrors = LrErrors,
	LrFileUtils = LrFileUtils,
	LrFunctionContext = LrFunctionContext,
	LrLogger = LrLogger,
	LrPathUtils = LrPathUtils,
	LrPrefs = LrPrefs,
	LrProgressScope = LrProgressScope,
	LrShell = LrShell,
	LrTasks = LrTasks,
	LrView = LrView,
}

function import( name ) -- luacheck: ignore
	return assert( namespaces[ name ], 'stub missing for ' .. name )
end

MAC_ENV = true
WIN_ENV = false

--------------------------------------------------------------------------------
-- Localisation: LOC behaves like Lightroom's, reading TranslatedStrings_<lang>.txt

local function utf8char( cp )
	if cp < 0x80 then
		return string.char( cp )
	elseif cp < 0x800 then
		return string.char( 0xC0 + math.floor( cp / 64 ), 0x80 + cp % 64 )
	end
	return string.char( 0xE0 + math.floor( cp / 4096 ), 0x80 + math.floor( cp / 64 ) % 64, 0x80 + cp % 64 )
end

function stub.loadLanguage( lang )
	if not lang then
		stub.translations = nil
		return
	end
	stub.translations = {}
	for line in io.lines( 'FolderPublisher.lrplugin/TranslatedStrings_' .. lang .. '.txt' ) do
		local key, value = line:match( '^"%$%$%$/(.-)=(.*)"$' )
		if key then
			stub.translations[ key ] = value
		end
	end
end

function LOC( zstring, ... ) -- luacheck: ignore
	local key, value = zstring:match( '^%$%$%$/([%w/]+)=(.*)$' )
	assert( key, 'malformed ZString: ' .. zstring )
	assert( not value:find( '[\128-\255]' ), 'non-ASCII default text in ' .. key )
	if stub.translations and stub.translations[ key ] then
		value = stub.translations[ key ]
	end
	local args = { ... }
	value = value:gsub( '%^U%+(%x%x%x%x)', function( h ) return utf8char( tonumber( h, 16 ) ) end )
	value = value:gsub( '%^n', '\n' ):gsub( '%^r', '\r' ):gsub( '%^%.', '…' )
	value = value:gsub( '%^(%d)', function( d ) return tostring( args[ tonumber( d ) ] or '' ) end )
	return value
end
_PLUGIN = { id = 'io.github.lightd31.folderpublisher' }

stub.progressScope = progressScope
stub.factory = factory
stub.run = run
stub.shq = shq
stub.lines = lines

--------------------------------------------------------------------------------
-- Fake catalog objects

function stub.newPhoto( id, path, extra )
	local raw = { path = path, isVirtualCopy = false, dateTimeOriginal = 0 }
	local fmt = {}
	for k, v in pairs( extra or {} ) do
		if k == 'formatted' then
			for fk, fv in pairs( v ) do fmt[ fk ] = fv end
		else
			raw[ k ] = v
		end
	end
	local photo = { localIdentifier = id, raw = raw, fmt = fmt }
	stub.touch( path )
	function photo:getRawMetadata( key ) return self.raw[ key ] end
	function photo:getFormattedMetadata( key )
		if key == 'unknownKey' then
			error( 'unknown key' )
		end
		return self.fmt[ key ]
	end
	return photo
end

--- Creates an (empty) file, and its folder.
function stub.touch( path )
	run( 'mkdir -p ' .. shq( LrPathUtils.parent( path ) ) .. ' && touch ' .. shq( path ) )
end

--- Simulates renaming or moving a photo's original in Lightroom.
function stub.setPath( photo, path )
	stub.touch( path )
	photo.raw.path = path
end

function stub.newCollection( id, name, settings, parent )
	local c = {
		localIdentifier = id,
		name = name,
		settings = settings,
		parent = parent,
		entries = {}, -- array of { photo=, remoteId=, edited= }
	}
	function c:getName() return self.name end
	function c:getParent() return self.parent end
	function c:getService() return self.service end
	function c:getCollectionInfoSummary()
		return { collectionSettings = self.settings, name = self.name, isDefaultCollection = self.isDefault }
	end
	function c:entryFor( photo )
		for _, e in ipairs( self.entries ) do
			if e.photo == photo then
				return e
			end
		end
	end
	function c:add( photo )
		local e = self:entryFor( photo )
		if not e then
			e = { photo = photo }
			self.entries[ #self.entries + 1 ] = e
		end
		return e
	end
	function c:removeRemoteId( remoteId )
		for i, e in ipairs( self.entries ) do
			if e.remoteId == remoteId then
				table.remove( self.entries, i )
				return
			end
		end
	end
	function c:isSmartCollection() return self.searchDesc ~= nil end
	function c:getSearchDescription()
		assert( self.searchDesc, 'not a smart collection' )
		return self.searchDesc
	end
	function c:setCollectionSettings( settings )
		assert( stub.inWriteAccess, 'setCollectionSettings outside withWriteAccessDo' )
		self.settings = settings
	end
	function c:getPhotos()
		if self.searchDesc and stub.catalog then
			-- smart collection: every photo the catalog knows that matches
			for _, photo in ipairs( stub.catalog.allPhotos or {} ) do
				if self.searchDesc.match( photo ) then
					self:add( photo )
				end
			end
		end
		local out = {}
		for _, e in ipairs( self.entries ) do out[ #out + 1 ] = e.photo end
		return out
	end
	function c:addPhotoByRemoteId( photo, remoteId, url, published )
		assert( stub.inWriteAccess, 'addPhotoByRemoteId outside withWriteAccessDo' )
		if self.searchDesc and not self:entryFor( photo ) then
			error( 'photo is not in this smart collection' )
		end
		local e = self:add( photo )
		e.remoteId, e.url, e.edited = remoteId, url, not published
	end
	function c:addPhotos( photos )
		assert( stub.inWriteAccess, 'addPhotos outside withWriteAccessDo' )
		assert( not self.searchDesc, 'smart collection' )
		for _, photo in ipairs( photos ) do self:add( photo ) end
	end
	-- Lightroom publishes what is new or modified, then calls back.
	function c:publishNow( done )
		local photos = {}
		for _, e in ipairs( self.entries ) do
			if not e.remoteId or e.edited then
				photos[ #photos + 1 ] = e.photo
			end
		end
		if #photos > 0 then
			stub.publish( stub.provider, self.service, self, photos )
		end
		stub.publishedNow = ( stub.publishedNow or 0 ) + 1
		done()
	end
	function c:getPublishedPhotos()
		local out = {}
		for _, e in ipairs( self.entries ) do
			local pp = {}
			function pp:getRemoteId() return e.remoteId end
			function pp:getRemoteUrl() return e.url end
			function pp:getPhoto() return e.photo end
			function pp:getEditedFlag() return e.edited == true end
			function pp:setEditedFlag( v )
				assert( stub.inWriteAccess, 'setEditedFlag outside withWriteAccessDo' )
				e.edited = v
			end
			out[ #out + 1 ] = pp
		end
		return out
	end
	return c
end

local function newSet( name, parent, service )
	local set = { name = name, parent = parent, service = service, collections = {}, sets = {} }
	function set:getName() return self.name end
	function set:getParent() return self.parent end
	function set:getChildCollections() return self.collections end
	function set:getChildCollectionSets() return self.sets end
	return set
end

function stub.newService( name, settings, collections, pluginId )
	local s = newSet( name, nil, nil )
	s.settings = settings
	s.collections = collections
	s.pluginId = pluginId or _PLUGIN.id
	s.nextId = 1000
	function s:getPublishSettings() return self.settings end
	function s:getPluginId() return self.pluginId end
	local function container( parent ) return parent or s end
	local function findByName( list, name )
		for _, x in ipairs( list ) do
			if string.lower( x.name ) == string.lower( name ) then return x end
		end
	end
	function s:createPublishedCollection( name, parent, canReturnExisting, searchDesc )
		assert( stub.inWriteAccess, 'create outside withWriteAccessDo' )
		local into = container( parent )
		local existing = findByName( into.collections, name )
		if existing then
			return canReturnExisting and existing or nil
		end
		if findByName( into.sets, name ) then
			return nil
		end
		self.nextId = self.nextId + 1
		local c = stub.newCollection( self.nextId, name, nil, parent )
		c.searchDesc = searchDesc
		c.service = self
		table.insert( into.collections, c )
		return c
	end
	function s:createPublishedSmartCollection( name, searchDesc, parent, canReturnExisting )
		return self:createPublishedCollection( name, parent, canReturnExisting, searchDesc )
	end
	function s:createPublishedCollectionSet( name, parent, canReturnExisting )
		assert( stub.inWriteAccess, 'create outside withWriteAccessDo' )
		local into = container( parent )
		local existing = findByName( into.sets, name )
		if existing then
			return canReturnExisting and existing or nil
		end
		local set = newSet( name, parent, self )
		table.insert( into.sets, set )
		return set
	end
	for _, c in ipairs( collections ) do
		c.service = s
	end
	return s
end

function stub.newCatalog( topFolders, services )
	local cat = { topFolders = topFolders, services = services }
	function cat:getFolders()
		local out = {}
		for _, p in ipairs( self.topFolders ) do
			out[ #out + 1 ] = {
				getPath = function() return p end,
				getPhotos = function()
					local photos = {}
					for _, photo in ipairs( cat.allPhotos or {} ) do
						if photo.raw.path:sub( 1, #p + 1 ) == p .. '/' then
							photos[ #photos + 1 ] = photo
						end
					end
					return photos
				end,
			}
		end
		return out
	end
	function cat:getPublishServices( pluginId )
		if not pluginId then
			return self.services
		end
		local out = {}
		for _, service in ipairs( self.services ) do
			if service:getPluginId() == pluginId then
				out[ #out + 1 ] = service
			end
		end
		return out
	end
	function cat:getTargetPhoto() return self.targetPhoto end
	function cat:getPublishedCollectionByLocalIdentifier( id )
		local function search( container )
			for _, c in ipairs( container.collections ) do
				if c.localIdentifier == id then
					return c
				end
			end
			for _, set in ipairs( container.sets or {} ) do
				local found = search( set )
				if found then return found end
			end
		end
		for _, s in ipairs( self.services ) do
			local found = search( s )
			if found then return found end
		end
	end
	function cat:withWriteAccessDo( _, fn )
		stub.inWriteAccess = true
		fn()
		stub.inWriteAccess = false
	end
	return cat
end

--- Simulates Lightroom rendering `photos` into a temp folder and calling
-- processRenderedPhotos for `collection`.
-- opts.ext: rendered extension (default 'jpg'); opts.sidecar: also write .xmp
function stub.publish( provider, service, collection, photos, opts )
	opts = opts or {}
	run( 'mkdir -p ' .. shq( stub.temp ) )
	local renditions = {}
	stub.failures = {}
	for i, photo in ipairs( photos ) do
		local entry = collection:add( photo )
		local leaf = LrPathUtils.removeExtension( LrPathUtils.leafName( photo.raw.path ) )
		local ext = opts.ext or 'jpg'
		if ext == 'ORIGINAL' then
			ext = LrPathUtils.extension( photo.raw.path )
		end
		local rendered = stub.temp .. '/' .. i .. '-' .. leaf .. '.' .. ext
		local f = assert( io.open( rendered, 'w' ) )
		f:write( 'photo ' .. photo.localIdentifier .. ' ' .. ( opts.content or '' ) )
		f:close()
		if opts.sidecar then
			local x = assert( io.open( LrPathUtils.replaceExtension( rendered, 'xmp' ), 'w' ) )
			x:write( 'xmp' )
			x:close()
		end
		local r = { photo = photo, publishedPhotoId = entry.remoteId }
		function r:waitForRender() return true, rendered end
		function r:recordPublishedPhotoId( id ) entry.remoteId = id; entry.edited = false end
		function r:recordPublishedPhotoUrl( url ) entry.url = url end
		function r:uploadFailed( msg ) stub.failures[ #stub.failures + 1 ] = msg end
		renditions[ i ] = r
	end

	local exportContext = {
		propertyTable = service.settings,
		publishService = service,
		publishedCollection = collection,
		exportSession = {},
	}
	local removed = {}
	function exportContext.exportSession:countRenditions()
		local n = 0
		for _, r in ipairs( renditions ) do
			if not removed[ r.photo ] then n = n + 1 end
		end
		return n
	end
	function exportContext.exportSession:photosToExport()
		local i = 0
		return function()
			i = i + 1
			return renditions[i] and renditions[i].photo
		end
	end
	function exportContext.exportSession:removePhoto( photo )
		removed[ photo ] = true
	end
	function exportContext:configureProgress() return progressScope() end
	function exportContext:renditions()
		local active = {}
		for _, r in ipairs( renditions ) do
			if not removed[ r.photo ] then active[ #active + 1 ] = r end
		end
		local i = 0
		return function()
			i = i + 1
			if active[i] then
				return i, active[i]
			end
		end
	end
	provider.processRenderedPhotos( {}, exportContext )
	return renditions
end

return stub
