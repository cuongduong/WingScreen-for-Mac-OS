#import "CGVirtualDisplayKit.h"
#import <dlfcn.h>

typedef CFTypeRef _Nullable (*WSCreateFn)(CGDirectDisplayID, size_t, size_t, int32_t,
                                          CFDictionaryRef _Nullable, dispatch_queue_t, id);
typedef int32_t (*WSStartStopFn)(CFTypeRef);

@interface WSDisplayStreamBox : NSObject
@property (nonatomic, assign) CFTypeRef stream;
@property (nonatomic, strong) id block;
@end

@implementation WSDisplayStreamBox
- (void)dealloc {
    if (_stream) CFRelease(_stream);
}
@end

static id WSLookupKey(const char *name) {
    CFStringRef *p = (CFStringRef *)dlsym(RTLD_DEFAULT, name);
    return p && *p ? (__bridge NSString *)*p : nil;
}

NSObject *WSStartDisplayStream(CGDirectDisplayID display, size_t width, size_t height,
                               double fps, dispatch_queue_t queue, WSDisplayFrameHandler handler) {
    WSCreateFn create = (WSCreateFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    WSStartStopFn start = (WSStartStopFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    if (!create || !start) {
        NSLog(@"[WingScreen] CGDisplayStream is not available on this macOS");
        return nil;
    }

    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    id kMin = WSLookupKey("kCGDisplayStreamMinimumFrameTime");
    id kCursor = WSLookupKey("kCGDisplayStreamShowCursor");
    id kDepth = WSLookupKey("kCGDisplayStreamQueueDepth");
    if (kMin) props[kMin] = @(1.0 / (fps > 0 ? fps : 30));
    if (kCursor) props[kCursor] = @YES;
    if (kDepth) props[kDepth] = @4;

    WSDisplayFrameHandler h = [handler copy];
    // Trạng thái 0 = kCGDisplayStreamFrameStatusFrameComplete
    id block = [^(int32_t status, uint64_t displayTime, IOSurfaceRef _Nullable surface, CFTypeRef _Nullable update) {
        if (status == 0 && surface) h(surface);
    } copy];

    const int32_t nv12 = '420v';
    CFTypeRef stream = create(display, width, height, nv12, (__bridge CFDictionaryRef)props, queue, block);
    if (!stream) {
        NSLog(@"[WingScreen] CGDisplayStreamCreate failed");
        return nil;
    }
    WSDisplayStreamBox *box = [WSDisplayStreamBox new];
    box.stream = stream;
    box.block = block;
    int32_t err = start(stream);
    if (err != 0) {
        NSLog(@"[WingScreen] CGDisplayStreamStart failed: %d", err);
        return nil;   // box giải phóng stream
    }
    return box;
}

void WSStopDisplayStream(NSObject *object) {
    WSDisplayStreamBox *box = (WSDisplayStreamBox *)object;
    WSStartStopFn stop = (WSStartStopFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    if (stop && box.stream) stop(box.stream);
}
