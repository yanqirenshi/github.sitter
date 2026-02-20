;;; init.el --- github.el パッケージのエントリポイント -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; このファイルが github.el のソースコードルートとなる。
;; Emacs の init.el から (load "~/.emacs.d/dist/github.el/init.el") で読み込む。

;;; Code:

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

;;; init.el ends here
