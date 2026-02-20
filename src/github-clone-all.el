;;; github-clone-all.el --- GitHub API v4 で自分のリポジトリをすべて clone -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; GitHub GraphQL API (v4) を使い、認証ユーザーがオーナーのリポジトリを
;; すべて取得し、指定ディレクトリに git clone する。
;;
;; すべての処理は非同期で実行されるため、Emacs をブロックしない。
;;
;; 使い方:
;;   1. `github-clone-all-token' にパーソナルアクセストークンを設定する
;;   2. M-x github-clone-all を実行し、クローン先ディレクトリを指定する
;;
;; トークンには `repo' スコープが必要。

;;; Code:

(require 'url)
(require 'json)
(require 'cl-lib)

(defgroup github-clone-all nil
  "GitHub API v4 で自分のリポジトリをすべて clone する。"
  :group 'tools)

(defcustom github-clone-all-token nil
  "GitHub パーソナルアクセストークン。
`repo' スコープが必要。"
  :type '(choice (const nil) string)
  :group 'github-clone-all)

(defcustom github-clone-all-use-ssh t
  "non-nil なら SSH URL でクローンする。nil なら HTTPS URL を使う。"
  :type 'boolean
  :group 'github-clone-all)

(defcustom github-clone-all-max-parallel 4
  "同時に実行する git clone プロセスの最大数。"
  :type 'integer
  :group 'github-clone-all)

(defconst github-clone-all--graphql-query
  "query($cursor: String) {
  viewer {
    repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER], orderBy: {field: NAME, direction: ASC}) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        name
        sshUrl
        url
        isArchived
        isFork
      }
    }
  }
}"
  "リポジトリ一覧を取得する GraphQL クエリ。")

;;; ============================================================
;;; 進捗管理用の状態
;;; ============================================================

(cl-defstruct (github-clone-all--state (:constructor github-clone-all--state-create))
  "クローン処理全体の状態を保持する構造体。"
  (target-dir nil)          ; クローン先ディレクトリ
  (repos nil)               ; クローン対象リポジトリのリスト
  (pending nil)             ; 未処理のリポジトリキュー
  (active 0)                ; 現在実行中のプロセス数
  (results nil)             ; (name . status) のリスト
  (total 0))                ; リポジトリ総数

(defvar github-clone-all--current-state nil
  "現在実行中のクローン処理の状態。")

;;; ============================================================
;;; ログバッファ
;;; ============================================================

(defun github-clone-all--log (format-string &rest args)
  "FORMAT-STRING と ARGS でメッセージをログバッファとミニバッファに出力する。"
  (let ((msg (apply #'format format-string args)))
    (message "%s" msg)
    (with-current-buffer (get-buffer-create "*github-clone-all*")
      (goto-char (point-max))
      (insert msg "\n"))))

;;; ============================================================
;;; 非同期 GraphQL リクエスト
;;; ============================================================

(defun github-clone-all--ensure-token ()
  "トークンが設定されていることを確認する。"
  (unless github-clone-all-token
    (error "`github-clone-all-token' が設定されていません。GitHub パーソナルアクセストークンを設定してください")))

(defun github-clone-all--parse-response (buffer)
  "BUFFER から HTTP レスポンスをパースし JSON を返す。エラー時は signal する。"
  (with-current-buffer buffer
    (goto-char (point-min))
    (re-search-forward "\n\n" nil t)
    (let* ((response (json-read))
           (errors (alist-get 'errors response)))
      (when errors
        (error "GitHub API エラー: %s"
               (mapconcat (lambda (e) (alist-get 'message e))
                          errors ", ")))
      response)))

(defun github-clone-all--graphql-request-async (query variables callback)
  "GitHub GraphQL API に非同期リクエストを送り、結果を CALLBACK に渡す。
QUERY は GraphQL クエリ文字列、VARIABLES は変数の alist。
CALLBACK は (lambda (response) ...) の形式。"
  (github-clone-all--ensure-token)
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "bearer " github-clone-all-token))
            ("Content-Type" . "application/json")))
         (payload (json-encode `((query . ,query)
                                 (variables . ,(or variables :null)))))
         (url-request-data (encode-coding-string payload 'utf-8)))
    (url-retrieve
     "https://api.github.com/graphql"
     (lambda (status cb)
       (if (plist-get status :error)
           (progn
             (github-clone-all--log "API リクエスト失敗: %s"
                                    (plist-get status :error))
             (kill-buffer (current-buffer)))
         (let ((response (github-clone-all--parse-response (current-buffer))))
           (kill-buffer (current-buffer))
           (funcall cb response))))
     (list callback)
     t t)))

;;; ============================================================
;;; 非同期ページネーション: 全リポジトリ取得
;;; ============================================================

(defun github-clone-all--fetch-all-repos-async (callback)
  "ページネーションしながらすべてのリポジトリを非同期取得する。
完了時に CALLBACK を (lambda (repos) ...) の形式で呼ぶ。"
  (github-clone-all--fetch-page-async nil '() callback))

(defun github-clone-all--fetch-page-async (cursor acc callback)
  "CURSOR から1ページ取得し、ACC に蓄積して次ページがあれば再帰する。
全ページ取得完了時に CALLBACK を呼ぶ。"
  (let ((variables (if cursor `((cursor . ,cursor)) nil)))
    (github-clone-all--graphql-request-async
     github-clone-all--graphql-query
     variables
     (lambda (response)
       (let* ((data (alist-get 'viewer (alist-get 'data response)))
              (repos-data (alist-get 'repositories data))
              (page-info (alist-get 'pageInfo repos-data))
              (nodes (alist-get 'nodes repos-data))
              (new-acc (append acc (append nodes nil)))
              (has-next (eq (alist-get 'hasNextPage page-info) t))
              (end-cursor (alist-get 'endCursor page-info)))
         (github-clone-all--log "リポジトリ取得中... %d 件" (length new-acc))
         (if has-next
             ;; 次のページを取得
             (github-clone-all--fetch-page-async end-cursor new-acc callback)
           ;; 全ページ取得完了
           (funcall callback new-acc)))))))

;;; ============================================================
;;; 非同期 git clone (並列数制限付き)
;;; ============================================================

(defun github-clone-all--start-clone-queue (state)
  "STATE のキューからプロセスを起動する。最大並列数まで同時実行する。"
  (while (and (github-clone-all--state-pending state)
              (< (github-clone-all--state-active state)
                 github-clone-all-max-parallel))
    (let ((repo (pop (github-clone-all--state-pending state))))
      (github-clone-all--clone-repo-async repo state))))

(defun github-clone-all--clone-repo-async (repo state)
  "REPO を非同期でクローンし、完了時に STATE を更新する。"
  (let* ((name (alist-get 'name repo))
         (clone-url (if github-clone-all-use-ssh
                        (alist-get 'sshUrl repo)
                      (alist-get 'url repo)))
         (target-dir (github-clone-all--state-target-dir state))
         (dest (expand-file-name name target-dir)))
    (cond
     ;; 既にクローン済み
     ((file-directory-p (expand-file-name ".git" dest))
      (github-clone-all--log "  スキップ: %s (既にクローン済み)" name)
      (push (cons name :skipped) (github-clone-all--state-results state))
      ;; スキップの場合はプロセスを起動しないので、キューの次を処理
      (github-clone-all--maybe-finish state))

     ;; 非同期で git clone を実行
     (t
      (github-clone-all--log "  クローン中: %s" name)
      (cl-incf (github-clone-all--state-active state))
      (let ((proc (make-process
                   :name (format "git-clone-%s" name)
                   :command (list "git" "clone" clone-url dest)
                   :sentinel
                   (lambda (process event)
                     (let ((repo-name name)
                           (st state))
                       (cl-decf (github-clone-all--state-active st))
                       (cond
                        ((string-match-p "finished" event)
                         (github-clone-all--log "  完了: %s" repo-name)
                         (push (cons repo-name :cloned)
                               (github-clone-all--state-results st)))
                        (t
                         (github-clone-all--log "  失敗: %s (%s)"
                                                repo-name
                                                (string-trim event))
                         (push (cons repo-name :failed)
                               (github-clone-all--state-results st))))
                       (github-clone-all--maybe-finish st))))))
        proc)))))

(defun github-clone-all--maybe-finish (state)
  "完了チェック: 全リポジトリ処理済みならサマリーを表示、そうでなければキューを進める。"
  (let ((done (length (github-clone-all--state-results state)))
        (total (github-clone-all--state-total state)))
    (if (>= done total)
        ;; 全件完了
        (github-clone-all--show-summary state)
      ;; まだ残りがある場合、キューから次を起動
      (github-clone-all--start-clone-queue state))))

(defun github-clone-all--show-summary (state)
  "STATE の結果からサマリーをログバッファに表示する。"
  (let* ((results (github-clone-all--state-results state))
         (total (github-clone-all--state-total state))
         (cloned (cl-count :cloned results :key #'cdr))
         (skipped (cl-count :skipped results :key #'cdr))
         (failed (cl-count :failed results :key #'cdr)))
    (github-clone-all--log
     "\n完了! クローン: %d / スキップ: %d / 失敗: %d (合計: %d)"
     cloned skipped failed total)
    (when (> failed 0)
      (github-clone-all--log "\nクローンに失敗したリポジトリ:")
      (dolist (r results)
        (when (eq (cdr r) :failed)
          (github-clone-all--log "  - %s" (car r)))))
    (display-buffer (get-buffer "*github-clone-all*"))
    (setq github-clone-all--current-state nil)))

;;; ============================================================
;;; インタラクティブコマンド
;;; ============================================================

;;;###autoload
(defun github-clone-all (target-dir)
  "自分がオーナーのリポジトリをすべて TARGET-DIR に非同期クローンする。"
  (interactive "Dクローン先ディレクトリ: ")
  (when github-clone-all--current-state
    (error "既にクローン処理が実行中です。完了をお待ちください"))
  (github-clone-all--ensure-token)
  ;; ログバッファを初期化
  (with-current-buffer (get-buffer-create "*github-clone-all*")
    (erase-buffer))
  (github-clone-all--log "GitHub からリポジトリ一覧を取得中...")
  (github-clone-all--fetch-all-repos-async
   (lambda (repos)
     (let* ((total (length repos))
            (state (github-clone-all--state-create
                    :target-dir (expand-file-name target-dir)
                    :repos repos
                    :pending (append repos nil)
                    :active 0
                    :results '()
                    :total total)))
       (setq github-clone-all--current-state state)
       (github-clone-all--log
        "%d 件のリポジトリが見つかりました。クローンを開始します..." total)
       (github-clone-all--start-clone-queue state)))))

;;;###autoload
(defun github-clone-all-list ()
  "自分がオーナーのリポジトリ一覧を非同期で取得して表示する (クローンはしない)。"
  (interactive)
  (github-clone-all--ensure-token)
  (github-clone-all--log "GitHub からリポジトリ一覧を取得中...")
  (github-clone-all--fetch-all-repos-async
   (lambda (repos)
     (with-current-buffer (get-buffer-create "*github-repos*")
       (erase-buffer)
       (insert (format "自分がオーナーのリポジトリ (%d 件):\n\n" (length repos)))
       (dolist (repo repos)
         (let ((name (alist-get 'name repo))
               (archived (eq (alist-get 'isArchived repo) t))
               (fork (eq (alist-get 'isFork repo) t)))
           (insert (format "  %s%s%s\n"
                           name
                           (if archived " [archived]" "")
                           (if fork " [fork]" "")))))
       (goto-char (point-min))
       (display-buffer (current-buffer))))))

;;;###autoload
(defun github-clone-all-cancel ()
  "実行中のクローン処理をキャンセルする。"
  (interactive)
  (unless github-clone-all--current-state
    (error "実行中のクローン処理はありません"))
  ;; 実行中の git clone プロセスをすべて kill
  (dolist (proc (process-list))
    (when (string-prefix-p "git-clone-" (process-name proc))
      (delete-process proc)))
  (github-clone-all--log "\nクローン処理がキャンセルされました。")
  (display-buffer (get-buffer "*github-clone-all*"))
  (setq github-clone-all--current-state nil))

(provide 'github-clone-all)
;;; github-clone-all.el ends here
