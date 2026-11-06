TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PDDReplicaShell
PDDReplicaShell_FILES = Tweak.xm
PDDReplicaShell_CFLAGS = -fobjc-arc
PDDReplicaShell_FRAMEWORKS = UIKit Foundation
PDDReplicaShell_LIBRARIES = z
PDDReplicaShell_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Pinduoduo || true"
