#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#import <IOBluetooth/IOBluetooth.h>

// The many faces of 'static'. :P
#define internal static
#define local_persist static
#define global_variable static

#define USERDATA_TAG "hs._db.bluetooth"
int refTable;

/***********/
/* Helpers */
/***********/

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
    NSLog(@"NSObject: Method signature could not be created.");
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

/************/
/* Userdata */
/************/

@interface HSBluetoothWatcher: NSObject
@property int callbackRef;
@property IOBluetoothUserNotification *connectReceipt;
@property NSMutableArray *deviceConnections;
@end

@interface HSBluetoothDevice : NSObject
+ (NSString *) GetDeviceClass:(IOBluetoothDevice *)device;
+ (NSDictionary *) GetProperties:(IOBluetoothDevice *)device;
@end

@implementation HSBluetoothDevice
+ (NSString *) GetDeviceClass:(IOBluetoothDevice *)device {
  BluetoothClassOfDevice deviceClassRef = [device classOfDevice];
  // TODO: Make this an enum and expose it?
  NSString *deviceClass;
  if (deviceClassRef == 0) {
    deviceClass = @"uncategorized";
  } else if (deviceClassRef & (1 << 21)) {
    deviceClass = @"audio";
  } else if (deviceClassRef & ((1 << 10) | (1 << 8))) {
    deviceClass = @"peripheral";
  } else if (deviceClassRef & (1 << 9)) {
    deviceClass = @"phone";
  } else {
    deviceClass = [NSString stringWithFormat:@"%#x (unrecognized)", deviceClassRef];
  }
  return deviceClass;
}

+ (NSDictionary *) GetProperties:(IOBluetoothDevice *)device {
  NSDictionary *deviceProperties = @
    {
     @"name": [device name],
     @"isConnected": [NSNumber numberWithBool:[device isConnected]],
     @"deviceClass": [HSBluetoothDevice GetDeviceClass:device],
    };
  return deviceProperties;
}
@end

@implementation HSBluetoothWatcher
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

- (void) _HandleDisconnect:(__unused IOBluetoothUserNotification *)note
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
  NSDictionary *deviceProperties = [HSBluetoothDevice GetProperties:device];

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

/******************/
/* Lua Module API */
/******************/

internal int HSBluetooth_NewWatcher(lua_State *L) {
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

/*****************************/
/* Bluetooth Watcher Lua API */
/*****************************/

internal int userdata_HSBluetoothWatcher_Start(lua_State *L) {
  void **UserData = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  if(!UserData) {
    [LuaSkin logDebug:@"invalid userdata"];
    return(0);
  }
  [LuaSkin logDebug:@"starting watcher"];

  // Casting C pointers to an Objective-C pointer requires a 'bridged' cast.
  HSBluetoothWatcher *BTWatcher = (__bridge HSBluetoothWatcher *)(*UserData);

  // Register for bluetooth connection notifications.
  BTWatcher.deviceConnections = [[NSMutableArray alloc] init];
  BTWatcher.connectReceipt = [IOBluetoothDevice registerForConnectNotifications:BTWatcher
                                                                       selector:@selector(HandleConnect:device:)];

  // Push the watcher back on the stack to allow method chaining.
  lua_settop(L, 1);
  return(1);
}

internal int userdata_HSBluetoothWatcher_Stop(lua_State *L) {
  void **UserData = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  if(!UserData) {
    return(0);
  }

  // Casting C pointers to an Objective-C pointer requires a 'bridged' cast.
  HSBluetoothWatcher *BTWatcher = (__bridge HSBluetoothWatcher *)(*UserData);

  // Unregister for bluetooth connection notfications.
  if(BTWatcher.connectReceipt) {
    [BTWatcher.connectReceipt unregister];
  }
  BTWatcher.connectReceipt = nil;

  // Unregister from device disconnect notifications.
  if(BTWatcher.deviceConnections) {
    for(id connection in BTWatcher.deviceConnections) {
      [LuaSkin logDebug:@"unregistering device connection"];
      [connection unregister];
    }
  }
  BTWatcher.deviceConnections = nil;

  // Push the watcher back on the stack to allow method chaining.
  lua_settop(L, 1);
  return(1);
}

/**
   Custom string representation of this module's "userdata" object, if any.

   By default, userdata would appear as something like: userdata: 0x600000652bc8.
   This function should push a string onto the Lua stack and return 1 to indicate
   one result is being returned.
*/
internal int userdata_HSBluetoothWatcher_ToString(lua_State *L) {
  NSString *stringRep = [NSString stringWithFormat:@"%s: (%p)", USERDATA_TAG, lua_topointer(L, 1)];
  lua_pushstring(L, [stringRep UTF8String]);
  return(1);
}

/**
   Special cleanup to be done whenever a specific userdata instance is garbage
   collected.
*/
internal int userdata_HSBluetoothWatcher_GC(lua_State *L) {
  userdata_HSBluetoothWatcher_Stop(L);

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
global_variable const luaL_Reg userdata_HSBluetoothWatcher_publicAPI[] =
  {
   {"start", userdata_HSBluetoothWatcher_Start},
   {"stop", userdata_HSBluetoothWatcher_Stop},
   {"__tostring", userdata_HSBluetoothWatcher_ToString},
   {"__gc", userdata_HSBluetoothWatcher_GC},
   {0, 0} // or perhaps {NULL, NULL}
  };

/**
   Public API for this module.
*/
global_variable luaL_Reg publicAPI[] =
  {
   {"newWatcher", HSBluetooth_NewWatcher},
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
                             objectFunctions:userdata_HSBluetoothWatcher_publicAPI];
  return(1);
}
