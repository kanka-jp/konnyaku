# konnyaku 設計

リアルタイム音声翻訳字幕オーバーレイ (デフォルト 日本語→英語、言語選択可)。ハンズオン発表でプロジェクター / Meet 画面共有に翻訳字幕を映すための macOS メニューバーアプリ。

名前は「ほんやくコンニャク」由来 — honyaku (translation) → konnyaku。

## 要件 (発端の idea エントリより)

- 発表者 (自分) が喋る日本語をマイクから拾い、画面下部に字幕として英訳を表示する
- スライドではなく実際の操作画面を映すため、アプリ内キャプションではなく**画面全体に被さるオーバーレイ**が必要 (プロジェクターへのミラー出力にも Meet の画面全体共有にも同時に映る)
- 社内情報を扱うハンズオンでも使えるよう、音声を外部サーバーに送らない (完全オンデバイス)

## 技術選定

**Swift + Apple 純正フレームワーク、macOS 26+、追加依存ゼロ** を採用する。

| 案 | 判定 | 理由 |
|---|---|---|
| Apple 純正 (SpeechAnalyzer + Translation + NSPanel) | 採用 | 追加依存ゼロ・完全オンデバイス・無料。macOS 26.4+ の `.lowLatency` 翻訳戦略が字幕用途に合う |
| Whisper (MLX) + ローカル LLM 翻訳 | 不採用 | 数 GB のモデル依存 + LLM 常駐前提でレイテンシも劣る。ASR 精度に不満が出た時の差し替え候補 |
| クラウド API (STT + 翻訳) | 不採用 | 音声が外部に出る (要件違反)・従量課金・ネット必須 |
| Electron + Web Speech API | 不採用 | クリック透過・全画面 above 表示が不安定。Web Speech はクラウド処理 |

### SDK 一次確認で確定した API 事実 (Xcode 26.6 / macOS 26 SDK swiftinterface)

- `TranslationSession(installedSource:target:)` は **macOS 26.0+ で SwiftUI 非依存に直接生成できる** (macOS 15 時代の「`translationTask` modifier 必須」は解消済み。Web 上の解説記事の多くは旧仕様)
- `TranslationSession(installedSource:target:preferredStrategy: .lowLatency)` は macOS 26.4+
- 言語モデル未インストールは `LanguageAvailability.status(from:to:)` (`.installed` / `.supported` / `.unsupported`) と `TranslationError.notInstalled` で検出できる。インストール済みでない言語ペアに `installedSource` init を使うと失敗するため、起動時チェック + System Settings への誘導を実装する
- `SpeechTranscriber` (macOS 26.0+) は `ReportingOption.volatileResults` / `.fastResults` で暫定→確定の 2 段階結果を `AsyncSequence` で返す。確定判定は `Result.isFinal`
- 音声認識モデルは `AssetInventory.assetInstallationRequest(supporting:)` でダウンロードできる

## アーキテクチャ

```text
AVAudioEngine (mic tap)
  → AsyncStream<AnalyzerInput>
  → TranscriptionEngine (SpeechAnalyzer + SpeechTranscriber, 選択した入力言語)
       volatile 結果 → 上段: 書き起こしを即時表示 (体感 数百 ms)
                     → 追従訳 worker → 下段: 話し中の追従訳を随時更新 (realtime-translation = false で無効化)
       final 結果   → 翻訳 worker (TranslationSession、選択した出力言語へ)
                       → 下段: 確定訳で追従訳を置き換え (トグル OFF 時はこの確定訳のみ、文確定待ちで 1〜3 秒遅れ)
  → OverlayController (NSPanel: 透過・最前面・クリック透過・全 Space 追従)
MenuBarExtra: Start / Stop / オーバーレイ移動 / 設定 / Quit
Settings window: 言語選択 / 翻訳 (エンジン・リアルタイム翻訳) / 文字サイズ / AI 補正
```

日本語 (即時・暫定) と英語 (追従・確定) の 2 段構成が本アプリの中心的な UX。既定では話し中テキストの追従訳が下段を随時更新し、文確定後に確定訳へ置き換わる (`realtime-translation = false` で文確定待ちのみに切り替え可)。確定訳は文単位でしか得られないため、追従訳と日本語側の即時表示で「字幕が動いている」体感を保つ。

### モジュール構成

| モジュール | 責務 |
|---|---|
| `AudioCaptureEngine` | AVAudioEngine の mic tap、フォーマット変換、`AnalyzerInput` の供給 |
| `TranscriptionEngine` | SpeechAnalyzer + SpeechTranscriber の結線、認識モデルの確保、volatile / final 結果の配送 |
| `TranslationSupport` | TranslationSession の生成、言語ペアの変異形解決 (resolvePair)、可用性チェック (文単位の翻訳 worker は `CaptionPipeline` 内) |
| `CaptionPipeline` | 上記の接続、翻訳 worker、字幕状態 (`CaptionState`) の更新 |
| `OverlayController` / `SubtitleView` | オーバーレイ window (位置記憶・移動モード) と 2 段字幕の描画 |
| `LanguageSettings` / `OverlaySettings` / `ConfigStore` | 言語・表示設定の保持と `~/.config/konnyaku/config` (key = value プレーンテキスト、XDG_CONFIG_HOME 尊重) への永続化。オーバーレイ位置のみディスプレイ構成依存の状態として UserDefaults |
| `WindowCaptureEngine` | 共有可能ウィンドウの列挙 (SCShareableContent) とサムネイル取得、SCStream のキャプチャ開始/停止、フレーム配送、共有元リサイズへの追従 |
| `ShareViewController` | 共有ビュー window の生成、ウィンドウ選択 UI、キャプチャ映像 (AVSampleBufferDisplayLayer) と字幕の合成、共有元消滅時のプレースホルダ |
| `KonnyakuApp` / `SettingsView` / `AppController` | MenuBarExtra、設定ウィンドウ、Start/Stop、権限・モデル未インストール時の誘導 |

### オーバーレイの要件

- `NSPanel` + `.nonactivatingPanel`: フォーカスを奪わない
- `ignoresMouseEvents = true`: クリック透過 (ハンズオン操作の邪魔をしない)
- `level = .statusBar`: 通常ウィンドウ・フルスクリーンより手前
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`: Space 切替・フルスクリーンアプリに追従
- 背景半透明の帯 + 白文字。ミラー出力と画面共有にそのまま映る (特別な処理は不要。Meet では「ウィンドウ共有」でなく「画面全体の共有」を選ぶ運用)

### 共有ビュー (ウィンドウ共有対応)

Meet (Chrome) の「ウィンドウ共有」は ScreenCaptureKit の単一ウィンドウキャプチャで、そのウィンドウの内容だけが配信される。別プロセスのオーバーレイ (NSPanel) は構造的に映らず、他アプリのキャプチャ結果へ外から字幕を注入する API も macOS に存在しない。そこで「相手に見えるピクセルを konnyaku 自身が所有するウィンドウ」を作る:

```text
共有ビュー内のウィンドウ一覧 (SCShareableContent + SCScreenshotManager のサムネイル)
  → SCStream (選択ウィンドウのキャプチャ、30fps 起点)
  → WindowCaptureEngine: CMSampleBuffer を AVSampleBufferVideoRenderer へ配送
  → ShareViewController:
       NSWindow (通常レベル・タイトル付き = Meet の共有リストに出る)
       ├─ AVSampleBufferDisplayLayer   … キャプチャ映像 (aspect-fit、ゼロコピー描画)
       └─ NSHostingView(SubtitleView)  … 字幕 (CaptionState をオーバーレイと共有)
```

Meet ではこの「Konnyaku 共有ビュー」ウィンドウを共有する。発表者は元のアプリをそのまま操作する (SCK のキャプチャは共有元が背面・別 Space でも継続する)。

設計上の判断:

- **共有元の選択は自前一覧 (SCShareableContent) + 画面収録の TCC 許可**: 当初は TCC 不要の SCContentSharingPicker (システム標準ピッカー) を採用したが、常駐キャプチャ (DisplayLink 等) を含む実環境で「共有」の確定操作が機能しないケースが確認された (最小再現アプリ + 正規署名 + Control Center / capture デーモン再起動 + TCC リセットでも再現し、アプリ側で修正不能)。画面収録の許可を初回に一度もらう代わりに、全環境で動作が検証できる自前一覧に切り替えた。選択は「行クリックで選択 → 開始ボタンで確定」の 2 段階 (ウィンドウ前面化のクリックによる誤選択の防止)
- **再帰キャプチャの防止**: 一覧の列挙時に自アプリの bundle ID を除外し、共有ビュー自身を選べなくする
- **共有元リサイズへの追従**: フレーム添付情報 (contentRect / contentScale / scaleFactor) から共有元の native ピクセルサイズを復元し、config と乖離したら `updateConfiguration` で追従する (縦横比の食い違いによる余白と解像度劣化を解消)
- **共有元ウィンドウの消滅**: SCStreamDelegate のエラーで検出し、プレースホルダ + 再選択ボタンを表示する (黒画面のまま配信し続けない)
- **字幕配置 (`subtitle-placement` = overlay / band)**: band は映像の下に字幕専用の黒帯 (高さ = 160 × fontScale) を設け、映像と字幕を非重畳にする。帯の加算定数は `contentAspectRatio` の比率制約で表現できないため、band 中は比率制約を外し `windowWillResize(_:to:)` で「映像部の縦横比 + 帯固定高」を強制する。設定変更は SwiftUI の `onChange` → AppKit レイアウト (映像領域の分割) とウィンドウサイズへ即時反映
- **制約**: 共有元の最小化中はフレームが配信されず映像が止まる (occlusion・別 Space は問題ない)
- **不採用案**: SCContentSharingPicker (上記の実環境問題)、仮想カメラ (System Extension + notarization が ad-hoc 配布と両立しない)、Accessibility API での対象ウィンドウ自動リサイズ (AX 権限 + 他アプリへの副作用が過大)

## 配布形態

SwiftPM executable + `make app` で `.app` bundle を組み立てる (Xcode プロジェクトは使わない)。

- mic の TCC prompt には `.app` bundle + Info.plist (`NSMicrophoneUsageDescription`) + code signing が必要。個人利用なので ad-hoc sign (`codesign --sign -`)
- `LSUIElement = true` で Dock に出さずメニューバー常駐
- `.pbxproj` を持たないことでレビュー可能な diff を保つ

## MVP スコープ

含む:

1. メニューバーから Start / Stop
2. 入力言語 (音声) volatile 結果の上段即時表示
3. final 確定文の翻訳と下段表示 (直近数行)
4. クリック透過・全 Space 追従オーバーレイ
5. 音声認識モデル・翻訳言語モデル未インストール時の検出と誘導 (セットアップウィンドウからダウンロード)
6. 入力言語 / 出力言語の選択 (設定ウィンドウ。SpeechTranscriber.supportedLocales / LanguageAvailability.supportedLanguages から動的列挙、`~/.config/konnyaku/config` へ永続化、実行中の変更はパイプライン自動再起動、入力 == 出力言語なら翻訳 skip で書き起こしのみ)
7. オーバーレイの D&D 位置調整 (メニューの移動トグルでクリック透過と切り替え、位置は記憶して復元)
8. 文字サイズ選択 (小 / 標準 / 大)
9. UI の i18n (en / ja の localized resources)
10. 認識精度の改善: `.fastResults` は維持 (外すと volatile 字幕の初出が数秒遅れライブ字幕が成立しない。確定精度の差 +0.6pp は AI 補正層が吸収)、カスタム語彙 (`AnalysisContext.contextualStrings` + AI 補正プロンプトへ注入、`~/.config/konnyaku/vocabulary.txt` に 1 行 1 語、上限 100 語)
11. AI 補正 (opt-in トグル): 確定文はまず原文を即表示し、オンデバイス LLM (FoundationModels / Apple Intelligence) の校正完了後にまだ表示中なら差し替える (翻訳へは校正後テキストを流す)。`SystemLanguageModel.default.isAvailable` でゲートし、cancel・失敗時は原文 fallback。順序保証のため専用 worker で逐次処理。プロンプト・語尾復元が日本語専用のため日本語入力時のみ有効

含まない (実需要が出てから):

- 一時停止ホットキー
- フォント種・色の設定 UI
- 複数ディスプレイの出力先選択
- 字幕履歴の保存・エクスポート
- lowLatency 翻訳 strategy (デフォルトモデルと別アセットのため、DL 導線を含めて実需要が出てから。実機で lowLatency status = supported 止まりを確認済み)

## テスト方針

中核が OS フレームワークの結線であり、モック化しても実装の写し鏡にしかならないため、unit test は純粋ロジック (字幕状態管理・文の確定処理) に限定する。CI は GitHub Actions `macos-26` runner で `make test` (swift test) と `make app` (release build + bundle 組み立て) を main への push・pull request・手動トリガー (`workflow_dispatch`) で実行する (public リポジトリのため macOS runner は無課金)。`v*` tag の push で release workflow が test → tag からの version 反映 → app bundle の zip 化 → GitHub Release 作成までを行う (配布物は ad-hoc 署名のまま。notarization は Developer ID 取得の実需要が出てから)。音声認識・翻訳・オーバーレイ表示は実機での手動確認 (mic TCC はユーザー操作が必要)。

## References

- [https://developer.apple.com/documentation/speech/speechanalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [https://developer.apple.com/documentation/translation/translationsession](https://developer.apple.com/documentation/translation/translationsession)
- [https://developer.apple.com/videos/play/wwdc2025/277/](https://developer.apple.com/videos/play/wwdc2025/277/) (Bring advanced speech-to-text to your app with SpeechAnalyzer)
- [https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)
