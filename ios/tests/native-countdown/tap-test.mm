#import "../../MotoNav/NativeCountdownTap.h"
#import <mach-o/dyld.h>
#include <cassert>
#include <atomic>
#include <cstring>
#include <stdexcept>

extern "C" volatile uint64_t MNCountdownParseRVA, MNCountdownSignalRVA;
extern "C" bool MNCountdownParse(void *, int32_t, const uint8_t *, uint32_t);
extern "C" void MNCountdownSignal(void *, const void *, uint32_t);
static int parses=0, signals=0; static bool throwOriginal=false;
static std::atomic<int> deliveries{0};
static void *expectedSelf=reinterpret_cast<void *>(0x1234);
static int32_t values[10]={27,2,18,0,0,0,0,0,0,0};
static const uint8_t json[]="{}";
static void originalSignal(void *self,const void *data,uint32_t count) {
    assert(self==expectedSelf); ++signals;
    if(count) assert(data==values);
}
static bool originalParse(void *self,int32_t code,const uint8_t *data,uint32_t len) {
    assert(self==expectedSelf && code==200 && data==json && len==2); ++parses;
    if(throwOriginal)throw std::runtime_error("synthetic");
    MNCountdownSignal(self,values,1);return false;
}
int main() {
    @autoreleasepool {
        uintptr_t base=reinterpret_cast<uintptr_t>(_dyld_get_image_header(0));
        MNCountdownParseRVA=reinterpret_cast<uintptr_t>(&originalParse)-base;
        MNCountdownSignalRVA=reinterpret_cast<uintptr_t>(&originalSignal)-base;
        MNCountdownSetContext(0,NO);
        assert(!MNCountdownParse(expectedSelf,200,json,2));
        assert(parses==1 && signals==1);
        assert([MNCountdownCounters()[@"captures"] intValue]==0);
        dispatch_semaphore_t sem=dispatch_semaphore_create(0);
        id observer=[[NSNotificationCenter defaultCenter] addObserverForName:@"MotoNav.Countdown.Accepted"
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                if([note.userInfo[@"epoch"] unsignedLongLongValue]!=9)return;
                NSData *body=note.userInfo[@"body"], *bytes=note.userInfo[@"signals"];
                if(body) {
                    assert(body.length==2 && bytes.length==40);
                    assert(std::memcmp(bytes.bytes,values,40)==0);
                }
                deliveries.fetch_add(1);dispatch_semaphore_signal(sem);
            }];
        MNCountdownSetContext(9,YES);
        assert(!MNCountdownParse(expectedSelf,200,json,2));
        assert(parses==2 && signals==2);
        assert(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
        assert(deliveries==1);
        // A non-response update cannot acquire a fresh response transaction.
        MNCountdownSignal(expectedSelf,values,1);
        assert([MNCountdownCounters()[@"rejected"] intValue]>=1);
        MNCountdownSignal(expectedSelf,nullptr,0);
        assert(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
        assert(deliveries==2);
        throwOriginal=true;
        try { MNCountdownParse(expectedSelf,200,json,2); assert(false); }
        catch(const std::runtime_error &) {}
        // Restoring the thread context after an SDK exception is essential.
        uint64_t before=[MNCountdownCounters()[@"captures"] unsignedLongLongValue];
        MNCountdownSignal(expectedSelf,values,1);
        assert([MNCountdownCounters()[@"captures"] unsignedLongLongValue]==before);
        assert([MNCountdownCounters()[@"parseReturnedFalse"] unsignedLongLongValue]==1);
        assert([MNCountdownCounters()[@"parseReturnedTrue"] unsignedLongLongValue]==0);
        assert([MNCountdownCounters()[@"parseExceptions"] unsignedLongLongValue]==1);
        MNCountdownSetContext(10,NO);
        MNCountdownSignal(expectedSelf,values,1);
        assert([MNCountdownCounters()[@"captures"] unsignedLongLongValue]==before);
        assert([MNCountdownCounters()[@"enabled"] boolValue]==NO);
        assert([MNCountdownCounters()[@"epoch"] unsignedLongLongValue]==10);
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        puts("Native tap: original calls/return/exception, copied buffers, response ownership, clear and disable passed");
    }
}
