#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>

// The many faces of 'static'. :P
#define internal static
#define local_persist static
#define global_variable static

#define USERDATA_TAG "hs._db.bluetooth"
int refTable;

@interface HSBluetoothWatcher: NSObject
@property int callbackRef;
@end

@implementation HSBluetoothWatcher
// TODO
@end

/**
   Example Lua entrypoint:

   internal int ModuleFunction(lua_State *L) {
     // ...
     return(1); // the number of results pushed onto the stack
   }
*/
internal int NewWatcher(lua_State *L) {
  // Get a reference to our Lua 'skin', our interface with Lua.
  LuaSkin *Skin = [LuaSkin shared];
  // Verify that the first argument passed to us is a Lua function.
  // If it isn't, execution ends with a Lua traceback to the user.
  [Skin checkArgs:LS_TFUNCTION, LS_TBREAK];

  // Allocate memory for, and initialize, a new bluetooth watcher.
  HSBluetoothWatcher *BTWatcher = [[HSBluetoothWatcher alloc] init];

  /* Store a reference to the given callback function (without discarding it). */
  // Push a copy of the argument to the top of the stack.
  lua_pushvalue(L, 1);
  // Pops the argument copy off the stack, stores it in our module ref table
  // for garbage collection purposes, and saves a pointer to it in our new
  // bluetooth watcher reference.
  BTWatcher.callbackRef = [Skin luaRef:refTable];

  /* Give our new bluetooth listener back to Lua. */
  // Allocate a new userdata ref onto the stack.
  void **UserData = lua_newuserdata(L, sizeof(id*));
  // Store the bluetooth watcher on the stack.
  // `__bridge_retainable` is a hint to the ARC memory manager that this points at
  // an object that should be retained, promising to release it later.
  *UserData = (__bridge_retained void *)BTWatcher;

  /* Tag our watcher so we can identify its type later. */
  luaL_getmetatable(L, USERDATA_TAG);
  lua_setmetatable(L, -2);

  return(1);
}

/**
   Custom string representation of this module's "userdata" object, if any.

   By default, userdata would appear as something like: userdata: 0x600000652bc8.
   This function should push a string onto the Lua stack and return 1 to indicate
   one result is being returned.
*/
internal int userdata_tostring(lua_State *L) {
  NSString *stringRep = [NSString stringWithFormat:@"%s: (%p)", USERDATA_TAG, lua_topointer(L, 1)];
  lua_pushstring(L, [stringRep UTF8String]);
  return(1);
}

/**
   Special cleanup to be done whenever a specific userdata instance is garbage
   collected.
*/
internal int userdata_gc(lua_State *L) {
  // Verify the userdata is ours.
  void **UserData = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  // Grab a pointer to our bluetooth watcher.
  // `__bridge_transfer` tells the ARC memory manager to release it when we're done.
  HSBluetoothWatcher *BTWatcher = (__bridge_transfer HSBluetoothWatcher *)(*UserData);
  // Free the callback we kept a reference to in our `refTable`.
  BTWatcher.callbackRef = [[LuaSkin shared] luaUnref:refTable ref:BTWatcher.callbackRef];
  // Free our watcher.
  BTWatcher = nil;

  return(0);
}

/**
   Special cleanup to be done whenever this entire module is garbage collected.
   Usually only happens when Hammerspoon config reloads or Hammerspoon exits.
*/
// internal int meta_gc(lua_State __unused *L) {
//   return(0);
// }

/**
   Module metatable; rarely used unless providing custom garbage collection.
*/
// global_variable const luaL_Reg module_metatable[] =
//   {
//    {"__gc", meta_gc},
//    {0, 0} // or perhaps {NULL, NULL}
//   };

/**
   Userdata API, used as its Lua metatable.
*/
global_variable const luaL_Reg userdata_publicAPI[] =
  {
   {"__tostring", userdata_tostring},
   {"__gc", userdata_gc},
   {0, 0} // or perhaps {NULL, NULL}
  };

/**
   Public API for this module.
*/
global_variable luaL_Reg publicAPI[] =
  {
   {"new", NewWatcher},
   {0, 0} // or perhaps {NULL, NULL}
  };

/**
   Invoked by Lua when something `require`s our module.

   This function registers our public API with the LuaSkin bridge for Hammerspoon.
 */
int luaopen_hs__db_bluetooth_internal(lua_State __unused *L) {
  LuaSkin *skin = [LuaSkin shared];
  refTable = [skin registerLibraryWithObject:USERDATA_TAG
                                   functions:publicAPI
                               metaFunctions:nil
                             objectFunctions:userdata_publicAPI];
  return(1);
}
