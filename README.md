# github-clone-all.el

GitHub GraphQL API (v4) を使い、自分がオーナーのリポジトリをすべて一括クローンする Emacs パッケージ。

すべての処理は非同期で実行されるため、クローン中も Emacs を通常通り操作できる。

## 必要なもの

- Emacs 25.1 以上
- Git
- GitHub パーソナルアクセストークン (`repo` スコープ)

## ディレクトリ構造

```
github.el/
├── init.el                    # エントリポイント (use-package 設定)
├── src/
│   └── github-clone-all.el    # ソースコード本体
├── README.md
└── CLAUDE.md
```

## インストール

### init.el から読み込む (推奨)

`github.el/init.el` をエントリポイントとして読み込む。

```elisp
;; ~/.emacs.d/init.el に追加
(load "~/.emacs.d/dist/github.el/init.el")
```

`init.el` の中身は以下の use-package 設定:

```elisp
(use-package github-clone-all
  :ensure nil
  :load-path "~/.emacs.d/dist/github.el/src/"
  :commands (github-clone-all
             github-clone-all-list
             github-clone-all-cancel)
  :custom
  (github-clone-all-token (auth-source-pick-first-password :host "api.github.com"))
  (github-clone-all-use-ssh t)
  (github-clone-all-max-parallel 4))
```

- **`:ensure nil`** — ローカルパッケージなので MELPA からのインストールを抑制
- **`:load-path`** — `src/` ディレクトリをパスに追加
- **`:commands`** — 遅延読み込み。コマンド実行時に初めてロードされる
- **`:custom`** — カスタマイズ変数の設定

### require を使う場合

```elisp
(add-to-list 'load-path "~/.emacs.d/dist/github.el/src/")
(require 'github-clone-all)
```

## 設定

### トークン

`~/.authinfo.gpg` (または `~/.authinfo`) に以下の行を追加する:

```
machine api.github.com password ghp_xxxxxxxxxxxx
```

`use-package` の `:custom` で `auth-source-pick-first-password` を使うことで、起動時に自動取得される。

```elisp
(github-clone-all-token (auth-source-pick-first-password :host "api.github.com"))
```

**注意**: トークンをバージョン管理にコミットしないこと。`~/.authinfo.gpg` で GPG 暗号化して管理することを推奨する。

直接設定する場合:

```elisp
(setq github-clone-all-token "ghp_xxxxxxxxxxxx")
```

### SSH / HTTPS の切り替え

```elisp
;; SSH (デフォルト)
(setq github-clone-all-use-ssh t)

;; HTTPS
(setq github-clone-all-use-ssh nil)
```

### 並列数

```elisp
;; 同時に実行する git clone の最大数 (デフォルト: 4)
(setq github-clone-all-max-parallel 4)
```

## 使い方

### 全リポジトリをクローン

```
M-x github-clone-all
```

クローン先ディレクトリを指定すると、自分がオーナーのリポジトリをすべて非同期でクローンする。既にクローン済みのリポジトリはスキップされる。

進捗は `*github-clone-all*` バッファとミニバッファにリアルタイム表示される。

### リポジトリ一覧を確認

```
M-x github-clone-all-list
```

クローンせずにリポジトリ一覧を `*github-repos*` バッファに表示する。アーカイブ済み・フォークにはラベルが付く。

### クローンをキャンセル

```
M-x github-clone-all-cancel
```

実行中のクローン処理をすべて中止する。

## カスタマイズ変数

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `github-clone-all-token` | `nil` | GitHub パーソナルアクセストークン |
| `github-clone-all-use-ssh` | `t` | `t` なら SSH、`nil` なら HTTPS |
| `github-clone-all-max-parallel` | `4` | 同時実行する git clone の最大数 |

## 動作の流れ

1. `url-retrieve` で GraphQL API にリポジトリ一覧を非同期リクエスト (100件ずつページネーション)
2. 全ページ取得完了後、クローンキューを開始
3. `make-process` で git clone を非同期実行 (最大 `github-clone-all-max-parallel` 件並列)
4. 各プロセス完了時に次のリポジトリをキューから取り出して起動
5. 全件完了後、結果サマリー (クローン数 / スキップ数 / 失敗数) を `*github-clone-all*` バッファに表示

## ライセンス

GPL-3.0
