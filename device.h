@import Cocoa;
@import IOBluetooth;

@interface HSBluetoothDevice : NSObject
+ (NSSet *) readableDeviceProperties;
+ (NSString *) GetDeviceCategory:(IOBluetoothDevice *)device;
+ (NSDictionary *) GetProperties:(IOBluetoothDevice *)device properties:(NSSet *)properties;
@end
