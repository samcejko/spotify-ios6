# Spot6 - unofficial Spotify client for jailbroken iOS 6.x (armv7): its own access point connection, audio
# decryption and Ogg Vorbis decoding, its own TLS stack.
# Built with Theos. Deployment target iOS 6.0, compiled against the iOS 9.3 SDK.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

# Device used by `make install` (Theos) - overridden by tools/ipad.ps1 anyway
THEOS_DEVICE_IP ?= 192.168.137.17
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := Spot6

Spot6_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) $(wildcard src/*/*.c) \
               vendor/mbedtls_glue.c vendor/s6_stb_vorbis.c \
               $(wildcard vendor/mbedtls/library/*.c)

Spot6_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore CoreText Security ImageIO AVFoundation CoreMedia MediaPlayer AudioToolbox

# Flags for every C-family file (also the vendored mbedTLS sources)
Spot6_CFLAGS := -Isrc -Isrc/Net -Isrc/Spotify -Isrc/Audio -Isrc/UI -Isrc/Util \
                -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                -Os -fvisibility=hidden \
                -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-parameter \
                -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than iOS 6.0 are warnings here and turned into errors for our own
# sources by the pragma in src/S6Common.h (vendored code only warns).
Spot6_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Spot6_LDFLAGS := -lz

include $(THEOS)/makefiles/application.mk

# The iOS 9.3 SDK places the NSURL* loading classes in CFNetwork; on iOS 6 they live in Foundation and dyld aborts at
# launch when the binary asks CFNetwork for them. The app avoids those classes, but should the linker still record
# CFNetwork, the load command is pointed at Foundation (harmless when there is none), then the binary is signed again.
Spot6_STAGED_BIN := $(THEOS_STAGING_DIR)/Applications/Spot6.app/Spot6
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(Spot6_STAGED_BIN)" || true
	ldid -S"$(THEOS_PROJECT_DIR)/entitlements.xml" "$(Spot6_STAGED_BIN)"
