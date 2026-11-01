#!/bin/sh
# Build the newest JawnOS Android app into a QA run directory.
#
#   perl scripts/app_build.pl   <- a RELEASE: bumps versionCode and stages it
#   qa/android/build.sh         <- this: whatever the app repo's HEAD is, no bump,
#                                  no copy into releases/
#
# Every QA run builds again, so a stale staged APK can never pass as the current
# tree. The output path is printed on stdout.

set -eu

OUT=${1:-${QA_ROOT:-$HOME/jawnos-qa}/android}
APP=${JAWNOS_APP_DIR:-$HOME/jawnos-app/termux-app}

if [ ! -d "$APP" ]; then
	echo "qa-android: no app repo at $APP (set JAWNOS_APP_DIR)" >&2
	exit 2
fi
if [ ! -x "$APP/gradlew" ]; then
	echo "qa-android: $APP/gradlew is missing or not executable" >&2
	exit 2
fi

# gradle needs the SDK location; local.properties is gitignored and the app
# repo's own release script writes the same line.
if [ ! -f "$APP/local.properties" ]; then
	SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}
	if [ ! -d "$SDK" ]; then
		echo "qa-android: no Android SDK at $SDK (set ANDROID_SDK_ROOT)" >&2
		exit 2
	fi
	printf 'sdk.dir=%s\n' "$SDK" > "$APP/local.properties"
fi

mkdir -p "$OUT"
cd "$APP"

# AGP 8.7 / Gradle 8.9 support JDK 17-21. A machine whose only java is 26
# fails in JdkImageTransform (jlink), before a single source file is compiled.
# Prefer a supported JDK when one is installed; an explicit JAVA_HOME wins.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
	for d in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-21-openjdk \
		/usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-21-openjdk-amd64; do
		if [ -x "$d/bin/java" ]; then
			JAVA_HOME=$d
			export JAVA_HOME
			break
		fi
	done
fi

# cap the jobs: this box is shared with the live house
./gradlew --max-workers=4 :app:assembleDebug

APK=$(ls -t app/build/outputs/apk/debug/*.apk 2>/dev/null | head -n 1 || true)
if [ -z "$APK" ] || [ ! -s "$APK" ]; then
	echo "qa-android: gradle produced no debug APK" >&2
	exit 1
fi

REV=$(git -C "$APP" rev-parse --short HEAD 2>/dev/null || echo unknown)
DEST="$OUT/jawnos-qa-$REV.apk"
cp -f "$APK" "$DEST"
echo "$DEST"
