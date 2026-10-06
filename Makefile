# THEOS_DEVICE_IP = 192.168.1.15

TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = MediaRemoteUI SpringBoard
ARCHS = arm64 arm64e
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LSNowPlayingRepeat

LSNowPlayingRepeat_FILES = Tweak.x
LSNowPlayingRepeat_CFLAGS = -fobjc-arc -Wall
LSNowPlayingRepeat_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
