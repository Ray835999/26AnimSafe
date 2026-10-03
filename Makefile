TARGET := iphone:clang:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless
TWEAK_NAME = 26AnimSafe

26AnimSafe_FILES = Tweak.xm
26AnimSafe_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# The filter plist below injects only into SpringBoard (same as the original 26Anim).
# Place it at layout/Library/MobileSubstrate/DynamicLibraries/26AnimSafe.plist
after-install::
	@echo "respring SpringBoard to apply"
