#import <UIKit/UIKit.h>

@interface LiquidGlassSwitch : UIView
@property (nonatomic, copy, nullable) void (^changeAction)(BOOL);
@property (nonatomic) BOOL on;
- (void)setOnWithoutAction:(BOOL)on;
@end
