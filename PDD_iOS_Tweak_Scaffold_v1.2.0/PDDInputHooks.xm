#import <UIKit/UIKit.h>
#import "PDDDiagnostics.h"

%hook UITextField
- (void)setText:(NSString *)text {
    PDDDiagEvent(@"TF.setText", @{
        @"self": [NSString stringWithFormat:@"%p", self],
        @"before": self.text ?: @"",
        @"new": text ?: @"",
        @"firstResp": @(self.isFirstResponder)
    });
    %orig;
}
- (void)insertText:(NSString *)text {
    PDDDiagEvent(@"TF.insertText", @{
        @"self": [NSString stringWithFormat:@"%p", self],
        @"insert": text ?: @"",
        @"firstResp": @(self.isFirstResponder)
    });
    %orig;
}
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    PDDDiagEvent(@"TF.becomeFirstResponder", @{
        @"self": [NSString stringWithFormat:@"%p", self],
        @"result": @(r)
    });
    return r;
}
%end

%hook UITextView
- (void)setText:(NSString *)text {
    PDDDiagEvent(@"TV.setText", @{
        @"self": [NSString stringWithFormat:@"%p", self],
        @"before": self.text ?: @"",
        @"new": text ?: @""
    });
    %orig;
}
%end
