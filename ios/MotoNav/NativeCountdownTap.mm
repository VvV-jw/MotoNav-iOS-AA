#import "NativeCountdownTap.h"
#import <mach-o/dyld.h>
#include <atomic>
#include <cstdint>
#include <cstring>

// Only the isolated build's post-link tool replaces these sentinel RVAs. A
// successful build verifies every replaced call before producing an IPA.
extern "C" {
__attribute__((used, visibility("default"))) volatile uint64_t MNCountdownParseRVA = 0x4d4e435450415253ULL;
__attribute__((used, visibility("default"))) volatile uint64_t MNCountdownSignalRVA = 0x4d4e43545349474eULL;
}

namespace {
std::atomic<uint64_t> epoch{0}, parses{0}, events{0}, captures{0}, clears{0}, rejected{0};
std::atomic<unsigned> pending{0};
std::atomic<bool> enabled{false};
// Bounded transaction context; the SDK owns the bytes until parse returns.
struct ParseContext { const void *bytes; uint32_t length; uint64_t owner; ParseContext *previous; };
thread_local ParseContext *current = nullptr;
constexpr uint32_t maxBytes = 262144, maxSignals = 32;
constexpr size_t stride = 40; // Pinned SDK's normalized TrafficSignal, not a C++ vector.
struct PendingRelease { ~PendingRelease() { pending.fetch_sub(1); } };
dispatch_queue_t queue() {
    static dispatch_queue_t q = dispatch_queue_create("com.motonav.countdown.observe", DISPATCH_QUEUE_SERIAL);
    return q;
}
using Parse = bool (*)(void *, int32_t, const uint8_t *, uint32_t);
using Signal = void (*)(void *, const void *, uint32_t);
uintptr_t original(uint64_t rva) {
    // The wrapper and original are both linked into the main arm64 image.
    return reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) + rva;
}
}

void MNCountdownSetContext(uint64_t value, BOOL on) {
    enabled.store(false, std::memory_order_release);
    epoch.store(value, std::memory_order_release);
    enabled.store(on && value != 0, std::memory_order_release);
}

NSDictionary<NSString *, NSNumber *> *MNCountdownCounters(void) {
    return @{ @"parses": @(parses.load()), @"events": @(events.load()),
              @"captures": @(captures.load()), @"clears": @(clears.load()), @"rejected": @(rejected.load()) };
}

extern "C" __attribute__((used, visibility("default"), noinline))
bool MNCountdownParse(void *self, int32_t code, const uint8_t *bytes, uint32_t length) {
    ParseContext frame{bytes, length, epoch.load(std::memory_order_acquire), current};
    const bool observe = enabled.load(std::memory_order_acquire) && frame.owner != 0;
    if (observe) { current = &frame; parses.fetch_add(1, std::memory_order_relaxed); }
    // Preserve the original call, its return value and exception propagation.
    bool result;
    try { result = reinterpret_cast<Parse>(original(MNCountdownParseRVA))(self, code, bytes, length); }
    catch (...) { if (observe) current = frame.previous; throw; }
    if (observe) current = frame.previous;
    return result;
}

extern "C" __attribute__((used, visibility("default"), noinline))
void MNCountdownSignal(void *self, const void *signals, uint32_t count) {
    // Deliver to the SDK's own observers first, exactly once, including hide events.
    reinterpret_cast<Signal>(original(MNCountdownSignalRVA))(self, signals, count);
    if (!enabled.load(std::memory_order_acquire)) return;
    const uint64_t owner = epoch.load(std::memory_order_acquire);
    if (!owner) return;
    events.fetch_add(1, std::memory_order_relaxed);
    if (!count) {
        clears.fetch_add(1, std::memory_order_relaxed);
        dispatch_async(queue(), ^{
            if (enabled.load() && epoch.load() == owner)
                [[NSNotificationCenter defaultCenter] postNotificationName:@"MotoNav.Countdown.Accepted"
                    object:nil userInfo:@{ @"epoch": @(owner), @"clear": @YES }];
        });
        return;
    }
    ParseContext *frame = current;
    if (!frame || frame->owner != owner || !frame->bytes || frame->length < 2 ||
        frame->length > maxBytes || !signals || count > maxSignals) {
        rejected.fetch_add(1, std::memory_order_relaxed); return;
    }
    @autoreleasepool {
        if (pending.fetch_add(1) >= 2) {
            pending.fetch_sub(1); rejected.fetch_add(1); return;
        }
        @try {
        // Copy while both SDK-owned inputs are alive. No pointer escapes the call.
        NSData *body = [NSData dataWithBytes:frame->bytes length:frame->length];
        NSData *accepted = [NSData dataWithBytes:signals length:stride * count];
        const double at = NSProcessInfo.processInfo.systemUptime;
        captures.fetch_add(1, std::memory_order_relaxed);
        dispatch_async(queue(), ^{
            PendingRelease release;
            if (!enabled.load() || epoch.load() != owner) return;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MotoNav.Countdown.Accepted"
                object:nil userInfo:@{ @"epoch": @(owner), @"body": body,
                                      @"signals": accepted, @"uptime": @(at) }];
        });
        } @catch (NSException *) {
            pending.fetch_sub(1); rejected.fetch_add(1);
        }
    }
}
