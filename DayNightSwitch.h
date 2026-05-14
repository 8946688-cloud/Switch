#import <UIKit/UIKit.h>

@interface DayNightSwitch : UIView

@property (nonatomic, copy, nullable) void (^changeAction)(BOOL);
@property (nonatomic) BOOL on;
@property (nonatomic, nonnull, retain) CAShapeLayer *offBorder;
@property (nonatomic, nonnull, retain) CAShapeLayer *onBorder;
@property (nonatomic, nullable, retain) NSArray<UIView *> *stars;
@property (nonatomic, nonnull, retain) UIImageView *cloud;

- (CGFloat)knobMargin;
- (void)setOnWithoutAction:(BOOL)on;

@end
