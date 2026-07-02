APP_NAME := Konnyaku
BUILD_DIR := .build/release
APP_BUNDLE := dist/$(APP_NAME).app

.PHONY: build app run clean test

build:
	swift build -c release

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp -R Resources/en.lproj Resources/ja.lproj $(APP_BUNDLE)/Contents/Resources/
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp -R $(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle $(APP_BUNDLE)/Contents/Resources/
	codesign --force --sign - $(APP_BUNDLE)

run: app
	open $(APP_BUNDLE)

test:
	swift test

clean:
	rm -rf .build dist
