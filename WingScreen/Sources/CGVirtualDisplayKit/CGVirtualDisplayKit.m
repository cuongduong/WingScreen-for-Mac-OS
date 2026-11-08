#import "CGVirtualDisplayKit.h"

// Khai báo giao diện các lớp private dưới dạng protocol để gọi qua `id`.
@protocol WSVDDescriptor <NSObject>
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@protocol WSVDMode <NSObject>
- (id)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@protocol WSVDSettings <NSObject>
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@protocol WSVD <NSObject>
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

NSObject *WSCreateVirtualDisplay(NSString *name,
                                 uint32_t pointWidth,
                                 uint32_t pointHeight,
                                 uint32_t pixelWidth,
                                 uint32_t pixelHeight,
                                 double refreshRate,
                                 BOOL hiDPI,
                                 CGSize sizeInMillimeters) {
    Class DescC = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class DispC = NSClassFromString(@"CGVirtualDisplay");
    Class SetC  = NSClassFromString(@"CGVirtualDisplaySettings");
    Class ModeC = NSClassFromString(@"CGVirtualDisplayMode");
    if (!DescC || !DispC || !SetC || !ModeC) {
        NSLog(@"[WingScreen] CGVirtualDisplay API not available on this macOS");
        return nil;
    }

    id<WSVDDescriptor> desc = [[DescC alloc] init];
    [desc setDispatchQueue:dispatch_get_main_queue()];
    desc.name = name;
    desc.maxPixelsWide = pixelWidth;
    desc.maxPixelsHigh = pixelHeight;
    desc.sizeInMillimeters = sizeInMillimeters;
    // Serial cố định để macOS nhớ vị trí sắp xếp màn hình giữa các lần kết nối
    desc.vendorID = 0xEEEE;
    desc.productID = 0x2019;
    desc.serialNum = 0x0001;
    desc.terminationHandler = ^(id a, id b) {
        NSLog(@"[WingScreen] Virtual display was removed by the system");
    };

    id<WSVD> display = [(id<WSVD>)[DispC alloc] initWithDescriptor:desc];
    if (!display) return nil;

    id<WSVDSettings> settings = [[SetC alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    NSMutableArray *modes = [NSMutableArray array];
    // Chế độ pixel đầy đủ + chế độ point (macOS sẽ sinh bản HiDPI tương ứng)
    [modes addObject:[(id<WSVDMode>)[ModeC alloc] initWithWidth:pixelWidth height:pixelHeight refreshRate:refreshRate]];
    if (pixelWidth != pointWidth || pixelHeight != pointHeight) {
        [modes addObject:[(id<WSVDMode>)[ModeC alloc] initWithWidth:pointWidth height:pointHeight refreshRate:refreshRate]];
    }
    settings.modes = modes;

    if (![display applySettings:settings]) {
        NSLog(@"[WingScreen] applySettings failed");
        return nil;
    }
    return (NSObject *)display;
}

CGDirectDisplayID WSVirtualDisplayGetID(NSObject *display) {
    if (![display respondsToSelector:@selector(displayID)]) return 0;
    return [(id<WSVD>)display displayID];
}
