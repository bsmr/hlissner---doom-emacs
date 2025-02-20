;;; core/cli/ci.el -*- lexical-binding: t; -*-

(defcli! ci (&optional target &rest args)
  "TODO"
  (unless target
    (user-error "No CI target given"))
  (if-let (fn (intern-soft (format "doom-cli--ci-%s" target)))
      (apply fn args)
    (user-error "No known CI target: %S" target)))


;;
;;;


(defun doom-cli--ci-deploy-hooks ()
  (let ((dir (doom-path doom-emacs-dir ".git/hooks"))
        (default-directory doom-emacs-dir))
    (make-directory dir 'parents)
    (dolist (hook '("commit-msg"))
      (let ((file (doom-path dir hook)))
        (with-temp-file file
          (insert "#!/usr/bin/env sh\n"
                  (doom-path doom-emacs-dir "bin/doom")
                  " --nocolor ci hook-" hook
                  " \"$@\""))
        (set-file-modes file #o700)
        (print! (success "Created %s") (relpath file))))))


;;
;;; Git hooks

(defvar doom-cli-commit-rules
  (list (fn! (&key subject)
          (when (<= (length subject) 10)
            (cons 'error "Subject is too short (<10) and should be more descriptive")))

        (fn! (&key subject type)
          (unless (memq type '(bump revert))
            (let ((len (length subject)))
              (cond ((> len 50)
                     (cons 'warning
                           (format "Subject is %d characters; <=50 is ideal, 72 is max"
                                   len)))
                    ((> len 72)
                     (cons 'error
                           (format "Subject is %d characters; <=50 is ideal, 72 is max"
                                   len)))))))

        (fn! (&key type)
          (unless (memq type '(bump dev docs feat fix merge module nit perf
                                    refactor release revert test tweak))
            (cons 'error (format "Commit has an invalid type (%s)" type))))

        (fn! (&key summary)
          (when (or (not (stringp summary))
                    (string-blank-p summary))
            (cons 'error "Commit has no summary")))

        (fn! (&key summary subject)
          (and (stringp summary)
               (string-match-p "^[A-Z][^-]" summary)
               (not (string-match-p "\\(SPC\\|TAB\\|ESC\\|LFD\\|DEL\\|RET\\)" summary))
               (cons 'error (format "%S in summary is capitalized; do not capitalize the summary"
                                    (car (split-string summary " "))))))

        (fn! (&key type scopes summary)
          (and (memq type '(bump revert release merge module))
               scopes
               (cons 'error
                     (format "Scopes for %s commits should go after the colon, not before"
                             type))))

        (fn! (&key type scopes)
          (unless (memq type '(bump revert merge module release))
            (cl-loop with scopes =
                     (cl-loop for path
                              in (cdr (doom-module-load-path (list doom-modules-dir)))
                              for (_category . module)
                              = (doom-module-from-path path)
                              collect (symbol-name module))
                     with extra-scopes  = '("cli")
                     with regexp-scopes = '("^&")
                     with type-scopes =
                     (pcase type
                       (`docs
                        (cons "install"
                              (mapcar #'file-name-base
                                      (doom-glob doom-docs-dir "[a-z]*.org")))))
                     with scopes-re =
                     (concat (string-join regexp-scopes "\\|")
                             "\\|"
                             (regexp-opt (append type-scopes extra-scopes scopes)))
                     for scope in scopes
                     if (not (string-match scopes-re scope))
                     collect scope into error-scopes
                     finally return
                     (when error-scopes
                       (cons 'error (format "Commit has invalid scope(s): %s"
                                            error-scopes))))))

        (fn! (&key scopes)
          (unless (equal scopes (sort scopes #'string-lessp))
            (cons 'error "Scopes are not in lexicographical order")))

        (fn! (&key type body)
          (unless (memq type '(bump revert merge))
            (catch 'result
              (with-temp-buffer
                (save-excursion (insert body))
                (while (re-search-forward "^[^\n]\\{73,\\}" nil t)
                  ;; Exclude ref lines, bump lines, comments, lines with URLs,
                  ;; or indented lines
                  (save-excursion
                    (or (let ((bump-re "\\(https?://.+\\|[^/]+\\)/[^/]+@[a-z0-9]\\{12\\}"))
                          (re-search-backward (format "^%s -> %s$" bump-re bump-re) nil t))
                        (re-search-backward "https?://[^ ]+\\{73,\\}" nil t)
                        (re-search-backward "^\\(?:#\\| +\\)" nil t)
                        (throw 'result (cons 'error "Line(s) in commit body exceed 72 characters")))))))))

        (fn! (&key bang body type)
          (if bang
              (cond ((not (string-match-p "^BREAKING CHANGE:" body))
                     (cons 'error "'!' present in commit type, but missing 'BREAKING CHANGE:' in body"))
                    ((not (string-match-p "^BREAKING CHANGE: .+" body))
                     (cons 'error "'BREAKING CHANGE:' present in commit body, but missing explanation")))
            (when (string-match-p "^BREAKING CHANGE:" body)
              (cons 'error (format "'BREAKING CHANGE:' present in body, but missing '!' after %S"
                                   type)))))

        (fn! (&key type body)
          (and (eq type 'bump)
               (let ((bump-re "\\(?:https?://.+\\|[^/]+\\)/[^/]+@\\([a-z0-9]+\\)"))
                 (not (string-match-p (concat "^" bump-re " -> " bump-re "$")
                                      body)))
               (cons 'error "Bump commit is missing commit hash diffs")))

        (fn! (&key body)
          (with-temp-buffer
            (insert body)
            (catch 'result
              (let ((bump-re "^\\(?:https?://.+\\|[^/]+\\)/[^/]+@\\([a-z0-9]+\\)"))
                (while (re-search-backward bump-re nil t)
                  (when (/= (length (match-string 1)) 12)
                    (throw 'result (cons 'error (format "Commit hash in %S must be 12 characters long"
                                                        (match-string 0))))))))))

        ;; TODO Add bump validations for revert: type.

        (fn! (&key body)
          (when (string-match-p "^\\(\\(Fix\\|Clos\\|Revert\\)ed\\|Reference[sd]\\|Refs\\):? " body)
            (cons 'error "No present tense or imperative mood for a reference line")))

        (fn! (&key refs)
          (and (seq-filter (lambda (ref)
                             (string-match-p "^\\(\\(Fix\\|Close\\|Revert\\)\\|Ref\\): " ref))
                           refs)
               (cons 'error "Colon after reference line keyword; omit the colon on Fix, Close, Revert, and Ref lines")))

        (fn! (&key refs)
          (catch 'found
            (dolist (line refs)
              (cl-destructuring-bind (type . ref) (split-string line " +")
                (setq ref (string-join ref " "))
                (or (string-match "^\\(https?://.+\\|[^/]+/[^/]+\\)?\\(#[0-9]+\\|@[a-z0-9]+\\)" ref)
                    (string-match "^https?://" ref)
                    (and (string-match "^[a-z0-9]\\{12\\}$" ref)
                         (= (car (doom-call-process "git" "show" ref))
                            0))
                    (throw 'found
                           (cons 'error
                                 (format "%S is not a valid issue/PR, URL, or 12-char commit hash"
                                         line))))))))

        ;; TODO Check that bump/revert SUBJECT list: 1) valid modules and 2)
        ;;      modules whose files are actually being touched.

        ;; TODO Ensure your diff corraborates your SCOPE

        ))

(defun doom-cli--ci-hook-commit-msg (file)
  (with-temp-buffer
    (insert-file-contents file)
    (doom-cli--ci--lint
     (list (cons
            "CURRENT"
            (buffer-substring (point-min)
                              (and (re-search-forward "^# Please enter the commit message" nil t)
                                   (match-beginning 0))))))))


;;
;;;

(defun doom-cli--ci--lint (commits)
  (let ((errors? 0)
        (warnings? 0))
    (print! (start "Linting %d commits" (length commits)))
    (print-group!
     (dolist (commit commits)
       (let (subject body refs summary type scopes bang refs errors warnings)
         (with-temp-buffer
           (save-excursion (insert (cdr commit)))
           (setq subject (buffer-substring (point-min) (line-end-position))
                 body (buffer-substring
                       (line-beginning-position 3)
                       (save-excursion
                         (or (and (re-search-forward (format "\n\n%s "
                                                             (regexp-opt '("Co-authored-by:" "Signed-off-by:" "Fix" "Ref" "Close" "Revert")
                                                                         t))
                                                     nil t)
                                  (match-beginning 1))
                             (point-max))))
                 refs (split-string
                       (save-excursion
                         (buffer-substring
                          (or (and (re-search-forward (format "\n\n%s "
                                                              (regexp-opt '("Co-authored-by:" "Signed-off-by:" "Fix" "Ref" "Close" "Revert")
                                                                          t))
                                                      nil t)
                                   (match-beginning 1))
                              (point-max))
                          (point-max)))
                       "\n" t))
           (save-match-data
             (when (looking-at "^\\([a-zA-Z0-9_-]+\\)\\(!?\\)\\(?:(\\([^)]+\\))\\)?: \\([^\n]+\\)")
               (setq type (intern (match-string 1))
                     bang (equal (match-string 2) "!")
                     scopes (ignore-errors (split-string (match-string 3) ","))
                     summary (match-string 4)))))
         (dolist (fn doom-cli-commit-rules)
           (pcase (funcall fn
                           :bang bang
                           :body body
                           :refs refs
                           :scopes scopes
                           :subject subject
                           :summary summary
                           :type type)
             (`(,type . ,msg)
              (push msg (if (eq type 'error) errors warnings)))))
         (if (and (null errors) (null warnings))
             (print! (success "%s %s") (substring (car commit) 0 7) subject)
           (print! (start "%s %s") (substring (car commit) 0 7) subject))
         (print-group!
          (when errors
            (cl-incf errors?)
            (dolist (e (reverse errors))
              (print! (error "%s" e))))
          (when warnings
            (cl-incf warnings?)
            (dolist (e (reverse warnings))
              (print! (warn "%s" e))))))))
    (when (> warnings? 0)
      (print! (warn "Warnings: %d") errors?))
    (when (> errors? 0)
      (print! (error "Failures: %d") errors?))
    (if (not (or (> errors? 0) (> warnings? 0)))
        (print! (success "There were no issues!"))
      (terpri)
      (print! "See https://docs.doomemacs.org/latest/#/developers/conventions/git-commits for details")
      (when (> errors? 0)
        (throw 'exit 1)))))

(defun doom-cli--ci--read-commits ()
  (let (commits)
    (while (re-search-backward "^commit \\([a-z0-9]\\{40\\}\\)" nil t)
      (push (cons (match-string 1)
                  (replace-regexp-in-string
                   "^    " ""
                   (save-excursion
                     (buffer-substring-no-properties
                      (search-forward "\n\n")
                      (if (re-search-forward "\ncommit \\([a-z0-9]\\{40\\}\\)" nil t)
                          (match-beginning 0)
                        (point-max))))))
            commits))
    commits))

(defun doom-cli--ci-lint-commits (from &optional to)
  (with-temp-buffer
    (insert
     (cdr (doom-call-process
           "git" "log"
           (format "%s..%s" from (or to "HEAD")))))
    (doom-cli--ci--lint (doom-cli--ci--read-commits))))
