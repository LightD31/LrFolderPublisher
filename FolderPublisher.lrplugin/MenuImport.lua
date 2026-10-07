-- Library > Plug-in Extras > Folder Publisher: Import from Another Publish Service…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMigration = require 'FPMigration'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( FPMigration.run )
	if not ok then
		LrDialogs.message( 'Folder Publisher', 'The import failed: ' .. tostring( err ), 'critical' )
	end
end )
