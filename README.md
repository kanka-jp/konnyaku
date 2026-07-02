# konnyaku

リアルタイム音声翻訳字幕オーバーレイ (デフォルト 日本語→英語、言語選択可)。ハンズオン発表でプロジェクター / Google Meet の画面共有に翻訳字幕を映すための macOS メニューバーアプリ。

Named after ほんやくコンニャク (honyaku-konnyaku, the translation gadget from Doraemon) — honyaku (translation) → konnyaku.

## 特徴

- **完全オンデバイス**: 音声認識 (SpeechAnalyzer) も翻訳 (Translation framework) も Apple 純正のオンデバイス処理。音声が外部サーバーに出ない
- **2 段字幕**: 話した言語の書き起こしを即時表示し、文が確定し次第、翻訳を追いかけ表示する
- **言語選択**: 入力言語 (音声認識) と出力言語 (翻訳先) をメニューから選択。対応言語は OS から動的に列挙
- **画面全体オーバーレイ**: クリック透過・最前面・全 Space 追従。プロジェクターへのミラー出力にも Meet の画面全体共有にもそのまま映る。ドラッグで位置調整可、文字サイズ 3 段階
- **依存ゼロ**: Swift + Apple フレームワークのみ。UI は日本語 / 英語対応

## 動作要件

- macOS 26.0+ (Apple Silicon)
- マイクへのアクセス許可
- 日本語の音声認識モデルと日本語→英語の翻訳言語モデル (初回にダウンロード)

## インストール

```bash
brew install --cask kanka-jp/tap/konnyaku
```

ad-hoc 署名のため、初回起動時は Gatekeeper にブロックされる。システム設定 → プライバシーとセキュリティ → 「このまま開く」で許可するか、quarantine 属性を外す:

```bash
xattr -dr com.apple.quarantine /Applications/Konnyaku.app
```

zip を直接使う場合は [Releases](https://github.com/kanka-jp/konnyaku/releases) からダウンロードする (同じ Gatekeeper 許可が必要)。

## ビルドと起動

```bash
make run
```

`make app` で `dist/Konnyaku.app` が組み立てられ (ad-hoc 署名)、`make run` はそれを起動する。

## 使い方

1. メニューバーの 💬 アイコン → 「字幕を開始」
2. 初回はマイク許可のプロンプトに応答する。翻訳言語モデルが未インストールの場合は「翻訳モデルのセットアップ…」からダウンロードする
3. 喋ると画面下部に書き起こし (上段) と翻訳 (下段) の字幕が出る
4. 言語は「入力言語 (音声)」「出力言語 (翻訳)」メニューで変更できる (入力と出力が同じ言語なら書き起こしのみ表示)
5. 位置を変えたいときは「オーバーレイを移動 (ドラッグ)」を ON にしてドラッグ → OFF で固定 (位置は記憶される)
6. Google Meet で共有する場合は**ウィンドウ共有ではなく画面全体の共有**を選ぶ (ウィンドウ共有にはオーバーレイが映らない)

## 設定ファイル

設定は `~/.config/konnyaku/` 配下のプレーンテキストで管理される (`XDG_CONFIG_HOME` 尊重):

- `config` — 入力/出力言語・文字サイズ・低遅延翻訳・AI 補正 (`key = value` 形式、行頭 `#` でコメント。インラインコメント非対応)。メニューからの変更もここへ書き戻され、手編集は次回起動時に反映される
- `vocabulary.txt` — カスタム語彙 (1 行 1 語)。音声認識で誤認識されやすい専門用語・固有名詞を書くと認識がバイアスされる

オーバーレイの表示位置はディスプレイ構成依存の状態のため設定ファイルには含まれない。

## 設計

[docs/DESIGN.md](docs/DESIGN.md) 参照。

## License

MIT
