ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0

THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 22

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VirtualCamera

VirtualCamera_FILES = Tweak.xm
VirtualCamera_FRAMEWORKS = UIKit AVFoundation CoreMedia MediaPlayer ImageIO Photos MobileCoreServices VideoToolbox CoreVideo
VirtualCamera_PRIVATE_FRAMEWORKS = 
VirtualCamera_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"