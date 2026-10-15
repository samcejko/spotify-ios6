#import "S6Reachability.h"
#import "S6Common.h"
#import <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

@implementation S6Reachability

static SCNetworkReachabilityFlags S6Flags(void)
{
    static SCNetworkReachabilityRef reach;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct sockaddr_in zero;
        memset(&zero, 0, sizeof(zero));
        zero.sin_len = sizeof(zero);
        zero.sin_family = AF_INET;
        reach = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zero);
    });
    SCNetworkReachabilityFlags flags = 0;
    if (!reach || !SCNetworkReachabilityGetFlags(reach, &flags)) return 0;
    return flags;
}

+ (BOOL)online
{
    SCNetworkReachabilityFlags f = S6Flags();
    return (f & kSCNetworkReachabilityFlagsReachable) && !(f & kSCNetworkReachabilityFlagsConnectionRequired);
}

+ (BOOL)onCellular
{
    SCNetworkReachabilityFlags f = S6Flags();
    return (f & kSCNetworkReachabilityFlagsReachable) && (f & kSCNetworkReachabilityFlagsIsWWAN);
}

@end
