#import <Foundation/Foundation.h>

// Our own bridge. It does not change SDK configuration or service decisions.
FOUNDATION_EXPORT void MNCountdownSetContext(uint64_t epoch, BOOL enabled);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *MNCountdownCounters(void);
