--[[----------------------------------------------------------------------------
FPSummary.lua
The summary shown after publishing. Statistics go through the plug-in's
preferences so that "Check & Publish", which publishes several collections in
a row, can show one combined summary at the end.
------------------------------------------------------------------------------]]

local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'

local FPText = require 'FPText'

local T = FPText.T

local FPSummary = {}

local BATCH_MAX_AGE = 12 * 3600  -- a batch older than this was interrupted
local REMOVAL_MAX_AGE = 15 * 60  -- removals this recent belong to the current publish

local FIELDS = { 'new', 'updated', 'moved', 'removed', 'failed', 'offline', 'flagged', 'missing' }

local function prefs()
	return LrPrefs.prefsForPlugin()
end

local function now()
	return LrDate.currentTime()
end

function FPSummary.emptyStats()
	local s = { collections = 0, offlinePaths = {} }
	for _, f in ipairs( FIELDS ) do
		s[ f ] = 0
	end
	return s
end

local function add( into, stats )
	for _, f in ipairs( FIELDS ) do
		into[ f ] = ( into[ f ] or 0 ) + ( stats[ f ] or 0 )
	end
	into.collections = ( into.collections or 0 ) + ( stats.collections or 0 )
	into.offlinePaths = into.offlinePaths or {}
	for _, p in ipairs( stats.offlinePaths or {} ) do
		if #into.offlinePaths < 10 then
			into.offlinePaths[ #into.offlinePaths + 1 ] = p
		end
	end
	return into
end

local function batchActive()
	local p = prefs()
	return p.batchStarted ~= nil and now() - p.batchStarted < BATCH_MAX_AGE
end

--------------------------------------------------------------------------------
-- Recording

--- Removals happen before rendering (deleteFirstOnPublish); remember them for
-- the summary of the publish that follows.
function FPSummary.recordRemoved( n )
	if n <= 0 then
		return
	end
	local p = prefs()
	local pending = p.pendingRemoved
	if not pending or now() - ( pending.time or 0 ) > REMOVAL_MAX_AGE then
		pending = { count = 0 }
	end
	p.pendingRemoved = { count = pending.count + n, time = now() }
end

local function takeRemoved()
	local p = prefs()
	local pending = p.pendingRemoved
	p.pendingRemoved = nil
	if pending and now() - ( pending.time or 0 ) <= REMOVAL_MAX_AGE then
		return pending.count or 0
	end
	return 0
end

--------------------------------------------------------------------------------
-- Text

local function hasProblems( s )
	return ( s.failed or 0 ) > 0 or ( s.offline or 0 ) > 0 or ( s.missing or 0 ) > 0
end

--- Builds the summary text (exposed for tests).
function FPSummary.describe( s )
	local lines = {}
	local function line( n, key, one, many )
		if ( n or 0 ) > 0 then
			lines[ #lines + 1 ] = FPText.count( n, key, one, many )
		end
	end
	line( s.new, 'Summary/New', '^1 new photo published', '^1 new photos published' )
	line( s.updated, 'Summary/Updated', '^1 photo updated', '^1 photos updated' )
	line( s.moved, 'Summary/Moved', '^1 photo moved or renamed', '^1 photos moved or renamed' )
	line( s.removed, 'Summary/Removed', '^1 file removed', '^1 files removed' )
	line( s.flagged, 'Summary/Flagged', '^1 photo found renamed or moved in Lightroom',
		'^1 photos found renamed or moved in Lightroom' )
	line( s.missing, 'Summary/Missing', '^1 published file was missing and was re-created',
		'^1 published files were missing and were re-created' )
	line( s.failed, 'Summary/Failed', '^1 photo failed (Lightroom lists them)',
		'^1 photos failed (Lightroom lists them)' )
	line( s.offline, 'Summary/Offline', '^1 photo skipped: original offline',
		'^1 photos skipped: original offline' )
	if #lines == 0 then
		lines[1] = T( 'Summary/Nothing', 'Everything was already up to date.' )
	end
	local text = table.concat( lines, '\n' )
	if s.offlinePaths and #s.offlinePaths > 0 then
		text = text .. '\n\n' .. T( 'Summary/OfflineList',
			'Skipped photos stay queued and are published once their drive is connected:' )
			.. '\n' .. table.concat( s.offlinePaths, '\n' )
			.. ( ( s.offline or 0 ) > #s.offlinePaths and '\n…' or '' )
	end
	return text
end

local function show( title, stats, mode )
	if mode == 'never' or ( mode == 'problems' and not hasProblems( stats ) ) then
		return
	end
	LrDialogs.message( title, FPSummary.describe( stats ), hasProblems( stats ) and 'warning' or 'info' )
end

--------------------------------------------------------------------------------
-- Publishing

--- Called at the end of processRenderedPhotos.
-- @param mode publish setting fp_showSummary: always | problems | never
function FPSummary.publishFinished( collectionName, stats, mode )
	stats.removed = ( stats.removed or 0 ) + takeRemoved()
	stats.collections = 1
	if batchActive() then
		local p = prefs()
		p.batchStats = add( p.batchStats or FPSummary.emptyStats(), stats )
		p.batchMode = p.batchMode or mode
		return
	end
	show( T( 'Summary/Title', 'Published "^1"', collectionName ), stats, mode )
end

--- Starts a batch: summaries are collected instead of shown.
function FPSummary.beginBatch( initial )
	local p = prefs()
	p.batchStarted = now()
	p.batchStats = add( FPSummary.emptyStats(), initial or {} )
	p.batchMode = nil
end

--- Ends a batch and shows the combined summary.
function FPSummary.endBatch( serviceName, defaultMode )
	local p = prefs()
	local stats = p.batchStats or FPSummary.emptyStats()
	local mode = p.batchMode or defaultMode or 'always'
	stats.removed = ( stats.removed or 0 ) + takeRemoved()
	p.batchStarted = nil
	p.batchStats = nil
	p.batchMode = nil
	-- The user started this run explicitly: say how it went, unless summaries
	-- are turned off and nothing went wrong.
	if mode == 'never' and not hasProblems( stats ) then
		return stats
	end
	LrDialogs.message( T( 'Summary/BatchTitle', 'Check & Publish finished for "^1"', serviceName ),
		FPSummary.describe( stats ), hasProblems( stats ) and 'warning' or 'info' )
	return stats
end

return FPSummary
