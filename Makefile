APP_NAME := Konnyaku
BUILD_DIR := .build/release
APP_BUNDLE := dist/$(APP_NAME).app

.PHONY: build app run clean test eval

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

# ローカル専用の定量評価 (Speech / Translation / Apple Intelligence モデル要)。
# CI では実行しない (docs/DESIGN.md「定量評価ハーネス」参照)
eval:
	KONNYAKU_EVAL=1 swift test --filter 'TranscriptionEvaluation|SegmentationEvaluation'

clean:
	rm -rf .build dist
