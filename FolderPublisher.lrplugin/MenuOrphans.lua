-- Library > Plug-in Extras > Folder Publisher: Clean Up Orphaned Files…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMaintenance = require 'FPMaintenance'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( function()
		local service = FPMaintenance.chooseService( 'Clean Up Orphaned Files' )
		if service then
			FPMaintenance.cleanOrphans( service )
		end
	end )
	if not ok then
		LrDialogs.message( 'Folder Publisher', 'The clean-up failed: ' .. tostring( err ), 'critical' )
	end
end )
