TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = switchprefs

switchprefs_FILES = SWPRootListController.m
switchprefs_FRAMEWORKS = UIKit
switchprefs_PRIVATE_FRAMEWORKS = Preferences
switchprefs_INSTALL_PATH = /Library/PreferenceBundles
switchprefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
