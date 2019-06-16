@import Cocoa;
@import LuaSkin;
@import IOBluetooth;
#import "device.h"
#import "macros.h"

#define USERDATA_TAG "hs._db.bluetooth"
// A Lua table where we will store any references to Lua objects needed by this library.
global_variable int refTable;

internal int pushReadableDeviceProperties(__unused lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  [Skin pushNSObject:[[HSBluetoothDevice readableDeviceProperties] allObjects]];
  return(1);
}

/**
   Public API for this module.
*/
global_variable luaL_Reg publicAPI[] = {{NULL, NULL}};

/**
   Invoked by Lua when something `require`s our module.

   This function registers our public API with the LuaSkin bridge for Hammerspoon.
 */
int luaopen_hs__db_bluetooth_internal(lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  refTable = [Skin registerLibraryWithObject:USERDATA_TAG
                                   functions:publicAPI
                               metaFunctions:nil // metaAPI
                             objectFunctions:nil // userdata_publicAPI
              ];

  // Important properties of an IOBluetoothDevice.
  // Create a constant: `hs._db.bluetooth.readableDeviceProperties[]`
  pushReadableDeviceProperties(L); lua_setfield(L, -2, "readableDeviceProperties");

  return(1);
}
