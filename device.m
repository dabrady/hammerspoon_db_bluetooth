@import LuaSkin;
#import "device.h"
#import "macros.h"

internal NSSet *readableDeviceProperties;
@implementation HSBluetoothDevice
+ (NSSet *) readableDeviceProperties {
  if (!readableDeviceProperties) {
    readableDeviceProperties = [NSSet setWithObjects: @"addressString",
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
  }
  return readableDeviceProperties;
}

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
