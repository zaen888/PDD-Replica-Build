ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = PDDReplicaShell
PDDReplicaShell_FILES = Tweak.xm
PDDReplicaShell_CFLAGS = -fobjc-arc
PDDReplicaShell_FRAMEWORKS = UIKit Foundation
PDDReplicaShell_LIBRARIES = z
PDDReplicaShell_PRIVATE_FRAMEWORKS =

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
