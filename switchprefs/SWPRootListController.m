#import "SWPRootListController.h"
#import <Preferences/PSSpecifier.h> // <-- 新增了这行导入
#import <spawn.h>

@implementation SWPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 核心互斥逻辑：监听开关改变
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    
    NSString *key = [specifier propertyForKey:@"key"];
    
    if ([value boolValue]) {
        if ([key isEqualToString:@"dayNightEnabled"]) {
            // 开了日夜，强制关液态
            [self setPreferenceValue:@NO specifier:[self specifierForID:@"liquidGlassEnabled"]];
            [self reloadSpecifierID:@"liquidGlassEnabled"];
        } else if ([key isEqualToString:@"liquidGlassEnabled"]) {
            // 开了液态，强制关日夜
            [self setPreferenceValue:@NO specifier:[self specifierForID:@"dayNightEnabled"]];
            [self reloadSpecifierID:@"dayNightEnabled"];
        }
    }
    
    // 通知 Tweak 实时刷新，无需 Respring
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.switch/ReloadPrefs"), NULL, NULL, YES);
}

@end
