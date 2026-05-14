#import "DayNightSwitch.h"
#import "LiquidGlassSwitch.h"
#import <objc/runtime.h>

static NSString *domainString = @"com.iosdump.switch";
static BOOL globalEnabled = YES;
static BOOL dayNightEnabled = YES;
static BOOL liquidGlassEnabled = NO;

static void loadPrefs() {
    CFPreferencesAppSynchronize((CFStringRef)domainString);
    id globalObj = (id)CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)@"enabled", (CFStringRef)domainString));
    if (globalObj) globalEnabled = [globalObj boolValue];
    
    id dnObj = (id)CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)@"dayNightEnabled", (CFStringRef)domainString));
    if (dnObj) dayNightEnabled = [dnObj boolValue];

    id lgObj = (id)CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)@"liquidGlassEnabled", (CFStringRef)domainString));
    if (lgObj) liquidGlassEnabled = [lgObj boolValue];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"SwitchPrefsUpdatedNotification" object:nil];
}

%hook UISwitch

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(switch_forceRefreshUI) name:@"SwitchPrefsUpdatedNotification" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"SwitchPrefsUpdatedNotification" object:nil];
    %orig;
}

%new
- (void)switch_forceRefreshUI {
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)layoutSubviews {
    %orig;

    UIView *visualElement = nil;
    if ([self respondsToSelector:@selector(visualElement)]) {
        visualElement = [self performSelector:@selector(visualElement)];
    }

    DayNightSwitch *dns = objc_getAssociatedObject(self, @selector(dns));
    LiquidGlassSwitch *lgs = objc_getAssociatedObject(self, @selector(lgs));

    // 全局未开启，或全都没选，恢复原生
    if (!globalEnabled || (!dayNightEnabled && !liquidGlassEnabled)) {
        if (visualElement) visualElement.hidden = NO;
        if (dns) dns.hidden = YES;
        if (lgs) lgs.hidden = YES;
        for (UIGestureRecognizer *g in self.gestureRecognizers) g.enabled = YES;
        return;
    }

    // 隐藏系统 UI，并【强制禁用系统原生手势，彻底解决点不动的问题】
    if (visualElement) visualElement.hidden = YES;
    for (UIGestureRecognizer *g in self.gestureRecognizers) {
        g.enabled = NO; 
    }

    // 显示对应的开关
    if (dayNightEnabled) {
        if (lgs) lgs.hidden = YES;
        if (!dns) {
            dns = [[DayNightSwitch alloc] initWithFrame:self.bounds];
            __weak UISwitch *weakSelf = self;
            dns.changeAction = ^(BOOL on) {
                [weakSelf setOn:on animated:YES];
                [weakSelf sendActionsForControlEvents:UIControlEventValueChanged];
            };
            [self addSubview:dns];
            objc_setAssociatedObject(self, @selector(dns), dns, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        dns.hidden = NO;
        dns.frame = self.bounds;
        [dns setOnWithoutAction:self.isOn];
        [self bringSubviewToFront:dns];
        
    } else if (liquidGlassEnabled) {
        if (dns) dns.hidden = YES;
        if (!lgs) {
            lgs = [[LiquidGlassSwitch alloc] initWithFrame:self.bounds];
            __weak UISwitch *weakSelf = self;
            lgs.changeAction = ^(BOOL on) {
                [weakSelf setOn:on animated:YES];
                [weakSelf sendActionsForControlEvents:UIControlEventValueChanged];
            };
            [self addSubview:lgs];
            objc_setAssociatedObject(self, @selector(lgs), lgs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        lgs.hidden = NO;
        lgs.frame = self.bounds;
        [lgs setOnWithoutAction:self.isOn];
        [self bringSubviewToFront:lgs];
    }
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    if (!globalEnabled) return;
    DayNightSwitch *dns = objc_getAssociatedObject(self, @selector(dns));
    if (dns && !dns.hidden && dns.on != on) [dns setOnWithoutAction:on];
    LiquidGlassSwitch *lgs = objc_getAssociatedObject(self, @selector(lgs));
    if (lgs && !lgs.hidden && lgs.on != on) [lgs setOnWithoutAction:on];
}

%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.switch/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    %init;
}
