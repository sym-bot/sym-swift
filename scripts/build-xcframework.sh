#!/bin/bash
# Build SYM.xcframework for distribution.
# Bundles SYM + SYMCore into a single framework.
#
# Usage: ./scripts/build-xcframework.sh
# Output: build/SYM.xcframework

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Building SYM.xcframework..."

# Archive for iOS device
echo "  Archiving for iOS..."
xcodebuild archive \
  -scheme SYM \
  -destination "generic/platform=iOS" \
  -archivePath "$BUILD_DIR/SYM-iOS" \
  -derivedDataPath "$BUILD_DIR/derived" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  OTHER_SWIFT_FLAGS="-no-verify-emitted-module-interface" \
  -quiet

# Archive for iOS Simulator
echo "  Archiving for iOS Simulator..."
xcodebuild archive \
  -scheme SYM \
  -destination "generic/platform=iOS Simulator" \
  -archivePath "$BUILD_DIR/SYM-Simulator" \
  -derivedDataPath "$BUILD_DIR/derived" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  OTHER_SWIFT_FLAGS="-no-verify-emitted-module-interface" \
  -quiet

# Find the built frameworks
IOS_FW=$(find "$BUILD_DIR/SYM-iOS.xcarchive" -name "SYM.framework" -type d | head -1)
SIM_FW=$(find "$BUILD_DIR/SYM-Simulator.xcarchive" -name "SYM.framework" -type d | head -1)

if [ -z "$IOS_FW" ] || [ -z "$SIM_FW" ]; then
  echo "  Frameworks not found in archives. Trying static library approach..."

  # SPM builds static libraries — package them as frameworks manually
  IOS_PRODUCTS="$BUILD_DIR/SYM-iOS.xcarchive/Products"
  SIM_PRODUCTS="$BUILD_DIR/SYM-Simulator.xcarchive/Products"

  for PLATFORM_DIR in "$IOS_PRODUCTS" "$SIM_PRODUCTS"; do
    PLATFORM_NAME=$(basename "$(dirname "$PLATFORM_DIR")" .xcarchive)
    FW_DIR="$BUILD_DIR/frameworks/$PLATFORM_NAME/SYM.framework"
    mkdir -p "$FW_DIR/Modules"

    # Find and merge object files
    OBJ_FILES=$(find "$PLATFORM_DIR" -name "*.o" -type f)
    if [ -n "$OBJ_FILES" ]; then
      # Determine arch
      FIRST_OBJ=$(echo "$OBJ_FILES" | head -1)
      ARCH=$(lipo -info "$FIRST_OBJ" 2>/dev/null | awk '{print $NF}')

      # Merge all .o into single static lib
      ar rcs "$FW_DIR/SYM" $OBJ_FILES
    fi

    # Find and copy swiftmodule
    MODULES=$(find "$BUILD_DIR/derived" -path "*/$PLATFORM_NAME*" -name "SYM.swiftmodule" -type d 2>/dev/null | head -1)
    if [ -z "$MODULES" ]; then
      MODULES=$(find "$BUILD_DIR/SYM-${PLATFORM_NAME#SYM-}.xcarchive" -name "SYM.swiftmodule" -type d 2>/dev/null | head -1)
    fi
    if [ -n "$MODULES" ]; then
      cp -R "$MODULES" "$FW_DIR/Modules/"
    fi

    # Copy SYMCore module too
    CORE_MODULES=$(find "$BUILD_DIR/derived" -path "*/$PLATFORM_NAME*" -name "SYMCore.swiftmodule" -type d 2>/dev/null | head -1)
    if [ -n "$CORE_MODULES" ]; then
      cp -R "$CORE_MODULES" "$FW_DIR/Modules/"
    fi

    # Create Info.plist
    cat > "$FW_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SYM</string>
  <key>CFBundleIdentifier</key><string>bot.sym.SYM</string>
  <key>CFBundleVersion</key><string>0.2.0</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
</dict>
</plist>
PLIST
  done

  IOS_FW="$BUILD_DIR/frameworks/SYM-iOS/SYM.framework"
  SIM_FW="$BUILD_DIR/frameworks/SYM-Simulator/SYM.framework"
fi

# Create xcframework
echo "  Creating xcframework..."
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -output "$BUILD_DIR/SYM.xcframework"

echo ""
echo "  ✓ SYM.xcframework built: $BUILD_DIR/SYM.xcframework"
echo "  Size: $(du -sh "$BUILD_DIR/SYM.xcframework" | cut -f1)"
