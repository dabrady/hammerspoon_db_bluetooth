@import Cocoa;
@import LuaSkin;
@import IOBluetooth;
#import "device.h"
#import "macros.h"

#pragma mark - Macros, Forward Declarations, and Globals

#define USERDATA_TAG "hs._db.bluetooth.watcher"

@class HSBluetoothWatcher;

// A Lua table where we will store any references to Lua objects needed by this library.
global_variable int refTable = LUA_NOREF;
#pragma mark - Userdata and Support

@interface HSBluetoothWatcher: NSObject
@property int callbackRef;
@property NSSet *devicePropertiesToQuery;
@property IOBluetoothUserNotification *connectReceipt;
@property NSMutableArray *deviceConnections;
@end

// NOTE: I was unable to successfully separate this category into a separate file and link it.
@interface NSObject (VarargPerformSelectorOnMainThread)
/** A helper for executing functions which require multiple arguments, on the main thread. */
- (void) performSelectorOnMainThread:(SEL)selector
                       waitUntilDone:(BOOL)wait
                         withObjects:(NSObject *)firstObject, ... NS_REQUIRES_NIL_TERMINATION;
@end

@implementation NSObject (VarargPerformSelectorOnMainThread)
/** A helper for executing functions which require multiple arguments, on the main thread. */
- (void) performSelectorOnMainThread:(SEL)selector
                       waitUntilDone:(BOOL)wait
                         withObjects:(NSObject *)firstObject, ... {

  // First attempt to create the method signature with the provided selector.
  NSMethodSignature *signature = [self methodSignatureForSelector:selector];

  if (!signature) {
    [LuaSkin logError:@"NSObject: Method signature could not be created."];
    return;
  }

  // Next we create the invocation that will actually call the selector.
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
  [invocation setTarget:self];
  [invocation setSelector:selector];

  // Now add arguments from the variable list of objects (nil terminated).
  va_list args;
  va_start(args, firstObject);
  int nextArgIndex = 2;

  for (NSObject *object = firstObject;
       object != nil;
       object = va_arg(args, NSObject*)) {
    if (object != [NSNull null]) {
      [invocation setArgument:&object atIndex:nextArgIndex];
    }

    nextArgIndex++;
  }

  va_end(args);

  // Finally, we invoke the selector with the arguments we've set.
  [invocation retainArguments];
  [invocation performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:wait];
}
@end

@implementation HSBluetoothWatcher
- (instancetype) init {
  self = [super init];

  if (self) {
    _callbackRef = LUA_NOREF;
    // TODO: Import from internal.m
    _devicePropertiesToQuery = [HSBluetoothDevice readableDeviceProperties];
    _connectReceipt = NULL;
    _deviceConnections = [[NSMutableArray alloc] init];
  }

  return(self);
}

- (void) HandleConnect:(IOBluetoothUserNotification *)note
                device:(IOBluetoothDevice *)device {
  // Hammerspoon crashes when Lua code doesn't execute on the main thread.
  [self performSelectorOnMainThread:@selector(_HandleConnect:device:)
                      waitUntilDone:YES
                        withObjects:note, device, nil];
}

- (void) HandleDisconnect:(IOBluetoothUserNotification *)note
                   device:(IOBluetoothDevice *)device {
  [self performSelectorOnMainThread:@selector(_HandleDisconnect:device:)
                      waitUntilDone:YES
                        withObjects:note, device, nil];
}

- (void) _HandleConnect:(__unused IOBluetoothUserNotification *)note
                 device:(IOBluetoothDevice *)device {

  // Track device disconnect.
  IOBluetoothUserNotification *deviceConnection =
    [device registerForDisconnectNotification:self
                                     selector:@selector(HandleDisconnect:device:)];
  [_deviceConnections addObject:deviceConnection];

  if (_callbackRef != LUA_NOREF) {
    [self _CallbackWithDevice:device];
  }
}

- (void) _HandleDisconnect:(IOBluetoothUserNotification *)note
                    device:(IOBluetoothDevice *)device {
  [note unregister];
  [_deviceConnections removeObjectIdenticalTo:note];

  if (_callbackRef != LUA_NOREF) {
    [self _CallbackWithDevice:device];
  }
}

- (void) _CallbackWithDevice:(IOBluetoothDevice *)device {
  LuaSkin *Skin = [LuaSkin shared];
  lua_State *L = [Skin L];
  NSDictionary *deviceProperties = [HSBluetoothDevice GetProperties:device properties:_devicePropertiesToQuery];

  // Push our callback and its arguments onto the stack, then call it.
  [Skin pushLuaRef:refTable ref:_callbackRef];
  [Skin pushNSObject:deviceProperties];

  BOOL callSuccessful = [Skin protectedCallAndTraceback:1 nresults: 0];
  if (!callSuccessful) {
    const char *errorMsg = lua_tostring(L, -1);
    [Skin logError:[NSString stringWithFormat:@"%s: %s", USERDATA_TAG, errorMsg]];
    lua_pop(L, 1); // consume the error message
  }
}
@end

#pragma mark - Module Functions

internal int bluetooth_watcher_new(lua_State *L) {
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

  BTWatcher.connectReceipt = nil;

  /* Give our new bluetooth listener back to Lua. */
  // Allocate a new userdata ref onto the stack.
  void **Userdata = lua_newuserdata(L, sizeof(id*));
  // Store the bluetooth watcher on the stack.
  // `__bridge_retainable` is a hint to the ARC memory manager that this points at
  // an object that should be retained, promising to release it later.
  *Userdata = (__bridge_retained void *)BTWatcher;

  /* Tag our watcher so we can identify its type later. */
  luaL_getmetatable(L, USERDATA_TAG);
  lua_setmetatable(L, -2);

  return(1);
}

#pragma mark - Module Methods

internal int bluetooth_watcher_devicePropertiesToQuery(lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  // Since this is a method, the first argument is the watcher itself (the userdata tag).
  // Then comes the real arguments to the method: ours only accepts an optional list of strings.
  [Skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK];

  HSBluetoothWatcher *BTWatcher = [Skin toNSObjectAtIndex:1];

  if(lua_gettop(L) == 1) {
    // When no input is given, act as a getter.
    [Skin pushNSObject:BTWatcher.devicePropertiesToQuery];
  } else {
    NSArray *deviceProperties = [Skin toNSObjectAtIndex:2];

    // Validate our input.
    if ([deviceProperties isKindOfClass:[NSArray class]]) {
      // NOTE: `__block` allows changes to this variable within nested blocks to be
      // seen by the enclosing scope.
      __block NSString *errorMessage;
      __block NSMutableSet *devicePropertiesToQuery = [[NSMutableSet alloc] initWithCapacity:[deviceProperties count]];

      [deviceProperties enumerateObjectsUsingBlock:^(NSString *item, NSUInteger index, BOOL *stop) {
          if ([item isKindOfClass:[NSString class]]) {
            if ([[HSBluetoothDevice readableDeviceProperties] containsObject:item]) {
              [devicePropertiesToQuery addObject:item];
            } else {
              // Ignore unreadable properties.
              [LuaSkin logWarn:[NSString stringWithFormat:@"reading '%@' from IOBluetoothDevice is not supported", item]];
            }
          } else {
            *stop = YES;
            errorMessage = [NSString stringWithFormat:@"expected string at index %lu", index + 1]; // `lu` == long unsigned
          }
        }];

      if(errorMessage) {
        return luaL_argerror(L, 2, [errorMessage UTF8String]);
      }

      // [LuaSkin logDebg:@"configuring device query"];

      // Store the device properties.
      BTWatcher.devicePropertiesToQuery = [NSSet setWithSet:devicePropertiesToQuery];

      // Return this watcher.
      lua_settop(L, 1);
    } else {
      return luaL_argerror(L, 2, "expected an array of device properties");
    }
  }

  return(1);
}

internal int bluetooth_watcher_start(lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  [Skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];

  HSBluetoothWatcher *BTWatcher = [Skin toNSObjectAtIndex:1];

  // [LuaSkin logDebug:@"starting watcher"];

  // Register for bluetooth connection notifications.
  BTWatcher.connectReceipt = [IOBluetoothDevice registerForConnectNotifications:BTWatcher
                                                                       selector:@selector(HandleConnect:device:)];

  // Push the watcher back on the stack to allow method chaining.
  lua_settop(L, 1);
  return(1);
}

internal int bluetooth_watcher_stop(lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  [Skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];

  HSBluetoothWatcher *BTWatcher = [Skin toNSObjectAtIndex:1];

  // Unregister for bluetooth connection notfications.
  if (BTWatcher.connectReceipt) {
    [BTWatcher.connectReceipt unregister];
  }
  BTWatcher.connectReceipt = nil;

  // Unregister from device disconnect notifications.
  if (BTWatcher.deviceConnections) {
    for(id connection in BTWatcher.deviceConnections) {
      [connection unregister];
    }
  }
  BTWatcher.deviceConnections = nil;

  // Push the watcher back on the stack to allow method chaining.
  lua_settop(L, 1);
  return(1);
}

#pragma mark - Module Constants

#pragma mark - Lua <--> NSObject Conversion Functions

id ToHSBluetoothWatcherFromUserdata(lua_State *L, int index) {
  LuaSkin *Skin = [LuaSkin shared];

  void **Userdata = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  HSBluetoothWatcher *BTWatcher;
  if(Userdata) {
    BTWatcher = (__bridge HSBluetoothWatcher *)(*Userdata);
  } else {
    [Skin logError:[NSString stringWithFormat:@"expected %s object, found %s", USERDATA_TAG, lua_typename(L, lua_type(L, index))]];
  }

  return(BTWatcher);
}

#pragma mark - Hammerspoon/Lua Infrastructure

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
  bluetooth_watcher_stop(L);

  // Verify the userdata is ours.
  void **Userdata = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  // Grab a pointer to our bluetooth watcher.
  // `__bridge_transfer` tells the ARC memory manager to release it when we're done.
  HSBluetoothWatcher *BTWatcher = (__bridge_transfer HSBluetoothWatcher *)(*Userdata);

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


global_variable const luaL_Reg metaAPI[] = {{NULL, NULL}};
global_variable const luaL_Reg publicAPI[] = {{"new", bluetooth_watcher_new},
                                              {NULL, NULL}};
global_variable const luaL_Reg userdata_publicAPI[] = {{"devicePropertiesToQuery", bluetooth_watcher_devicePropertiesToQuery},
                                                       {"start", bluetooth_watcher_start},
                                                       {"stop", bluetooth_watcher_stop},
                                                       {"__tostring", userdata_tostring},
                                                       {"__gc", userdata_gc},
                                                       {NULL, NULL}};

int luaopen_hs__db_bluetooth_watcher(__unused lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  refTable = [Skin registerLibraryWithObject:USERDATA_TAG
                                   functions:publicAPI
                               metaFunctions:metaAPI
                             objectFunctions:userdata_publicAPI];
  [Skin registerLuaObjectHelper:ToHSBluetoothWatcherFromUserdata
                       forClass:"HSBluetoothWatcher"
            withUserdataMapping:USERDATA_TAG];
  return(1);
}
