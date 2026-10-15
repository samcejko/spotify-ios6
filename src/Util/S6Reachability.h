#import <Foundation/Foundation.h>

// Which way the device is online right now (asked each time, cheap)
@interface S6Reachability : NSObject
+ (BOOL)online;
+ (BOOL)onCellular;      // mobile data, not Wi-Fi
@end
