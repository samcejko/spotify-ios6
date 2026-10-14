#!/usr/bin/env python3
"""Turns the staged app bundle into the arm64 one for iOS 14-17 (make package THEOS_PACKAGE_SCHEME=rootless).

The Makefile's after-stage runs it; the Info.plist in Resources stays the iOS 6 one. It raises MinimumOSVersion,
requires arm64 instead of armv7, replaces the iOS 6 launch images (Default*.png) with a launch screen the system
draws itself (UILaunchScreen: the app icon on a plain background, so that the app runs full screen on every
notched iPhone) and drops the keys iOS 14 and newer would misread.

Usage: python3 tools/modern_bundle.py <staged .app> [minimum iOS version, default 14.0]
"""
import os
import plistlib
import sys

app = sys.argv[1]
minimum = sys.argv[2] if len(sys.argv) > 2 else "14.0"
path = os.path.join(app, "Info.plist")
with open(path, "rb") as f:
    info = plistlib.load(f)

info["MinimumOSVersion"] = minimum
info["UIRequiredDeviceCapabilities"] = ["arm64"]
for key in ("UILaunchImages", "UILaunchImageFile", "UILaunchImageFile~iphone", "UILaunchImageFile~ipad"):
    info.pop(key, None)

launch = {}
if os.path.exists(os.path.join(app, "LaunchLogo.png")) or os.path.exists(os.path.join(app, "LaunchLogo@2x.png")):
    launch = {"UIImageName": "LaunchLogo", "UIImageRespectsSafeAreaInsets": True}
info["UILaunchScreen"] = launch

# light mode only (the app has its own themes), no iPad split view
info.setdefault("UIUserInterfaceStyle", "Light")
info.setdefault("UIRequiresFullScreen", True)

with open(path, "wb") as f:
    plistlib.dump(info, f, sort_keys=False)

removed = 0
for name in sorted(os.listdir(app)):
    if name.startswith("Default") and name.endswith(".png"):
        os.remove(os.path.join(app, name))
        removed += 1

print("modern_bundle: %s is now iOS %s+ arm64 (UILaunchScreen%s, %d iOS 6 launch images removed)"
      % (os.path.basename(app), minimum, " with LaunchLogo" if launch else "", removed))
