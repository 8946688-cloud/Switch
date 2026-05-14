DEBUG = 0
FINALPACKAGE = 1

TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Switch
Switch_FILES = Tweak.x DayNightSwitch.m LiquidGlassSwitch.m
Switch_CFLAGS = -fobjc-arc
Switch_FRAMEWORKS = UIKit Metal MetalKit Accelerate MetalPerformanceShaders CoreVideo QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += switchprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
