@import Cocoa;
@import LuaSkin;
@import IOBluetooth;
#import "macros.h"

#define USERDATA_TAG "hs._db.bluetooth"
// A Lua table where we will store any references to Lua objects needed by this library.
global_variable int refTable;
// A set of device properties that can be read via `devicePropertiesToQuery`.
global_variable NSSet *readableDeviceProperties;

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

/************/
/* Userdata */
/************/

@interface HSBluetoothWatcher: NSObject
@property int callbackRef;
@property NSSet *devicePropertiesToQuery;
@property IOBluetoothUserNotification *connectReceipt;
@property NSMutableArray *deviceConnections;
@end

@interface HSBluetoothDevice : NSObject
+ (NSString *) GetDeviceCategory:(IOBluetoothDevice *)device;
+ (NSDictionary *) GetProperties:(IOBluetoothDevice *)device properties:(NSSet *)properties;
@end

@implementation HSBluetoothDevice
+ (NSString *) GetDeviceCategory:(IOBluetoothDevice *)device {
  BluetoothClassOfDevice deviceClassRef = [device classOfDevice];
  // TODO: Make this an enum and expose it?
  NSString *deviceCategory;
  if (deviceClassRef == 0) {
    deviceCategory = @"uncategorized";
  } else if (deviceClassRef & (1 << 21)) {
    deviceCategory = @"audio";
  } else if (deviceClassRef & ((1 << 10) | (1 << 8))) {
    deviceCategory = @"peripheral";
  } else if (deviceClassRef & (1 << 9)) {
    deviceCategory = @"phone";
  } else {
    deviceCategory = [NSString stringWithFormat:@"%#x (unrecognized)", deviceClassRef];
  }
  return(deviceCategory);
}

+ (void (^)(void **, const char **)) GetProperty:(IOBluetoothDevice *)device
               propertyName:(NSString *)propertyName {
  SEL propertySelector = NSSelectorFromString(propertyName);
  if (![device respondsToSelector:propertySelector]) {
    // Unrecognized property.
    return(NULL);
  }

  NSMethodSignature *signature = [[device class] instanceMethodSignatureForSelector:propertySelector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];

  void *returnValueBuffer = (void *)malloc([signature methodReturnLength]);

  [invocation setSelector:propertySelector];
  [invocation setTarget:device];
  [invocation invoke];
  [invocation getReturnValue:returnValueBuffer];

  // Return a block capable of producing the raw property value and its type encoding.
  void (^property)(void **, const char **) = ^(void **rawValue, const char **valueType){
    *rawValue = returnValueBuffer;
    *valueType = [signature methodReturnType];
  };

  return(property);
}

+ (NSDictionary *) GetProperties:(IOBluetoothDevice *)device
                      properties:(NSSet *)properties {
  NSMutableDictionary *deviceProperties = [[NSMutableDictionary alloc] initWithCapacity:[properties count]];

  [properties enumerateObjectsUsingBlock:^(NSString *propertyName, __unused BOOL *stop) {
      // My own property.
      if ([propertyName isEqual:@"deviceCategory"]) {
        [deviceProperties setObject:[HSBluetoothDevice GetDeviceCategory:device] forKey:@"deviceCategory"];
        return;
      }

      void (^property)(void **, const char **) = [HSBluetoothDevice GetProperty:device propertyName:propertyName];
      if (!property) return;

      // Read out the property info.
      void *rawPropertyValue;
      const char *propertyValueType;
      property(&rawPropertyValue, &propertyValueType);

      /**
       * NOTE:
       * Ideally, we'd simply be able to do something like this:
       *
       *     [deviceProperties setObject:rawPropertyValue
       *                          forKey:propertyName];
       *
       * However, that is not an option: we can't store raw pointers in a
       * dictionary, and even if we could, there'd be no way to give LuaSkin
       * the type information it needs to properly de/serializing the data.
       * So, we need to cast the data to the appropriate type ourselves.
       */
      if (strcmp(@encode(NSObject *), propertyValueType) == 0) {
        NSObject *val = *(__weak NSObject **)rawPropertyValue;

        if ([val isKindOfClass:[NSString class]]) {
          NSString *str = (NSString *)val;
          [deviceProperties setObject:str forKey:propertyName];
        } else {
          [LuaSkin logError:[NSString stringWithFormat:@"unrecognized object type for property '%@': %@", propertyName, [val className]]];
        }
      } else if (strcmp(@encode(BOOL), propertyValueType) == 0) {
        BOOL val = *(BOOL *)rawPropertyValue;
        [deviceProperties setObject:[NSNumber numberWithBool:val] forKey:propertyName];
      } else if (strcmp(@encode(UInt32), propertyValueType) == 0) {
        UInt32 val = *(UInt32 *)rawPropertyValue;
        [deviceProperties setObject:[NSNumber numberWithUnsignedInt:val] forKey:propertyName];
      } else {
        [LuaSkin logError:[NSString stringWithFormat:@"unrecognized property type for property '%@': %s", propertyName, propertyValueType]];
      }
    }];

  // Return a frozen copy of our properties table.
  return([[NSDictionary alloc] initWithDictionary:deviceProperties]);
}
@end

@implementation HSBluetoothWatcher
- (instancetype) init {
  self = [super init];

  if (self) {
    _callbackRef = LUA_NOREF;
    _connectReceipt = NULL;
    _deviceConnections = [[NSMutableArray alloc] init];
    _devicePropertiesToQuery = readableDeviceProperties;
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

id ToHSBluetoothWatcherFromUserdata(lua_State *L, int index) {
  LuaSkin *Skin = [LuaSkin shared];

  void **UserData = (void **)luaL_checkudata(L, 1, USERDATA_TAG);
  HSBluetoothWatcher *BTWatcher;
  if(UserData) {
    BTWatcher = (__bridge HSBluetoothWatcher *)(*UserData);
  } else {
    [Skin logError:[NSString stringWithFormat:@"expected %s object, found %s", USERDATA_TAG, lua_typename(L, lua_type(L, index))]];
  }

  return(BTWatcher);
}


/******************/
/* Lua Module API */
/******************/

internal int pushReadableDeviceProperties(__unused lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  [Skin pushNSObject:[readableDeviceProperties allObjects]];
  return(1);
}

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

internal int userdata_HSBluetoothWatcher_DevicePropertiesToQuery(lua_State *L) {
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
            if ([readableDeviceProperties containsObject:item]) {
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

internal int userdata_HSBluetoothWatcher_Start(lua_State *L) {
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

internal int userdata_HSBluetoothWatcher_Stop(lua_State *L) {
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
   {"devicePropertiesToQuery", userdata_HSBluetoothWatcher_DevicePropertiesToQuery},
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
int luaopen_hs__db_bluetooth_internal(lua_State *L) {
  LuaSkin *Skin = [LuaSkin shared];
  refTable = [Skin registerLibraryWithObject:USERDATA_TAG
                                   functions:publicAPI
                               metaFunctions:nil
                             objectFunctions:userdata_HSBluetoothWatcher_publicAPI];
  [Skin registerLuaObjectHelper:ToHSBluetoothWatcherFromUserdata
                       forClass:"HSBluetoothWatcher"
            withUserdataMapping:USERDATA_TAG];

  // Important properties of an IOBluetoothDevice.
  readableDeviceProperties = [NSSet setWithObjects:
                                    @"addressString",
                                    @"name",
                                    @"classOfDevice",
                                    @"deviceClassMajor",
                                    @"deviceClassMinor",
                                    @"deviceCategory", // my own classification
                                    @"serviceClassMajor",
                                    @"isHandsFreeDevice",
                                    @"nameOrAddress",
                                    @"isConnected",
                                    @"isFavorite",
                                    @"isPaired",
                                    nil];
  // Create a constant: `hs._db.bluetooth.readableDeviceProperties[]`
  pushReadableDeviceProperties(L); lua_setfield(L, -2, "readableDeviceProperties");

  return(1);
}
