include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Prefs

Prefs_FILES = APLRootListController.m PasswordViewController.m ../UIAlertController+Fast.m
Prefs_FRAMEWORKS = UIKit
Prefs_PRIVATE_FRAMEWORKS = Preferences
Prefs_INSTALL_PATH = /Library/PreferenceBundles
Prefs_CFLAGS = -fobjc-arc -idirafter ../vendor

include $(THEOS_MAKE_PATH)/bundle.mk
