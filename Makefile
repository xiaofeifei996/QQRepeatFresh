ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQRepeatFresh
QQRepeatFresh_FILES = Repeater.mm
QQRepeatFresh_CFLAGS = -fobjc-arc -O2 -Wall
QQRepeatFresh_FRAMEWORKS = UIKit Foundation CoreFoundation
QQRepeatFresh_LDFLAGS = -undefined dynamic_lookup
QQRepeatFresh_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
