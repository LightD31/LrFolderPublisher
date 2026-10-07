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

local bind = LrView.bind
local share = LrView.share

local FPDialogs = {}

local TOKEN_HELP = 'Tokens: ' .. table.concat( ( function()
	local out = {}
	for i, name in ipairs( FPCore.TOKEN_NAMES ) do
		out[i] = '{' .. name .. '}'
	end
	return out
end )(), ' ' ) .. '\nUse "/" to create sub-folders, and {A|B|"text"} for fallbacks when A is empty.'

local function isTemplateMode( value )
	return value == 'template'
end

--------------------------------------------------------------------------------
-- Validation

function FPDialogs.startDialog( propertyTable )
	local function validate()
		local root = FPFiles.expandRoot( propertyTable.fp_root )
		local problem
		if root == '' then
			problem = 'Choose the root folder of the publish tree.'
			propertyTable.fp_rootStatus = ''
		elseif FPFiles.isDirectory( root ) then
			propertyTable.fp_rootStatus = ''
		else
			propertyTable.fp_rootStatus = 'This folder does not exist yet. You will be asked to create it when publishing.'
		end
		if not problem and propertyTable.fp_fileNaming == 'template'
			and FPCore.trim( propertyTable.fp_template or '' ) == '' then
			problem = 'Enter a file name template.'
		end
		propertyTable.LR_cantExportBecause = problem
	end
	propertyTable:addObserver( 'fp_root', validate )
	propertyTable:addObserver( 'fp_fileNaming', validate )
	propertyTable:addObserver( 'fp_template', validate )
	propertyTable.fp_preview = ''
	validate()
end

--------------------------------------------------------------------------------
-- Preview

local function updatePreview( propertyTable )
	LrTasks.startAsyncTask( function()
		local ok, result = LrTasks.pcall( function()
			local catalog = LrApplication.activeCatalog()
			local photo = catalog:getTargetPhoto()
			if not photo then
				return 'Select a photo in the Library first.'
			end
			local colCtx = FPMapping.collectionContext( nil, { name = 'Collection' } )
			local stem, nameKnown = FPMapping.targetStem( photo, propertyTable, colCtx,
				FPMapping.topFolders( catalog ), nil, 'Service' )
			local ext = FPMapping.guessExtension( propertyTable, photo )
			local text = stem .. ( ext ~= '' and ( '.' .. ext ) or '' )
			if not nameKnown then
				text = text .. '\n(the file name will come from the File Naming section)'
			end
			return text
		end )
		propertyTable.fp_preview = ok and result or ( 'Preview failed: ' .. tostring( result ) )
	end )
end

--------------------------------------------------------------------------------
-- Sections

function FPDialogs.sectionsForTopOfDialog( f, propertyTable )
	local labelWidth = share 'fp_labelWidth'

	return {
		{
			title = 'Folder Publisher: Destination',
			synopsis = bind {
				key = 'fp_root',
				transform = function( value )
					return ( value and value ~= '' ) and value or '(no folder chosen)'
				end,
			},

			f:row {
				f:static_text { title = 'Publish tree root:', alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'fp_root',
					immediate = true,
					fill_horizontal = 1,
					width_in_chars = 36,
				},
				f:push_button {
					title = 'Choose…',
					action = function()
						local result = LrDialogs.runOpenPanel {
							title = 'Choose the root of the publish tree',
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
					title = MAC_ENV and 'Show in Finder' or 'Show in Explorer',
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
				f:static_text {
					title = bind 'fp_rootStatus',
					fill_horizontal = 1,
					text_color = LrColor( 0.7, 0.3, 0 ),
				},
			},

			f:row {
				f:static_text { title = 'Mirror folders from:', alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_folderBase',
					items = {
						{ title = 'The top-level Lightroom folder, including its name', value = 'lrRoot' },
						{ title = 'Inside the top-level Lightroom folder', value = 'lrRootContents' },
						{ title = 'The full path on disk (without drive letter)', value = 'full' },
					},
				},
			},

			f:row {
				f:static_text { title = 'Skip leading folders:', alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'fp_skipLevels',
					min = 0, max = 99, precision = 0, width_in_digits = 3,
				},
				f:spacer { width = 20 },
				f:static_text { title = 'Limit depth to:' },
				f:edit_field {
					value = bind 'fp_maxDepth',
					min = 0, max = 99, precision = 0, width_in_digits = 3,
				},
				f:static_text { title = 'levels (0 = no limit)' },
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = 'Example: "D:\\Photos\\2024\\Trip\\IMG_1.CR3" in the top-level folder "Photos" '
						.. 'is published to "<root>\\Photos\\2024\\Trip\\IMG_1.jpg". Skipping one folder gives '
						.. '"<root>\\2024\\Trip\\IMG_1.jpg". Collections can add a sub-folder or flatten the tree.',
					fill_horizontal = 1,
					height_in_lines = 3,
					width_in_chars = 60,
					size = 'small',
				},
			},
		},

		{
			title = 'Folder Publisher: File Names',
			synopsis = bind {
				key = 'fp_fileNaming',
				transform = function( value )
					if value == 'template' then
						return 'Template: ' .. tostring( propertyTable.fp_template )
					elseif value == 'lightroom' then
						return 'Lightroom File Naming'
					end
					return 'Same as original'
				end,
			},

			f:row {
				f:static_text { title = 'Name published files:', alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_fileNaming',
					items = {
						{ title = 'Same as the original file', value = 'library' },
						{ title = 'With a template (below)', value = 'template' },
						{ title = 'With Lightroom\'s File Naming section', value = 'lightroom' },
					},
				},
			},

			f:row {
				f:static_text { title = 'Template:', alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'fp_template',
					immediate = true,
					fill_horizontal = 1,
					width_in_chars = 36,
					enabled = bind { key = 'fp_fileNaming', transform = isTemplateMode },
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = TOKEN_HELP,
					fill_horizontal = 1,
					height_in_lines = 5,
					width_in_chars = 60,
					size = 'small',
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:checkbox {
					value = bind 'fp_virtualCopySuffix',
					title = 'Add the copy name to virtual copies, e.g. "IMG_1234 (Copy 1).jpg"',
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = 'Files that would get the same name (e.g. RAW+JPEG pairs) get "-2", "-3", ... appended.',
					size = 'small',
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:push_button {
					title = 'Preview with Selected Photo',
					action = function()
						updatePreview( propertyTable )
					end,
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = bind 'fp_preview',
					fill_horizontal = 1,
					height_in_lines = 2,
					width_in_chars = 60,
				},
			},
		},
	}
end

function FPDialogs.sectionsForBottomOfDialog( f, propertyTable )
	local labelWidth = share 'fp_labelWidth2'

	local left, right = { spacing = f:control_spacing() }, { spacing = f:control_spacing() }
	local half = math.ceil( #FPSettings.republishTriggers / 2 )
	for i, trigger in ipairs( FPSettings.republishTriggers ) do
		local column = i <= half and left or right
		column[ #column + 1 ] = f:checkbox {
			title = trigger.label,
			value = bind( 'fp_trig_' .. trigger.key ),
		}
	end

	return {
		{
			title = 'Folder Publisher: Republish Triggers',
			synopsis = 'Metadata changes that mark photos for republishing',

			f:static_text {
				title = 'Mark published photos as modified when this metadata changes '
					.. '(Develop edits always do):',
			},
			f:row {
				f:spacer { width = 20 },
				f:column( left ),
				f:spacer { width = 30 },
				f:column( right ),
			},
		},

		{
			title = 'Folder Publisher: Housekeeping',
			synopsis = bind {
				key = 'fp_onRemove',
				transform = function( value )
					if value == 'keep' then
						return 'Removed photos stay on disk'
					elseif value == 'trash' then
						return 'Removed photos go to the Trash'
					end
					return 'Removed photos are deleted'
				end,
			},

			f:row {
				f:static_text { title = 'When a photo is removed:', alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_onRemove',
					items = {
						{ title = 'Delete the published file', value = 'delete' },
						{ title = MAC_ENV and 'Move the published file to the Trash'
							or 'Move the published file to the Recycle Bin', value = 'trash' },
						{ title = 'Leave the published file on disk', value = 'keep' },
					},
				},
			},

			f:row {
				f:spacer { width = labelWidth },
				f:checkbox {
					value = bind 'fp_pruneEmptyFolders',
					title = 'Remove folders that become empty',
				},
			},

			f:row {
				f:static_text { title = 'Published file date:', alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'fp_fileDate',
					items = {
						{ title = 'Time of publishing', value = 'export' },
						{ title = 'Photo capture time', value = 'capture' },
					},
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Collection settings

function FPDialogs.collectionSettingsView( f, collectionSettings )
	local labelWidth = share 'fp_colLabelWidth'
	return f:group_box {
		title = 'Folder Publisher',
		fill_horizontal = 1,
		bind_to_object = collectionSettings,

		f:column {
			spacing = f:control_spacing(),
			fill_horizontal = 1,

			f:row {
				f:static_text { title = 'Sub-folder in the root:', alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'subfolder',
					immediate = true,
					width_in_chars = 28,
				},
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = 'Optional. Tokens such as {Collection}, {CollectionPath} or {YYYY} are allowed.',
					size = 'small',
				},
			},
			f:row {
				f:static_text { title = 'Folder structure:', alignment = 'right', width = labelWidth },
				f:popup_menu {
					value = bind 'structure',
					items = {
						{ title = 'Mirror Lightroom folders', value = 'mirror' },
						{ title = 'Flat: all files in one folder', value = 'flatten' },
					},
				},
			},
			f:row {
				f:static_text { title = 'Skip more folders:', alignment = 'right', width = labelWidth },
				f:edit_field {
					value = bind 'extraSkipLevels',
					min = 0, max = 99, precision = 0, width_in_digits = 3,
				},
				f:static_text { title = '(added to the service setting)' },
			},
			f:row {
				f:spacer { width = labelWidth },
				f:static_text {
					title = 'Photos whose target path changes are marked for republishing,\n'
						.. 'and their old files are removed when you publish.',
					size = 'small',
					height_in_lines = 2,
				},
			},
		},
	}
end

return FPDialogs
