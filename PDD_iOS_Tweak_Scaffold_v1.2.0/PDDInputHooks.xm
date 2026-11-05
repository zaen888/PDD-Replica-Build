#import <UIKit/UIKit.h>
#import "PDDDiagnostics.h"

// 监听 UISearchBar 的标准方法
%hook UISearchBar
- (void)setText:(NSString *)text {
    PDDDiagEvent(@"SB.setText", @{
        @"self": [NSString stringWithFormat:@"%p", self],
        @"before": self.text ?: @"",
        @"new": text ?: @""
    });
    %orig;
}
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    PDDDiagEvent(@"SB.becomeFirstResponder", @{@"result": @(r)});
    return r;
}
%end

// 监听 Delegate 回调是否被触发
%hook NSObject
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if ([self respondsToSelector:@selector(searchBar:textDidChange:)]) {
        PDDDiagEvent(@"DELEGATE.textDidChange", @{@"text": searchText ?: @""});
        %orig;
    }
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    if ([self respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
        PDDDiagEvent(@"DELEGATE.searchButtonClicked", @{@"text": searchBar.text ?: @""});
        %orig;
    }
}
%end

// 保留原有的 UITextField 监听
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
