.PHONY: help ios ios-start android android-devices android-start test format lint clean deps pods build-ios build-android devices deploy-ios deploy-android pull-credentials ci

.DEFAULT_GOAL := help

help:
	@echo "Relay Flutter Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make ci              - Run CI checks (format, test, lint)"
	@echo "  make ios             - Run on iOS simulator (iPhone 17)"
	@echo "  make ios-start       - Boot the iOS simulator"
	@echo "  make android         - Run on Android emulator"
	@echo "  make android-devices - List Android emulators"
	@echo "  make android-start   - Boot the Android emulator"
	@echo "  make devices         - List available devices"
	@echo "  make test            - Run all tests"
	@echo "  make format          - Format code"
	@echo "  make lint            - Run static analysis"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make deps            - Get dependencies"
	@echo "  make pods            - Install iOS CocoaPods"
	@echo "  make build-ios       - Build iOS app"
	@echo ""
	@echo "Deployment (requires BUILD_NUMBER):"
	@echo "  make deploy-ios BUILD_NUMBER=999      - Build + upload to TestFlight"
	@echo "  make deploy-android BUILD_NUMBER=999  - Build + upload to Play Store (internal)"
	@echo "  make pull-credentials                - Sync dev certs/profiles via Match"

ci: format test lint

ios:
	flutter run -d "iPhone 17"

android:
	flutter run -d "sdk gphone64 arm64" \
		--dart-define=APP_API_URL=http://10.0.2.2:4000

android-devices:
	@echo "=== Available Android Emulators ==="
	@~/Library/Android/sdk/emulator/emulator -list-avds
	@echo ""
	@echo "=== Currently Running Devices ==="
	@flutter devices

android-start:
	flutter emulators --launch Medium_Phone_API_36

# Point a physical device / simulator at your Mac's LAN IP for the dev server.
# Example: make ios-lan LAN_IP=192.168.86.30
ios-lan:
	flutter run --dart-define=APP_API_URL=http://$(LAN_IP):4000

ios-start:
	flutter emulators --launch apple_ios_simulator

devices:
	flutter devices

test:
	flutter test --no-pub

format:
	dart format .

lint:
	flutter analyze --no-pub

clean:
	flutter clean

deps:
	flutter pub get

pods:
	cd ios && pod install && cd ..

build-ios:
	flutter build ios

build-android:
	flutter build appbundle

# Pull development certs/profiles locally so you can run on a device.
pull-credentials:
	cd ios \
		&& MATCH_TYPE=development fastlane match development \
		&& cd .. \
		&& flutter clean \
		&& rm -rf ~/Library/MobileDevice/Provisioning\ Profiles/

deploy-ios:
	@if [ -z "$(BUILD_NUMBER)" ]; then \
		echo "❌ BUILD_NUMBER is required. Usage: make deploy-ios BUILD_NUMBER=999"; \
		exit 1; \
	fi
	@echo "🚀 Deploying iOS with build number $(BUILD_NUMBER)..."
	cd ios && BUILD_NUMBER=$(BUILD_NUMBER) fastlane deploy

deploy-android:
	@if [ -z "$(BUILD_NUMBER)" ]; then \
		echo "❌ BUILD_NUMBER is required. Usage: make deploy-android BUILD_NUMBER=999"; \
		exit 1; \
	fi
	@echo "🚀 Deploying Android with build number $(BUILD_NUMBER)..."
	cd android && BUILD_NUMBER=$(BUILD_NUMBER) fastlane deploy
