#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <zlib.h>

static NSString * const kDataFolderName = @"PDDGoodsData";
static const NSInteger kFloatingButtonTag = 0x50444452;
static BOOL gEnabled = YES;
static BOOL gPresented = NO;
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

static NSString *PDDDataDirectory(void);
static void PDDShowMessage(NSString *title, NSString *message);
static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *taskSnapshot);
static NSDictionary *PDDActiveTaskSnapshot(void);
static void PDDStartCloudWorker(void);
static void PDDShowControlMenu(UIButton *button);
static void PDDConfigureCloud(void);

static BOOL PDDCaptureEnabled(void) {
    @synchronized ([UIApplication class]) { return gEnabled; }
}

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
    // Bind a capture to the task that was active when the parser returned.
    // This prevents a queued disk write from being attached to a later task.
    NSDictionary *taskSnapshot = PDDActiveTaskSnapshot();
    NSData *snapshot = [data copy];
    dispatch_async(gCaptureQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = PDDDataDirectory();
        NSError *error = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[PDDReplica] create directory failed: %@", error.localizedDescription);
            return;
        }
        NSString *path = [dir stringByAppendingPathComponent:[goodsID stringByAppendingPathExtension:@"txt"]];
        if (![snapshot writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[PDDReplica] write failed for %@: %@", goodsID, error.localizedDescription);
            return;
        }
        @synchronized ([UIApplication class]) { gCaptureCount++; }
        NSLog(@"[PDDReplica] saved product JSON id=%@ bytes=%lu", goodsID, (unsigned long)snapshot.length);
        PDDQueueCloudUpload(snapshot, goodsID, taskSnapshot);
    });
}

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

static NSString *PDDDataDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:kDataFolderName];
}

static NSArray<NSURL *> *PDDTXTFiles(void) {
    NSString *path = PDDDataDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return @[];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
                                         includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       errorHandler:nil];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"txt"]) {
            NSNumber *isRegular = nil;
            [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
            if (isRegular.boolValue) [files addObject:url];
        }
    }
    return files;
}

static void PDDShowMessage(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void PDDAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t b[2] = { (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff) };
    [data appendBytes:b length:sizeof(b)];
}

static void PDDAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t b[4] = { (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff), (uint8_t)((value >> 16) & 0xff), (uint8_t)((value >> 24) & 0xff) };
    [data appendBytes:b length:sizeof(b)];
}

// Minimal ZIP writer using STORE (no compression), compatible with standard ZIP readers.
static NSURL *PDDCreateZIP(NSArray<NSURL *> *files, NSError **outError) {
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSDictionary *> *central = [NSMutableArray array];
    for (NSURL *url in files) {
        NSError *readError = nil;
        NSData *payload = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
        if (!payload) { if (outError) *outError = readError; return nil; }
        NSString *name = url.lastPathComponent ?: @"item.txt";
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        if (nameData.length == 0 || nameData.length > UINT16_MAX || payload.length > UINT32_MAX || zip.length > UINT32_MAX) {
            if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:1 userInfo:@{NSLocalizedDescriptionKey:@"檔名或檔案大小超出 ZIP Store 支援範圍。"}];
            return nil;
        }
        // ZIP names are flattened like the original export; reject collisions rather than silently duplicate entries.
        for (NSDictionary *entry in central) {
            if ([entry[@"name"] isEqualToString:name]) {
                if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"發現重複檔名：%@。請先整理檔案。", name]}];
                return nil;
            }
        }
        uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
        const Bytef *bytes = (const Bytef *)payload.bytes;
        uInt remaining = (uInt)MIN(payload.length, (NSUInteger)UINT_MAX);
        crc = (uint32_t)crc32(crc, bytes, remaining);
        uint32_t localOffset = (uint32_t)zip.length;
        PDDAppendLE32(zip, 0x04034b50); PDDAppendLE16(zip, 20); PDDAppendLE16(zip, 0x0800);
        PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE32(zip, crc); PDDAppendLE32(zip, (uint32_t)payload.length); PDDAppendLE32(zip, (uint32_t)payload.length);
        PDDAppendLE16(zip, (uint16_t)nameData.length); PDDAppendLE16(zip, 0);
        [zip appendData:nameData]; [zip appendData:payload];
        [central addObject:@{@"name":name, @"nameData":nameData, @"crc":@(crc), @"size":@((uint32_t)payload.length), @"offset":@(localOffset)}];
    }
    if (central.count > UINT16_MAX || zip.length > UINT32_MAX) {
        if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:3 userInfo:@{NSLocalizedDescriptionKey:@"檔案數量或 ZIP 大小超出支援範圍。"}];
        return nil;
    }
    uint32_t centralOffset = (uint32_t)zip.length;
    for (NSDictionary *entry in central) {
        NSData *nameData = entry[@"nameData"];
        PDDAppendLE32(zip, 0x02014b50); PDDAppendLE16(zip, 20); PDDAppendLE16(zip, 20);
        PDDAppendLE16(zip, 0x0800); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE32(zip, [entry[@"crc"] unsignedIntValue]);
        PDDAppendLE32(zip, [entry[@"size"] unsignedIntValue]); PDDAppendLE32(zip, [entry[@"size"] unsignedIntValue]);
        PDDAppendLE16(zip, (uint16_t)nameData.length); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE32(zip, 0);
        PDDAppendLE32(zip, [entry[@"offset"] unsignedIntValue]); [zip appendData:nameData];
    }
    uint32_t centralSize = (uint32_t)zip.length - centralOffset;
    PDDAppendLE32(zip, 0x06054b50); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
    PDDAppendLE16(zip, (uint16_t)central.count); PDDAppendLE16(zip, (uint16_t)central.count);
    PDDAppendLE32(zip, centralSize); PDDAppendLE32(zip, centralOffset); PDDAppendLE16(zip, 0);

    NSString *tmp = NSTemporaryDirectory();
    NSString *uniqueName = [NSString stringWithFormat:@"PDDExport-%lu-%@.zip", (unsigned long)files.count, NSUUID.UUID.UUIDString];
    NSString *zipPath = [tmp stringByAppendingPathComponent:uniqueName];
    NSError *writeError = nil;
    if (![zip writeToFile:zipPath options:NSDataWritingAtomic error:&writeError]) { if (outError) *outError = writeError; return nil; }
    return [NSURL fileURLWithPath:zipPath];
}

static void PDDShareTXTFiles(void) {
    // File enumeration, reading, CRC calculation and ZIP construction run off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSURL *> *files = PDDTXTFiles();
        if (files.count == 0) {
            PDDShowMessage(@"PDD Replica", [NSString stringWithFormat:@"No TXT files found in:\n%@", PDDDataDirectory()]);
            return;
        }
        NSError *zipError = nil;
        NSURL *zipURL = PDDCreateZIP(files, &zipError);
        if (!zipURL) {
            PDDShowMessage(@"ZIP 匯出失敗", zipError.localizedDescription ?: @"無法建立 ZIP 檔案。");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = PDDActiveWindow();
            UIViewController *presenter = window.rootViewController;
            if (!presenter) return;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL] applicationActivities:nil];
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                share.popoverPresentationController.sourceView = presenter.view;
                share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
            }
            [presenter presentViewController:share animated:YES completion:nil];
        });
    });
}

@interface PDDActionProxy : NSObject
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)drag:(UIPanGestureRecognizer *)gesture;
- (void)longPress:(UILongPressGestureRecognizer *)gesture;
- (void)cloudTick:(NSTimer *)timer;
@end

// MARK: - Local cloud worker (LAN server)
// This worker only receives tasks and uploads captures. Search/navigation remains a
// separately validated adapter because PDD 6.92.0 UI controls are not identified here.
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

static NSDictionary *PDDActiveTaskSnapshot(void) {
    @synchronized ([UIApplication class]) {
        if (!gActiveTaskID.length) return nil;
        return @{ @"task_id": gActiveTaskID, @"keyword": gActiveKeyword ?: @"",
                  @"target_count": @(gActiveTargetCount), @"saved_count": @(gActiveSavedCount) };
    }
}

static BOOL PDDSetActiveTask(NSDictionary *task, BOOL notify) {
    NSString *taskID = [task[@"task_id"] isKindOfClass:NSString.class] ? task[@"task_id"] : nil;
    NSString *keyword = [task[@"keyword"] isKindOfClass:NSString.class] ? task[@"keyword"] : @"";
    if (!taskID.length) return NO;
    BOOL isNew = NO;
    @synchronized ([UIApplication class]) {
        isNew = ![gActiveTaskID isEqualToString:taskID];
        gActiveTaskID = [taskID copy];
        gActiveKeyword = [keyword copy];
        gActiveTargetCount = [task[@"target_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [task[@"target_count"] unsignedIntegerValue] : 0;
        gActiveSavedCount = [task[@"saved_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [task[@"saved_count"] unsignedIntegerValue] : 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
        if ([button isKindOfClass:UIButton.class]) {
            NSString *title = [NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)gActiveSavedCount, (unsigned long)gActiveTargetCount];
            [button setTitle:title forState:UIControlStateNormal];
        }
        if (notify && isNew) {
            UIPasteboard.generalPasteboard.string = keyword;
            PDDShowMessage(@"收到本地採集任務", [NSString stringWithFormat:@"關鍵詞：%@\n目標商品：%lu\n關鍵詞已複製。請在拼多多中搜尋並逐個打開商品詳情；捕獲到的商品 JSON 會自動上傳。", keyword, (unsigned long)gActiveTargetCount]);
        }
    });
    return isNew;
}

static void PDDClearActiveTask(void) {
    @synchronized ([UIApplication class]) {
        gActiveTaskID = nil; gActiveKeyword = nil; gActiveTargetCount = 0; gActiveSavedCount = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
        if ([button isKindOfClass:UIButton.class]) [button setTitle:(gEnabled ? @"PDD · ON" : @"PDD · OFF") forState:UIControlStateNormal];
    });
}

static void PDDCloudRequest(NSString *path, NSDictionary *body, void (^completion)(NSDictionary *result, NSError *error, NSInteger statusCode)) {
    if (!PDDCloudConfigured()) {
        NSError *e = [NSError errorWithDomain:@"PDDLocalCollector" code:100 userInfo:@{NSLocalizedDescriptionKey:@"尚未設定本地伺服器或設備憑證。"}];
        if (completion) completion(nil, e, 0);
        return;
    }
    NSString *base = PDDCloudServerURL();
    NSURL *url = [NSURL URLWithString:[[base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] stringByAppendingString:path]];
    if (!url) {
        NSError *e = [NSError errorWithDomain:@"PDDLocalCollector" code:101 userInfo:@{NSLocalizedDescriptionKey:@"本地伺服器 URL 無效。"}];
        if (completion) completion(nil, e, 0);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    request.HTTPMethod = @"POST";
    [request setValue:PDDCloudDeviceID() forHTTPHeaderField:@"X-Device-ID"];
    [request setValue:PDDCloudDeviceToken() forHTTPHeaderField:@"X-Device-Token"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:(body ?: @{}) options:0 error:&jsonError];
    if (!bodyData) { if (completion) completion(nil, jsonError, 0); return; }
    request.HTTPBody = bodyData;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = nil;
        if (data.length) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) json = parsed;
        }
        if (completion) completion(json, error, status);
    }];
    [task resume];
}

static NSString *PDDPendingUploadDirectory(void) {
    return [PDDDataDirectory() stringByAppendingPathComponent:@"PendingUploads"];
}

static NSString *PDDFailedUploadDirectory(void) {
    return [PDDDataDirectory() stringByAppendingPathComponent:@"FailedUploads"];
}

static BOOL PDDQuarantinePendingUpload(NSString *path, NSString *reason) {
    if (!path.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = PDDFailedUploadDirectory();
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *name = path.lastPathComponent ?: [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"json"];
    NSString *destination = [dir stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:destination]) {
        destination = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, name]];
    }
    NSError *moveError = nil;
    if ([fm moveItemAtPath:path toPath:destination error:&moveError]) {
        NSString *note = reason.length ? reason : @"上傳遭伺服器拒絕；原始佇列檔已保留在 FailedUploads。";
        [note writeToFile:[destination stringByAppendingString:@".reason.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[PDDReplica] upload quarantined file=%@ reason=%@", destination.lastPathComponent, note);
        return YES;
    }
    NSLog(@"[PDDReplica] could not quarantine upload %@: %@", path, moveError.localizedDescription ?: @"");
    return NO;
}

static void PDDHandleUploadSuccess(NSDictionary *envelope, NSDictionary *response) {
    NSString *taskID = envelope[@"task_id"];
    if (![taskID isKindOfClass:NSString.class]) return;
    BOOL matches = NO;
    @synchronized ([UIApplication class]) { matches = [gActiveTaskID isEqualToString:taskID]; }
    if (!matches) return;
    NSUInteger saved = [response[@"saved_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [response[@"saved_count"] unsignedIntegerValue] : 0;
    BOOL completed = [response[@"task_completed"] boolValue];
    @synchronized ([UIApplication class]) { gActiveSavedCount = saved; }
    if (completed) {
        PDDShowMessage(@"採集任務完成", [NSString stringWithFormat:@"%@\n成功上傳 %lu 件商品。", gActiveKeyword ?: @"", (unsigned long)saved]);
        PDDClearActiveTask();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = PDDActiveWindow(); UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
            if ([button isKindOfClass:UIButton.class]) [button setTitle:[NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)saved, (unsigned long)gActiveTargetCount] forState:UIControlStateNormal];
        });
    }
}

static void PDDDiscardPendingForTask(NSString *taskID) {
    if (!taskID.length) return;
    NSString *dir = PDDPendingUploadDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in files) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
        if ([parsed isKindOfClass:NSDictionary.class] && [parsed[@"task_id"] isEqualToString:taskID]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    }
}

static void PDDFlushPendingUploads(void) {
    @synchronized ([UIApplication class]) { if (gUploadBusy) return; }
    NSString *dir = PDDPendingUploadDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSArray *sorted = [files sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
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
            if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"task_id"] isKindOfClass:NSString.class] ||
                ![envelope[@"goods_id"] isKindOfClass:NSString.class] || ![envelope[@"raw_json_base64"] isKindOfClass:NSString.class]) {
                BOOL moved = PDDQuarantinePendingUpload(path, @"上傳佇列 JSON 格式錯誤；檔案已移至 FailedUploads。");
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                if (moved) PDDFlushPendingUploads();
                return;
            }
            PDDCloudRequest(@"/api/v1/device/captures", envelope, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
                BOOL success = !error && statusCode >= 200 && statusCode < 300 && [result[@"ok"] boolValue];
                BOOL completed = success && [result[@"task_completed"] boolValue];
                if (success) {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    PDDHandleUploadSuccess(envelope, result);
                    NSLog(@"[PDDReplica] cloud upload accepted goods_id=%@ task_id=%@", envelope[@"goods_id"], envelope[@"task_id"]);
                    if (completed) PDDDiscardPendingForTask(envelope[@"task_id"]);
                } else {
                    BOOL retryable = (statusCode == 0 || statusCode >= 500 || statusCode == 408 || statusCode == 425 || statusCode == 429);
                    if (!retryable && statusCode >= 400 && statusCode < 500) {
                        NSString *detail = [result[@"detail"] isKindOfClass:NSString.class] ? result[@"detail"] : @"伺服器拒絕此上傳";
                        PDDQuarantinePendingUpload(path, [NSString stringWithFormat:@"HTTP %ld：%@", (long)statusCode, detail]);
                    }
                    NSLog(@"[PDDReplica] cloud upload %@ goods_id=%@ status=%ld error=%@", retryable ? @"pending" : @"rejected", envelope[@"goods_id"], (long)statusCode, error.localizedDescription ?: @"");
                }
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                if (success && !completed) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PDDFlushPendingUploads(); });
            });
        });
        return; // one in-flight upload keeps task target counting deterministic
    }
}

static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *task) {
    if (!task || !data.length || !goodsID.length) return; // no task: preserve the original local-only capture behavior
    dispatch_async(gCaptureQueue, ^{
        NSString *dir = PDDPendingUploadDirectory();
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

static void PDDCloudTick(void) {
    if (!PDDCloudConfigured()) return;
    NSTimeInterval current = [NSDate date].timeIntervalSince1970;
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (!gHeartbeatInFlight && (current - gLastHeartbeat >= kCloudHeartbeatInterval)) {
        gHeartbeatInFlight = YES;
        NSString *activeID = active[@"task_id"] ?: @"";
        NSDictionary *body = @{ @"app_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
                                 @"plugin_version": @"1.1.0", @"app_active": @YES, @"active_task_id": activeID };
        PDDCloudRequest(@"/api/v1/device/heartbeat", body, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gHeartbeatInFlight = NO;
                gLastHeartbeat = [NSDate date].timeIntervalSince1970;
            });
            if (error || statusCode < 200 || statusCode >= 300) NSLog(@"[PDDReplica] heartbeat failed status=%ld %@", (long)statusCode, error.localizedDescription ?: @"");
        });
    }
    if (PDDCaptureEnabled() && !gClaimInFlight) {
        gClaimInFlight = YES;
        PDDCloudRequest(@"/api/v1/device/tasks/claim", @{}, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{ gClaimInFlight = NO; });
            if (error || statusCode < 200 || statusCode >= 300) {
                NSLog(@"[PDDReplica] task claim failed status=%ld %@", (long)statusCode, error.localizedDescription ?: @"");
                return;
            }
            if ([result[@"paused"] boolValue]) return;
            NSDictionary *task = [result[@"task"] isKindOfClass:NSDictionary.class] ? result[@"task"] : nil;
            if (task) {
                BOOL isNewTask = PDDSetActiveTask(task, YES);
                if (isNewTask) {
                    NSString *taskID = task[@"task_id"];
                    PDDCloudRequest([NSString stringWithFormat:@"/api/v1/device/tasks/%@/start", taskID], @{}, ^(NSDictionary *r, NSError *e, NSInteger code) {
                        if (e || code < 200 || code >= 300) NSLog(@"[PDDReplica] task start failed task=%@ status=%ld", taskID, (long)code);
                    });
                }
            } else if (PDDActiveTaskSnapshot()) {
                PDDClearActiveTask(); // server-side task was stopped or lease was released
            }
        });
    }
    PDDFlushPendingUploads();
}

static void PDDStartCloudWorker(void) {
    if (!PDDCloudConfigured()) {
        NSLog(@"[PDDReplica] local cloud connection is not configured; open the floating-button menu to set it.");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCloudTimer) { [gCloudTimer invalidate]; gCloudTimer = nil; }
        gCloudTimer = [NSTimer scheduledTimerWithTimeInterval:kCloudPollInterval target:[PDDActionProxy shared] selector:@selector(cloudTick:) userInfo:nil repeats:YES];
        PDDCloudTick();
    });
}

static void PDDToggle(UIButton *button) {
    @synchronized ([UIApplication class]) { gEnabled = !gEnabled; }
    [NSUserDefaults.standardUserDefaults setBool:gEnabled forKey:kEnabledDefaultsKey];
    NSDictionary *active = PDDActiveTaskSnapshot();
    NSString *state = active ? [NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)gActiveSavedCount, (unsigned long)gActiveTargetCount] : (gEnabled ? @"PDD · ON" : @"PDD · OFF");
    [button setTitle:state forState:UIControlStateNormal];
    PDDShowMessage(@"PDD Replica", gEnabled ? @"商品 JSON 擷取已啟用。" : @"商品 JSON 擷取已停用；設備心跳仍會維持連線。" );
}

static void PDDConfigureCloud(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"設定本地採集服務" message:@"請填入 Windows 本地伺服器 HTTPS 網址、設備 ID 與設備 Token。憑證只存在這台 iPhone 的拼多多 App 偏好設定，不會寫入 GitHub 源碼。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"https://192.168.x.x:8443";
            field.text = PDDCloudServerURL();
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"Device ID";
            field.text = PDDCloudDeviceID();
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"Device Token";
            field.text = PDDCloudDeviceToken();
            field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"儲存並連線" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSArray<UITextField *> *fields = alert.textFields;
            NSString *url = [fields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *deviceID = [fields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *token = [fields[2].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURLComponents *parts = [NSURLComponents componentsWithString:url];
            if (![[parts.scheme lowercaseString] isEqualToString:@"https"] || parts.host.length == 0 || deviceID.length < 8 || token.length < 16) {
                PDDShowMessage(@"設定無效", @"請確認網址以 https:// 開頭，且設備 ID、Token 都完整。可從 Windows 專案中的 ios/PDDLocalConfig.h 查看。" );
                return;
            }
            [NSUserDefaults.standardUserDefaults setObject:[url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] forKey:kCloudServerURLKey];
            [NSUserDefaults.standardUserDefaults setObject:deviceID forKey:kCloudDeviceIDKey];
            [NSUserDefaults.standardUserDefaults setObject:token forKey:kCloudDeviceTokenKey];
            PDDStartCloudWorker();
            PDDShowMessage(@"設定已儲存", @"本地服務設定已儲存。插件會開始發送心跳並領取任務；請在 Windows 管理頁建立任務。" );
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void PDDShowControlMenu(UIButton *button) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        NSString *captureState = gEnabled ? @"暫停 JSON 擷取" : @"啟用 JSON 擷取";
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"PDD Local Collector" message:(PDDCloudConfigured() ? @"本地服務已設定" : @"尚未設定本地服務") preferredStyle:UIAlertControllerStyleActionSheet];
        [menu addAction:[UIAlertAction actionWithTitle:captureState style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDToggle(button); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"設定本地服務" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDConfigureCloud(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"匯出 TXT ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDShareTXTFiles(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        if (menu.popoverPresentationController) {
            menu.popoverPresentationController.sourceView = button ?: presenter.view;
            menu.popoverPresentationController.sourceRect = button ? button.bounds : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:menu animated:YES completion:nil];
    });
}

static void PDDLongPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    PDDShareTXTFiles();
}

static void PDDInstallFloatingButton(void) {
    if (gPresented) return;
    UIWindow *window = PDDActiveWindow();
    if (!window) return;
    UIView *existing = [window viewWithTag:kFloatingButtonTag];
    if (existing) { gPresented = YES; return; }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = kFloatingButtonTag;
    button.frame = CGRectMake(MAX(8.0, window.bounds.size.width - 92.0), window.safeAreaInsets.top + 180.0, 84.0, 44.0);
    button.backgroundColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.85 alpha:0.92];
    [button setTitle:(gEnabled ? @"PDD · ON" : @"PDD · OFF") forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    button.layer.cornerRadius = 12.0;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 4.0;
    [button addTarget:[PDDActionProxy shared] action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[PDDActionProxy shared] action:@selector(drag:)];
    pan.cancelsTouchesInView = NO;
    [button addGestureRecognizer:pan];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[PDDActionProxy shared] action:@selector(longPress:)];
    longPress.minimumPressDuration = 0.7;
    longPress.cancelsTouchesInView = NO;
    [button addGestureRecognizer:longPress];
    [window addSubview:button];
    gPresented = YES;
}

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
- (void)longPress:(UILongPressGestureRecognizer *)gesture { PDDLongPress(gesture); }
- (void)cloudTick:(NSTimer *)timer { PDDCloudTick(); }
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

%ctor {
    @autoreleasepool {
        gEnabled = [NSUserDefaults.standardUserDefaults objectForKey:kEnabledDefaultsKey] ? [NSUserDefaults.standardUserDefaults boolForKey:kEnabledDefaultsKey] : YES;
        gCaptureQueue = dispatch_queue_create("com.local.pddreplica.capture", DISPATCH_QUEUE_SERIAL);
        gUploadingPaths = [NSMutableSet set];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PDDInstallFloatingButton();
            PDDStartCloudWorker();
            // Timers run only while the Pinduoduo app is active; iOS may suspend the process in background.
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                gPresented = NO;
                PDDInstallFloatingButton();
                PDDStartCloudWorker();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (gCloudTimer) { [gCloudTimer invalidate]; gCloudTimer = nil; }
            }];
        });
    }
}
