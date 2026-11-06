#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <zlib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PDDDiagnostics.h"

// ==========================================
// 1. iPhone 11 坐标配置 (逻辑尺寸 414 x 896)
// ==========================================
static const CGPoint kSearchBoxPoint      = {207.0, 75.0};  // 顶部搜索框
static const CGPoint kKeyboardSearchPoint = {350.0, 800.0}; // 键盘右下角“搜索”键
static const CGPoint kGoods1Point         = {105.0, 490.0}; // 列表左上角第一个商品（汰渍）
static const CGPoint kBackPoint           = {30.0, 50.0};   // 详情页左上角返回键

// ==========================================
// 2. 提前声明 PDDActionProxy 类
// ==========================================
@interface PDDActionProxy : NSObject
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)drag:(UIPanGestureRecognizer *)gesture;
- (void)cloudTick:(NSTimer *)timer;
@end

// ==========================================
// 3. 全局配置与状态
// ==========================================
static NSString * const kDataFolderName = @"PDDGoodsData";
static NSInteger kFloatingButtonTag = 0x50444452;
static BOOL gEnabled = YES;
__attribute__((unused)) static BOOL gPresented = NO;
static NSString * const kEnabledDefaultsKey = @"PDDReplicaEnabled";
static NSString * const kCloudServerURLKey = @"PDDReplicaCloudServerURL";
static NSString * const kCloudDeviceIDKey = @"PDDReplicaCloudDeviceID";
static NSString * const kCloudDeviceTokenKey = @"PDDReplicaCloudDeviceToken";
static const NSTimeInterval kCloudPollInterval = 5.0;
static const NSTimeInterval kCloudHeartbeatInterval = 15.0;

static dispatch_queue_t gCaptureQueue;
static NSUInteger gCaptureCount = 0;
static NSString *gActiveTaskID = nil;
static NSString *gActiveKeyword = nil;
static NSUInteger gActiveTargetCount = 0;
static NSUInteger gActiveSavedCount = 0;
static BOOL gClaimInFlight = NO;
static BOOL gHeartbeatInFlight = NO;
static NSTimer *gCloudTimer = nil;
static NSTimeInterval gLastHeartbeat = 0;
static NSMutableSet<NSString *> *gUploadingPaths = nil;
static BOOL gUploadBusy = NO;

static NSInteger gAutoCollectState = 0; 
static NSString *gAutoSearchTaskID = nil;
static NSUInteger gAutoPhaseTicks = 0;

static UIWindow *PDDActiveWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

static NSString *PDDDataDirectory(void);
__attribute__((unused)) static void PDDShowMessage(NSString *title, NSString *message);
static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *taskSnapshot);
static NSDictionary *PDDActiveTaskSnapshot(void);
static void PDDStartCloudWorker(void);
static void PDDShowControlMenu(UIButton *button);
__attribute__((unused)) static void PDDConfigureCloud(void);
static void PDDAutoCollectTick(void);
static void PDDAutoScheduleTick(NSTimeInterval delay);
static void PDDCaptureRawJSON(NSData *data, NSString *goodsID);
static BOOL PDDLooksLikeGoodsObject(id object, NSString **goodsIDOut);
static NSString *PDDSafeGoodsID(id value);
static void PDDFlushPendingUploads(void);

// ==========================================
// 4. 随机延迟与坐标抖动
// ==========================================
static NSTimeInterval PDDRandomDelay(CGFloat min, CGFloat max) {
    return min + (max - min) * ((CGFloat)arc4random_uniform(1000) / 1000.0);
}

static CGPoint PDDJitterPoint(CGPoint center) {
    CGFloat range = 15.0; 
    CGFloat dx = ((CGFloat)arc4random_uniform(2000) / 1000.0 - 1.0) * range;
    CGFloat dy = ((CGFloat)arc4random_uniform(2000) / 1000.0 - 1.0) * range;
    return CGPointMake(center.x + dx, center.y + dy);
}

static void PDDSimulateTap(CGPoint basePoint) {
    CGPoint finalPoint = PDDJitterPoint(basePoint);
    UIWindow *window = PDDActiveWindow();
    if (!window) return;

    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:window forKey:@"_window"];
    [touch setValue:@(finalPoint) forKey:@"_locationInWindow"];
    [touch setValue:@(finalPoint) forKey:@"_preciseLocationInWindow"];
    [touch setValue:@(0) forKey:@"_phase"];
    [touch setValue:@(0) forKey:@"_tapCount"];
    [touch setValue:[NSDate date] forKey:@"_timestamp"];
    
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSArray arrayWithObject:touch] forKey:@"_touches"];
    
    [window sendEvent:event];
    PDDDiagEvent(@"simulate_tap", @{@"x": @(finalPoint.x), @"y": @(finalPoint.y)});
}

static BOOL PDDForceInputKeyword(NSString *keyword) {
    UIWindow *window = PDDActiveWindow();
    UITextField *target = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:UITextField.class] && v.isFirstResponder) {
            target = (UITextField *)v; break;
        }
        for (UIView *child in v.subviews) [stack addObject:child];
    }
    if (target) {
        target.text = @"";
        [target sendActionsForControlEvents:UIControlEventEditingChanged];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PDDRandomDelay(0.3, 0.8) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            target.text = keyword;
            [target sendActionsForControlEvents:UIControlEventEditingChanged];
        });
        return YES;
    }
    return NO;
}

// ==========================================
// 5. 状态机
// ==========================================
static void PDDAutoScheduleTick(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.1, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PDDAutoCollectTick();
    });
}

static void PDDAutoCollectTick(void) {
    if (!gEnabled) { gAutoCollectState = 0; return; }
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (!active) { gAutoCollectState = 0; return; }

    NSUInteger target = [active[@"target_count"] unsignedIntegerValue];
    NSUInteger saved = [active[@"saved_count"] unsignedIntegerValue];
    if (target < 1) target = 1;
    if (target > 2) target = 2; 

    if (gAutoCollectState == 0) {
        gAutoSearchTaskID = active[@"task_id"];
        gAutoCollectState = 1;
        PDDAutoScheduleTick(PDDRandomDelay(1.0, 3.0));
        return;
    }
    if (gAutoCollectState == 1) {
        PDDSimulateTap(kSearchBoxPoint);
        gAutoCollectState = 2;
        PDDAutoScheduleTick(PDDRandomDelay(1.0, 2.0)); 
        return;
    }
    if (gAutoCollectState == 2) {
        if (PDDForceInputKeyword(active[@"keyword"])) {
            gAutoCollectState = 3;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PDDRandomDelay(0.8, 1.8) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PDDSimulateTap(kKeyboardSearchPoint);
                PDDAutoScheduleTick(PDDRandomDelay(2.5, 4.5)); 
            });
        } else {
            PDDAutoScheduleTick(PDDRandomDelay(1.0, 2.0));
        }
        return;
    }
    if (gAutoCollectState == 3) {
        gAutoCollectState = 4;
        PDDAutoScheduleTick(PDDRandomDelay(1.0, 2.5)); 
        return;
    }
    if (gAutoCollectState == 4) {
        PDDSimulateTap(kGoods1Point);
        gAutoCollectState = 5;
        PDDAutoScheduleTick(PDDRandomDelay(3.0, 6.0)); 
        return;
    }
    if (gAutoCollectState == 5) {
        if (saved >= 1) {
            gAutoCollectState = 6;
            PDDAutoScheduleTick(PDDRandomDelay(1.5, 3.0)); 
        } else {
            if (++gAutoPhaseTicks > 10) { gAutoCollectState = 6; PDDAutoScheduleTick(1.0); }
            else PDDAutoScheduleTick(1.0); 
        }
        return;
    }
    if (gAutoCollectState == 6) {
        PDDSimulateTap(kBackPoint);
        gAutoCollectState = 7;
        PDDAutoScheduleTick(PDDRandomDelay(2.0, 3.5));
        return;
    }
    if (gAutoCollectState == 7) {
        if (saved < target) {
            PDDSimulateTap(kGoods1Point); 
            gAutoCollectState = 8;
            PDDAutoScheduleTick(PDDRandomDelay(3.0, 6.0));
        } else {
            gAutoCollectState = 0; 
        }
        return;
    }
    if (gAutoCollectState == 8) {
        if (saved >= target) {
            gAutoCollectState = 9;
            PDDAutoScheduleTick(PDDRandomDelay(1.5, 3.0));
        } else {
            if (++gAutoPhaseTicks > 10) { gAutoCollectState = 9; PDDAutoScheduleTick(1.0); }
            else PDDAutoScheduleTick(1.0);
        }
        return;
    }
    if (gAutoCollectState == 9) {
        PDDSimulateTap(kBackPoint);
        gAutoCollectState = 0;
        gAutoPhaseTicks = 0;
        return;
    }
}

// ==========================================
// 6. 工具函数与网络上传
// ==========================================
static BOOL PDDCaptureEnabled(void) { return gEnabled; }

static NSString *PDDSafeGoodsID(id value) {
    if (![value isKindOfClass:NSString.class] && ![value respondsToSelector:@selector(stringValue)]) return nil;
    NSString *raw = [value isKindOfClass:NSString.class] ? (NSString *)value : [value stringValue];
    if (raw.length == 0 || raw.length > 100) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
    if ([raw rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [raw isEqualToString:@"."] || [raw isEqualToString:@".."]) return nil;
    return raw;
}

static BOOL PDDLooksLikeGoodsObject(id object, NSString **goodsIDOut) {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *goods = [root[@"goods"] isKindOfClass:NSDictionary.class] ? root[@"goods"] : nil;
    NSArray *sku = [root[@"sku"] isKindOfClass:NSArray.class] ? root[@"sku"] : nil;
    NSDictionary *price = [root[@"price"] isKindOfClass:NSDictionary.class] ? root[@"price"] : nil;
    NSString *goodsID = PDDSafeGoodsID(goods[@"goods_id"]);
    if (!goods || !sku || !price || !goodsID) return NO;
    if (goodsIDOut) *goodsIDOut = goodsID;
    return YES;
}

static void PDDCaptureRawJSON(NSData *data, NSString *goodsID) {
    if (data.length == 0 || !goodsID.length) return;
    NSDictionary *taskSnapshot = PDDActiveTaskSnapshot();
    NSData *snapshot = [data copy];
    dispatch_async(gCaptureQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = PDDDataDirectory();
        NSError *error = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) return;
        NSString *path = [dir stringByAppendingPathComponent:[goodsID stringByAppendingPathExtension:@"txt"]];
        if (![snapshot writeToFile:path options:NSDataWritingAtomic error:&error]) return;
        @synchronized ([UIApplication class]) { gCaptureCount++; }
        PDDDiagEvent(@"capture.saved", @{@"goods_id": goodsID, @"bytes": @(snapshot.length)});
        PDDQueueCloudUpload(snapshot, goodsID, taskSnapshot);
    });
}

static NSString *PDDDataDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:kDataFolderName];
}

static NSDictionary *PDDActiveTaskSnapshot(void) {
    @synchronized ([UIApplication class]) {
        if (!gActiveTaskID.length) return nil;
        return @{ @"task_id": gActiveTaskID, @"keyword": gActiveKeyword ?: @"",
                  @"target_count": @(gActiveTargetCount), @"saved_count": @(gActiveSavedCount) };
    }
}

static NSString *PDDCloudSetting(NSString *key) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value isKindOfClass:NSString.class] ? [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}
static NSString *PDDCloudServerURL(void) { return PDDCloudSetting(kCloudServerURLKey); }
static NSString *PDDCloudDeviceID(void) { return PDDCloudSetting(kCloudDeviceIDKey); }
static NSString *PDDCloudDeviceToken(void) { return PDDCloudSetting(kCloudDeviceTokenKey); }

static BOOL PDDCloudConfigured(void) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:PDDCloudServerURL()];
    return [[parts.scheme lowercaseString] isEqualToString:@"https"] && parts.host.length > 0 &&
        PDDCloudDeviceID().length >= 8 && PDDCloudDeviceToken().length >= 16;
}

static void PDDCloudRequest(NSString *path, NSDictionary *body, void (^completion)(NSDictionary *result, NSError *error, NSInteger statusCode)) {
    if (!PDDCloudConfigured()) return;
    NSString *base = PDDCloudServerURL();
    NSURL *url = [NSURL URLWithString:[[base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] stringByAppendingString:path]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    request.HTTPMethod = @"POST";
    [request setValue:PDDCloudDeviceID() forHTTPHeaderField:@"X-Device-ID"];
    [request setValue:PDDCloudDeviceToken() forHTTPHeaderField:@"X-Device-Token"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:(body ?: @{}) options:0 error:nil];
    if (!bodyData) return;
    request.HTTPBody = bodyData;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = nil;
        if (data.length) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) json = parsed;
        }
        if (completion) completion(json, error, status);
    }] resume];
}

static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *task) {
    if (!task || !data.length || !goodsID.length) return;
    dispatch_async(gCaptureQueue, ^{
        NSString *dir = [PDDDataDirectory() stringByAppendingPathComponent:@"PendingUploads"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *envelope = [NSMutableDictionary dictionary];
        envelope[@"task_id"] = task[@"task_id"];
        envelope[@"goods_id"] = goodsID;
        envelope[@"captured_at"] = [[NSDate date] description];
        envelope[@"source"] = @"NSJSONSerialization";
        envelope[@"raw_json_base64"] = [data base64EncodedStringWithOptions:0];
        NSData *json = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
        if (!json) return;
        NSString *filename = [NSString stringWithFormat:@"%@-%@.json", task[@"task_id"], NSUUID.UUID.UUIDString];
        NSString *path = [dir stringByAppendingPathComponent:filename];
        if (![json writeToFile:path options:NSDataWritingAtomic error:nil]) return;
        PDDFlushPendingUploads();
    });
}

static void PDDFlushPendingUploads(void) {
    @synchronized ([UIApplication class]) { if (gUploadBusy) return; }
    NSString *dir = [PDDDataDirectory() stringByAppendingPathComponent:@"PendingUploads"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in [files sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        @synchronized ([UIApplication class]) {
            if (gUploadBusy || [gUploadingPaths containsObject:path]) return;
            gUploadBusy = YES;
            [gUploadingPaths addObject:path];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *fileData = [NSData dataWithContentsOfFile:path];
            NSDictionary *envelope = nil;
            if (fileData) {
                id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:NSJSONReadingMutableContainers error:nil];
                if ([parsed isKindOfClass:NSDictionary.class]) envelope = parsed;
            }
            if (![envelope isKindOfClass:NSDictionary.class]) {
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                return;
            }
            PDDCloudRequest(@"/api/v1/device/captures", envelope, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
                BOOL success = !error && statusCode >= 200 && statusCode < 300 && [result[@"ok"] boolValue];
                if (success) {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    NSUInteger saved = [result[@"saved_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [result[@"saved_count"] unsignedIntegerValue] : 0;
                    @synchronized ([UIApplication class]) { gActiveSavedCount = saved; }
                }
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                if (success) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PDDFlushPendingUploads(); });
            });
        });
        return;
    }
}

static void PDDStartCloudWorker(void) {
    if (!PDDCloudConfigured()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCloudTimer) { [gCloudTimer invalidate]; gCloudTimer = nil; }
        gCloudTimer = [NSTimer scheduledTimerWithTimeInterval:kCloudPollInterval target:[PDDActionProxy shared] selector:@selector(cloudTick:) userInfo:nil repeats:YES];
    });
}

// ==========================================
// 7. PDDActionProxy 实现
// ==========================================
@implementation PDDActionProxy
+ (instancetype)shared { static PDDActionProxy *p; static dispatch_once_t once; dispatch_once(&once, ^{ p = [PDDActionProxy new]; }); return p; }
- (void)toggle:(UIButton *)button { PDDShowControlMenu(button); }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    UIWindow *window = PDDActiveWindow();
    if (!view || !window) return;
    CGPoint delta = [gesture translationInView:window];
    CGPoint center = view.center;
    center.x += delta.x; center.y += delta.y;
    CGFloat halfW = CGRectGetWidth(view.bounds) / 2.0, halfH = CGRectGetHeight(view.bounds) / 2.0;
    center.x = MIN(MAX(halfW, center.x), CGRectGetWidth(window.bounds) - halfW);
    center.y = MIN(MAX(halfH, center.y), CGRectGetHeight(window.bounds) - halfH);
    view.center = center;
    [gesture setTranslation:CGPointZero inView:window];
}
- (void)cloudTick:(NSTimer *)timer {
    if (!PDDCloudConfigured()) return;
    NSTimeInterval current = [NSDate date].timeIntervalSince1970;
    if (!gHeartbeatInFlight && (current - gLastHeartbeat >= kCloudHeartbeatInterval)) {
        gHeartbeatInFlight = YES;
        PDDCloudRequest(@"/api/v1/device/heartbeat", @{}, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{ gHeartbeatInFlight = NO; gLastHeartbeat = [NSDate date].timeIntervalSince1970; });
        });
    }
    if (PDDCaptureEnabled() && !gClaimInFlight) {
        gClaimInFlight = YES;
        PDDCloudRequest(@"/api/v1/device/tasks/claim", @{}, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{ gClaimInFlight = NO; });
            if (error || statusCode < 200 || statusCode >= 300) return;
            NSDictionary *task = [result[@"task"] isKindOfClass:NSDictionary.class] ? result[@"task"] : nil;
            if (task) {
                @synchronized ([UIApplication class]) {
                    gActiveTaskID = task[@"task_id"];
                    gActiveKeyword = task[@"keyword"];
                    gActiveTargetCount = [task[@"target_count"] unsignedIntegerValue];
                    gActiveSavedCount = [task[@"saved_count"] unsignedIntegerValue];
                }
                if (gAutoCollectState == 0) PDDAutoScheduleTick(1.0);
            }
        });
    }
    PDDFlushPendingUploads();
}
@end

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id parsed = %orig;
    if (parsed && data.length > 0 && PDDCaptureEnabled()) {
        NSString *goodsID = nil;
        if (PDDLooksLikeGoodsObject(parsed, &goodsID)) {
            PDDCaptureRawJSON(data, goodsID);
        }
    }
    return parsed;
}
%end

static void PDDShowControlMenu(UIButton *button) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        
        NSString *captureState = gEnabled ? @"暫停自動採集" : @"啟用自動採集";
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"PDD Auto" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [menu addAction:[UIAlertAction actionWithTitle:captureState style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            gEnabled = !gEnabled;
            if (gEnabled && gAutoCollectState == 0) PDDAutoScheduleTick(1.0);
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        
        if (menu.popoverPresentationController) {
            menu.popoverPresentationController.sourceView = button ?: presenter.view;
        }
        [presenter presentViewController:menu animated:YES completion:nil];
    });
}

%ctor {
    @autoreleasepool {
        [[PDDDiagnostics shared] start];
        gCaptureQueue = dispatch_queue_create("com.local.pddreplica.capture", DISPATCH_QUEUE_SERIAL);
        gUploadingPaths = [NSMutableSet set];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = PDDActiveWindow();
            if (window) {
                UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
                button.tag = kFloatingButtonTag;
                button.frame = CGRectMake(MAX(8.0, window.bounds.size.width - 92.0), window.safeAreaInsets.top + 180.0, 84.0, 44.0);
                button.backgroundColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.85 alpha:0.92];
                [button setTitle:@"PDD · ON" forState:UIControlStateNormal];
                [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
                button.layer.cornerRadius = 12.0;
                [button addTarget:[PDDActionProxy shared] action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
                
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[PDDActionProxy shared] action:@selector(drag:)];
                [button addGestureRecognizer:pan];
                [window addSubview:button];
            }
            PDDStartCloudWorker();
        });
    }
}
