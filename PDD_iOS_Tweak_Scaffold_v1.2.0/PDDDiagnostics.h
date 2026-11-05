#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PDDDiagnostics : NSObject
+ (instancetype)shared;
- (void)start;
- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1,2);
- (void)event:(NSString *)name fields:(NSDictionary<NSString *, id> *)fields;
- (void)flush;
- (NSURL *)exportLogURL;
- (void)presentExportFromViewController:(UIViewController *)presenter sourceView:(UIView *)sourceView;
@end

#define PDDDiagLog(fmt, ...) [[PDDDiagnostics shared] log:fmt, ##__VA_ARGS__]
#define PDDDiagEvent(name, fields) [[PDDDiagnostics shared] event:name fields:fields]
