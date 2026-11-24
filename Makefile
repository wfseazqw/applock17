export ARCHS = arm64e
export TARGET := iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppLock

AppLock_FILES = Tweak.x AppLockAppGuard.x PasswordManager.m UIAlertController+Fast.m
AppLock_FRAMEWORKS = UIKit LocalAuthentication
AppLock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -idirafter $(THEOS_PROJECT_DIR)/vendor

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
