--[[----------------------------------------------------------------------------
FPDialogs.lua
Publish-service and collection settings UI.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrShell = import 'LrShell'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local FPCore = require 'FPCore'
local FPFiles = require 'FPFiles'
local FPMapping = require 'FPMapping'
local FPSettings = require 'FPSettings'
local FPText = require 'FPText'

local T = FPText.T
local bind = LrView.bind
local share = LrView.share

local FPDialogs = {}

local REVEAL_TITLE = MAC_ENV and T( 'Reveal/Finder', 'Show in Finder' ) or T( 'Reveal/Explorer', 'Show in Explorer' )
local NOTE_COLOR = LrColor( 0.45, 0.45, 0.45 )
local WARN_COLOR = LrColor( 0.75, 0.35, 0 )

local TOKEN_HELP = T( 'Names/Tokens', 'Tokens:' ) .. ' ' .. table.concat( ( function()
	local out = {}
	for i, name in ipairs( FPCore.TOKEN_NAMES ) do
		out[i] = '{' .. name .. '}'
	end
	return out
end )(), ' ' ) .. '\n' .. T( 'Names/TokenSyntax',
	'"/" creates sub-folders. {A|B|"text"} falls back to B, then to the text, when A is empty.' )

local function levelItems( noneTitle )
	local items = { { title = noneTitle or T( 'Common/None', 'None' ), value = 0 } }
	for i = 1, 9 do
		items[ #items + 1 ] = { title = tostring( i ), value = i }
	end
	return items
end

--------------------------------------------------------------------------------
-- Live example

local EXAMPLE_KEYS = {
	'fp_root', 'fp_folderBase', 'fp_skipLevels', 'fp_maxDepth', 'fp_fileNaming',
	'fp_template', 'fp_virtualCopySuffix', 'LR_format',
}

-- Recomputes `target.fp_exampleSource` / `fp_exampleDest`. `makeColCtx`
-- returns the collection context to use.
local function updateExample( target, settings, makeColCtx, collection )
	LrTasks.startAsyncTask( function()
		local ok, source, dest = LrTasks.pcall( function()
			local catalog = LrApplication.activeCatalog()
			local photo = FPMapping.examplePhoto( catalog, collection )
			if not photo then
				return nil, T( 'Example/NoPhoto', 'Select a photo in the Library to see an example.' )
			end
			return FPMapping.example( photo, settings, makeColCtx(), catalog, 'Service' )
		end )
		if ok then
			target.fp_exampleSource = source or ''
			target.fp_exampleDest = dest or ''
		else
			target.fp_exampleSource = ''
			target.fp_exampleDest = T( 'Example/Failed', 'Example unavailable: ^1', tostring( source ) )
		end
	end )
end

local function exampleRows( f, labelWidth, object )
	return f:column {
		bind_to_object = object,
		spacing = f:label_spacing(),
		f:row {
			f:static_text { title = T( 'Example/Source', 'Example:' ), alignment = 'right', width = labelWidth },
			f:static_text {
				title = bind 'fp_exampleSource',
				fill_horizontal = 1,
				width_in_chars = 60,
				truncation = 'middle',
				text_color = NOTE_COLOR,
			},
		},
		f:row {
			f:static_text { title = T( 'Example/Dest', 'is published to:' ), alignment = 'right', width = labelWidth },
			f:static_text {
				title = bind 'fp_exampleDest',
				fill_horizontal = 1,
				width_in_chars = 60,
				truncation = 'middle',
				font = '<system/bold>',
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Service lookup for the maintenance buttons

-- The service being edited, recognised by its root folder as stored when
-- the dialog opened (Lightroom doesn't tell the dialog which service it is).
local function serviceBeingEdited( propertyTable )
	local catalog = LrApplication.activeCatalog()
	local matches = {}
	for _, service in ipairs( catalog:getPublishServices( _PLUGIN.id ) ) do
		local settings = service:getPublishSettings()
		if settings and settings.fp_root == propertyTable.fp_originalRoot then
			matches[ #matches + 1 ] = service
		end
	end
	if #matches == 1 then
		return matches[1]
	end
	return nil, #matches
end

local function runMaintenance( propertyTable, action )
	LrTasks.startAsyncTask( function()
		local FPMaintenance = require 'FPMaintenance'
		local ok, err = LrTasks.pcall( function()
			if not propertyTable.fp_originalRoot or propertyTable.fp_originalRoot == '' then
				LrDialogs.message( 'Folder Publisher', T( 'Maint/SaveFirst', 'Save this publish service first.' ), 'info' )
				return
			end
			local service, count = serviceBeingEdited( propertyTable )
			if not service and count and count > 1 then
				service = FPMaintenance.chooseService( T( 'Maint/Choose', 'Choose the publish service' ) )
			end
			if not service then
				LrDialogs.message( 'Folder Publisher', T( 'Maint/SaveFirst', 'Save this publish service first.' ), 'info' )
				return
			end
			action( FPMaintenance, service )
		end )
		if not ok then
			LrDialogs.message( 'Folder Publisher', tostring( err ), 'critical' )
		end
	end )
end

--------------------------------------------------------------------------------
-- Dialog lifecycle

function FPDialogs.startDialog( propertyTable )
	propertyTable.fp_originalRoot = propertyTable.fp_root

	local function validate()
		local root = FPFiles.expandRoot( propertyTable.fp_root )
		local problem
		if root == '' then
			problem = T( 'Dest/NoFolder', 'Choose the folder to publish to.' )
			propertyTable.fp_rootStatus = ''
		elseif FPFiles.isDirectory( root ) then
			propertyTable.fp_rootStatus = ''
		else
			propertyTable.fp_rootStatus = T( 'Dest/NotThere',
				'This folder does not exist yet. You will be asked before it is created.' )
		end
		if not problem and propertyTable.fp_fileNaming == 'template'
			and FPCore.trim( propertyTable.fp_template or '' ) == '' then
			problem = T( 'Names/NoTemplate', 'Enter a file name template.' )
		end
		propertyTable.LR_cantExportBecause = problem
	end

	local function refreshExample()
		updateExample( propertyTable, propertyTable, function()
			return FPMapping.collectionContext( nil, { name = 'Collection' } )
		end )
	end

	for _, key in ipairs { 'fp_root', 'fp_fileNaming', 'fp_template' } do
		propertyTable:addObserver( key, validate )
	end
	for _, key in ipairs( EXAMPLE_KEYS ) do
		propertyTable:addObserver( key, refreshExample )
	end

	propertyTable.fp_exampleSource = ''
	propertyTable.fp_exampleDest = ''
	validate()
	refreshExample()
end

--------------------------------------------------------------------------------
-- Service sections

function FPDialogs.sectionsForTopOfDialog( f, propertyTable )
	local labelWidth = share 'fp_labelWidth'

	return {
		{
			title = T( 'Dest/Section', 'Folder Publisher: Destination' ),
			synopsis = bind {
				key = 'fp_root',
				transform = function( value )
					return ( value and value ~= '' ) and value or T( 'Dest/NoneChosen', '(no folder chosen)' )
				end,
			},

			f:row {
				f:static_text { title = T( 'Dest/Folder', 'Publish to folder:' ), alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'fp_root',
					immediate = true,
					fill_horizontal = 1,
					width_in_chars = 36,
				},
				f:push_button {
					title = T( 'Dest/ChooseButton', 'Choose…' ),
					action = function()
						local result = LrDialogs.runOpenPanel {
							title = T( 'Dest/ChooseTitle', 'Choose the folder to publish to' ),
							canChooseFiles = false,
							canChooseDirectories = true,
							canCreateDirectories = true,
							allowsMultipleSelection = false,
							initialDirectory = FPFiles.expandRoot( propertyTable.fp_root ),
						}
						if result and result[1] then
							propertyTable.fp_root = result[1]
						end
					end,
				},
				f:push_button {
					title = REVEAL_TITLE,
					action = function()
						local root = FPFiles.expandRoot( propertyTable.fp_root )
						if FPFiles.isDirectory( root ) then
							LrShell.revealInShell( root )
						end
					end,
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text { title = bind 'fp_rootStatus', fill_horizontal = 1, text_color = WARN_COLOR },
			},

			f:row {
				f:static_text { title = T( 'Dest/Base', 'Mirror folders from:' ), alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_folderBase',
					items = {
						{ title = T( 'Dest/BaseInside', 'Inside each top-level Lightroom folder' ), value = 'lrRootContents' },
						{ title = T( 'Dest/BaseWithName', 'Each top-level Lightroom folder, including its name' ), value = 'lrRoot' },
						{ title = T( 'Dest/BaseFull', 'The full path on disk (without the drive)' ), value = 'full' },
					},
				},
			},

			f:row {
				f:static_text { title = T( 'Path/StripLeading', 'Strip leading folders:' ), alignment = 'right', width = labelWidth },
				f:popup_menu { value = bind 'fp_skipLevels', items = levelItems() },
				f:spacer { width = 20 },
				f:static_text { title = T( 'Dest/Depth', 'Limit depth to:' ) },
				f:popup_menu { value = bind 'fp_maxDepth', items = levelItems( T( 'Dest/NoLimit', 'No limit' ) ) },
			},

			exampleRows( f, labelWidth, propertyTable ),

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Dest/CollectionsNote', 'Each published collection can add folders before or after '
						.. 'this path, strip more folders, or flatten it.' ),
					size = 'small',
					text_color = NOTE_COLOR,
				},
			},

			f:separator { fill_horizontal = 1 },

			f:row {
				f:static_text { title = T( 'Maint/Label', 'Maintenance:' ), alignment = 'right', width = labelWidth },
				f:push_button {
					title = T( 'Maint/CheckButton', 'Find Moved, Renamed or Missing Photos…' ),
					action = function()
						runMaintenance( propertyTable, function( m, service ) m.checkService( service ) end )
					end,
				},
				f:push_button {
					title = T( 'Maint/OrphansButton', 'Clean Up Orphaned Files…' ),
					action = function()
						runMaintenance( propertyTable, function( m, service ) m.cleanOrphans( service ) end )
					end,
				},
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Maint/Note', 'Lightroom does not flag renamed or moved photos for republishing; '
						.. 'the first button finds them.\nBoth, and Check & Publish, are in Library ▸ Plug-in Extras.' ),
					size = 'small',
					height_in_lines = 2,
					text_color = NOTE_COLOR,
				},
			},
		},

		{
			title = T( 'Names/Section', 'Folder Publisher: File Names' ),
			synopsis = bind {
				key = 'fp_fileNaming',
				transform = function( value )
					if value == 'template' then
						return T( 'Names/SynTemplate', 'Template' )
					elseif value == 'lightroom' then
						return T( 'Names/SynLightroom', 'Lightroom File Naming' )
					end
					return T( 'Names/SynOriginal', 'Same as original' )
				end,
			},

			f:row {
				f:static_text { title = T( 'Names/Mode', 'Name published files:' ), alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_fileNaming',
					items = {
						{ title = T( 'Names/ModeOriginal', 'Same as the original file' ), value = 'library' },
						{ title = T( 'Names/ModeTemplate', 'With a template' ), value = 'template' },
						{ title = T( 'Names/ModeLightroom', 'With the File Naming section above' ), value = 'lightroom' },
					},
				},
			},

			f:row {
				f:static_text { title = T( 'Names/Template', 'Template:' ), alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'fp_template',
					immediate = true,
					fill_horizontal = 1,
					width_in_chars = 36,
					enabled = bind { key = 'fp_fileNaming', transform = function( v ) return v == 'template' end },
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = TOKEN_HELP,
					fill_horizontal = 1,
					height_in_lines = 4,
					width_in_chars = 60,
					size = 'small',
					text_color = NOTE_COLOR,
					visible = bind { key = 'fp_fileNaming', transform = function( v ) return v == 'template' end },
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:checkbox {
					value = bind 'fp_virtualCopySuffix',
					title = T( 'Names/VirtualCopies', 'Add the copy name to virtual copies, e.g. "IMG_1234 (Copy 1).jpg"' ),
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Names/Collisions', 'Photos that would get the same name (RAW+JPEG pairs, names '
						.. 'differing only in case) get "-2", "-3"… and keep it.' ),
					size = 'small',
					text_color = NOTE_COLOR,
				},
			},

			exampleRows( f, labelWidth, propertyTable ),
		},
	}
end

function FPDialogs.sectionsForBottomOfDialog( f, propertyTable )
	local labelWidth = share 'fp_labelWidth2'

	local columns = { {}, {}, {} }
	local perColumn = math.ceil( #FPSettings.republishTriggers / 3 )
	for i, trigger in ipairs( FPSettings.republishTriggers ) do
		local column = columns[ math.ceil( i / perColumn ) ]
		column[ #column + 1 ] = f:checkbox {
			title = T( 'Trig/' .. trigger.id, trigger.label ),
			value = bind( 'fp_trig_' .. trigger.id ),
		}
	end
	for i, column in ipairs( columns ) do
		column.spacing = f:label_spacing()
		columns[i] = f:column( column )
	end

	local function setAll( value )
		for _, trigger in ipairs( FPSettings.republishTriggers ) do
			propertyTable[ 'fp_trig_' .. trigger.id ] = value
		end
	end

	return {
		{
			title = T( 'Trig/Section', 'Folder Publisher: Republish When Metadata Changes' ),
			synopsis = T( 'Trig/Synopsis', 'Metadata changes that mark photos for republishing' ),

			f:row {
				f:static_text {
					title = T( 'Trig/Intro', 'Develop edits always mark a photo for republishing. Also mark it when '
						.. 'this changes:' ),
					fill_horizontal = 1,
				},
				f:push_button { title = T( 'Common/All', 'All' ), action = function() setAll( true ) end },
				f:push_button { title = T( 'Common/None', 'None' ), action = function() setAll( false ) end },
			},
			f:row {
				spacing = 30,
				f:spacer { width = 1 },
				columns[1], columns[2], columns[3],
			},
			f:static_text {
				title = T( 'Trig/Note', 'Changes apply to future edits only. After saving, Lightroom asks whether '
					.. 'to republish everything: choose "Leave As Is" if you only changed these options.' ),
				size = 'small',
				height_in_lines = 2,
				width_in_chars = 80,
				text_color = NOTE_COLOR,
			},
		},

		{
			title = T( 'Remove/Section', 'Folder Publisher: Removing Photos' ),
			synopsis = bind {
				key = 'fp_onRemove',
				transform = function( value )
					if value == 'keep' then
						return T( 'Remove/SynKeep', 'Files of removed photos stay on disk' )
					elseif value == 'trash' then
						return T( 'Remove/SynTrash', 'Files of removed photos go to the Trash' )
					end
					return T( 'Remove/SynDelete', 'Files of removed photos are deleted' )
				end,
			},

			f:row {
				f:static_text { title = T( 'Remove/OnRemove', 'When a photo leaves the service:' ), alignment = 'right',
					width = labelWidth },
				f:popup_menu {
					value = bind 'fp_onRemove',
					items = {
						{ title = T( 'Remove/Delete', 'Delete its published file' ), value = 'delete' },
						{ title = MAC_ENV and T( 'Remove/Trash', 'Move its published file to the Trash' )
							or T( 'Remove/RecycleBin', 'Move its published file to the Recycle Bin' ), value = 'trash' },
						{ title = T( 'Remove/Keep', 'Leave its published file on disk' ), value = 'keep' },
					},
				},
			},
			f:row {
				f:static_text { title = T( 'Remove/OnCatalogDelete', 'When it is deleted from the catalog:' ),
					alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_onCatalogDelete',
					items = {
						{ title = T( 'Remove/CatalogRemove', 'Remove it from the service (as above)' ), value = 'remove' },
						{ title = T( 'Remove/Keep', 'Leave its published file on disk' ), value = 'keep' },
						{ title = T( 'Remove/CatalogBlock', 'Don\'t allow deleting published photos' ), value = 'block' },
					},
				},
			},
			f:row {
				f:spacer { width = labelWidth },
				f:checkbox {
					value = bind 'fp_pruneEmptyFolders',
					title = T( 'Remove/Prune', 'Remove folders that become empty' ),
				},
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Remove/Note', 'A file shared by several collections of this service is kept until '
						.. 'the last one lets go of it.\nWhen a photo is renamed or moved, its old file is always removed.' ),
					size = 'small',
					height_in_lines = 2,
					text_color = NOTE_COLOR,
				},
			},
		},

		{
			title = T( 'After/Section', 'Folder Publisher: After Publishing' ),
			synopsis = bind {
				key = 'fp_fileDate',
				transform = function( value )
					return value == 'capture' and T( 'After/SynCapture', 'Files dated with the capture time' )
						or T( 'After/SynExport', 'Files dated with the time of publishing' )
				end,
			},
			f:row {
				f:static_text { title = T( 'After/Date', 'Date of published files:' ), alignment = 'right',
					width = labelWidth },
				f:popup_menu {
					value = bind 'fp_fileDate',
					items = {
						{ title = T( 'After/DateExport', 'Time of publishing' ), value = 'export' },
						{ title = T( 'After/DateCapture', 'Photo capture time' ), value = 'capture' },
					},
				},
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = MAC_ENV and T( 'After/DateNoteMac', 'This is the date shown in Finder. Backup and sync '
						.. 'tools may use it to detect changes.' )
						or T( 'After/DateNoteWin', 'This is the date shown in Explorer. Backup and sync tools may '
						.. 'use it to detect changes.' ),
					size = 'small',
					text_color = NOTE_COLOR,
				},
			},
			f:row {
				f:static_text { title = T( 'After/Summary', 'Show a summary:' ), alignment = 'right',
					width = labelWidth },
				f:popup_menu {
					value = bind 'fp_showSummary',
					items = {
						{ title = T( 'After/SummaryAlways', 'After every publish' ), value = 'always' },
						{ title = T( 'After/SummaryProblems', 'Only when something needs attention' ),
							value = 'problems' },
						{ title = T( 'After/SummaryNever', 'Never' ), value = 'never' },
					},
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Collection settings

function FPDialogs.collectionSettingsView( f, publishSettings, info )
	local collectionSettings = info.collectionSettings
	local exampleTarget = info.pluginContext or collectionSettings
	local labelWidth = share 'fp_colLabelWidth'

	local parents = {}
	for _, parent in ipairs( info.parents or {} ) do
		parents[ #parents + 1 ] = parent.name
	end

	local function refresh()
		updateExample( exampleTarget, publishSettings, function()
			local name = collectionSettings.LR_liveName or info.name or T( 'Col/DefaultName', 'Collection' )
			local path = {}
			for i, p in ipairs( parents ) do
				path[i] = p
			end
			path[ #path + 1 ] = name
			return {
				name = name,
				path = path,
				settings = FPSettings.collectionSettings( collectionSettings ),
			}
		end, info.publishedCollection )
	end

	for _, key in ipairs { 'subfolder', 'append', 'structure', 'extraSkipLevels', 'trailingSkipLevels', 'LR_liveName' } do
		collectionSettings:addObserver( key, refresh )
	end
	exampleTarget.fp_exampleSource = ''
	exampleTarget.fp_exampleDest = ''
	refresh()

	local mirroring = bind {
		key = 'structure',
		object = collectionSettings,
		transform = function( v ) return v ~= 'flatten' end,
	}

	return f:group_box {
		title = 'Folder Publisher',
		fill_horizontal = 1,
		bind_to_object = collectionSettings,

		f:column {
			spacing = f:control_spacing(),
			fill_horizontal = 1,

			f:static_text {
				title = T( 'Col/Intro', 'Photos go to the folder that mirrors their Lightroom folder (as set for '
					.. 'the service), adjusted here:' ),
			},
			f:row {
				f:static_text { title = T( 'Col/Structure', 'Folder structure:' ), alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'structure',
					items = {
						{ title = T( 'Col/Mirror', 'Mirror Lightroom folders' ), value = 'mirror' },
						{ title = T( 'Col/Flat', 'Flat: no sub-folders' ), value = 'flatten' },
					},
				},
			},
			f:row {
				f:static_text { title = T( 'Path/StripLeading', 'Strip leading folders:' ), alignment = 'right',
					width = labelWidth },
				f:popup_menu { value = bind 'extraSkipLevels', items = levelItems(), enabled = mirroring },
				f:spacer { width = 20 },
				f:static_text { title = T( 'Path/StripTrailing', 'Strip trailing folders:' ) },
				f:popup_menu { value = bind 'trailingSkipLevels', items = levelItems(), enabled = mirroring },
			},
			f:row {
				f:static_text { title = T( 'Col/Before', 'Add before the path:' ), alignment = 'right', width = labelWidth },
				f:edit_field { value = bind 'subfolder', immediate = true, width_in_chars = 30 },
			},
			f:row {
				f:static_text { title = T( 'Col/After', 'Add after the path:' ), alignment = 'right', width = labelWidth },
				f:edit_field { value = bind 'append', immediate = true, width_in_chars = 30 },
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Col/Tokens', 'Tokens are allowed, e.g. {Collection}, {CollectionPath}, {YYYY}, {Rating}.' ),
					size = 'small',
					text_color = NOTE_COLOR,
				},
			},

			exampleRows( f, labelWidth, exampleTarget ),

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = T( 'Col/Note', 'Photos whose path changes are marked for republishing; publishing moves '
						.. 'their files.' ),
					size = 'small',
					text_color = NOTE_COLOR,
				},
			},
		},
	}
end

--- Removes the transient example values if they had to be stored in the
-- collection settings (Lightroom versions without pluginContext).
function FPDialogs.endCollectionSettings( info )
	if not info.pluginContext and info.collectionSettings then
		info.collectionSettings.fp_exampleSource = nil
		info.collectionSettings.fp_exampleDest = nil
	end
end

return FPDialogs
