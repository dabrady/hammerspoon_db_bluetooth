local USERDATA_TAG = 'hs._db.bluetooth'
local module = require(USERDATA_TAG..'.internal')
module.watcher = require(USERDATA_TAG..'.watcher')
module.readableDeviceProperties = ls.makeConstantsTable(module.readableDeviceProperties)

return module
