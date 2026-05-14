;;; odineval.el --- REPL-like Odin eval helpers -*- lexical-binding: t; -*-

;; This is intentionally small: it shells out to the local Python odineval CLI,
;; displays results in Emacs buffers, and leaves Odin semantics to Odin itself.

(require 'compile)
(require 'subr-x)

(defgroup odineval nil
  "REPL-like eval helpers for Odin."
  :group 'languages)

(defcustom odineval-python-executable "python3"
  "Python executable used to run odineval."
  :type 'string
  :group 'odineval)

(defcustom odineval-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name default-directory))))
  "Path to the local odineval checkout."
  :type 'directory
  :group 'odineval)

(defcustom odineval-result-buffer-name "*Odin Eval*"
  "Buffer name used for odineval command output."
  :type 'string
  :group 'odineval)

(defcustom odineval-runner-buffer-name "*Odin Eval Generated*"
  "Buffer name used for generated Odin when `odineval-show-generated' is non-nil."
  :type 'string
  :group 'odineval)

(defcustom odineval-show-generated nil
  "When non-nil, request and display generated Odin before command output."
  :type 'boolean
  :group 'odineval)

(defcustom odineval-default-no-print nil
  "When non-nil, default eval commands run snippets as statements."
  :type 'boolean
  :group 'odineval)

(defvar odineval--last-source-buffer nil)

(defun odineval--project-root (&optional start)
  "Return a likely Odin project root for START or the current buffer."
  (let* ((path (cond
                ((bufferp start) (or (buffer-file-name start) default-directory))
                ((stringp start) start)
                ((buffer-file-name) (buffer-file-name))
                (t default-directory)))
         (dir (if (and path (file-directory-p path))
                  path
                (file-name-directory (expand-file-name path)))))
    (or (locate-dominating-file dir "ols.json")
        (locate-dominating-file dir "odin.json")
        (locate-dominating-file dir ".git")
        dir)))

(defun odineval-package-directory ()
  "Return the Odin package directory for the current buffer.
For Odin this is usually the directory containing the current file."
  (if buffer-file-name
      (file-name-directory (expand-file-name buffer-file-name))
    default-directory))

(defun odineval--cli-args (command package code &optional no-print show)
  "Return odineval CLI args for COMMAND, PACKAGE, and CODE."
  (append
   (list "-m" "src.odineval" command package code)
   (when no-print (list "--no-print"))
   (when show (list "--show"))))

(defun odineval--prepare-buffer (name)
  "Create and clear buffer NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local truncate-lines nil)
        (setq-local word-wrap t)
        (visual-line-mode 1)))
    buffer))

(defun odineval--split-generated-output (text)
  "Split TEXT from `--show' into (GENERATED . OUTPUT).
This relies on generated programs ending before the first Odin compiler/runtime
output. It is deliberately best-effort; if splitting is unclear, all text is
treated as command output."
  (if (string-match "\nmain :: proc() {\n" text)
      (let ((last-brace (string-match "\n}\n" text)))
        (if last-brace
            (cons (substring text 0 (match-end 0))
                  (substring text (match-end 0)))
          (cons nil text)))
    (cons nil text)))

(defun odineval--display-output (stdout stderr exit-code show-generated)
  "Display STDOUT and STDERR with EXIT-CODE.
When SHOW-GENERATED is non-nil, split generated Odin into a separate buffer when
possible."
  (let* ((split (and show-generated (odineval--split-generated-output stdout)))
         (generated (car-safe split))
         (visible-stdout (if split (cdr split) stdout))
         (result-buffer (odineval--prepare-buffer odineval-result-buffer-name)))
    (when generated
      (let ((runner-buffer (odineval--prepare-buffer odineval-runner-buffer-name)))
        (with-current-buffer runner-buffer
          (let ((inhibit-read-only t))
            (insert generated)
            (when (fboundp 'odin-mode)
              (odin-mode))))
        (display-buffer runner-buffer)))
    (with-current-buffer result-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ odineval exited %s\n\n" exit-code))
        (unless (string-empty-p visible-stdout)
          (insert visible-stdout)
          (unless (string-suffix-p "\n" visible-stdout)
            (insert "\n")))
        (unless (string-empty-p stderr)
          (insert "\n[stderr]\n")
          (insert stderr))
        (goto-char (point-min))))
    (display-buffer result-buffer)
    (message "odineval exited %s" exit-code)))

(defun odineval--run (command package code &optional no-print show)
  "Run odineval COMMAND for PACKAGE and CODE."
  (setq odineval--last-source-buffer (current-buffer))
  (let* ((default-directory (file-name-as-directory (expand-file-name odineval-root)))
         (stdout-buffer (generate-new-buffer " *odineval-stdout*"))
         (stderr-buffer (generate-new-buffer " *odineval-stderr*"))
         (args (odineval--cli-args command package code no-print show)))
    (make-process
     :name "odineval"
     :buffer stdout-buffer
     :stderr stderr-buffer
     :command (cons odineval-python-executable args)
     :noquery t
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (let ((exit-code (process-exit-status process))
               (stdout (with-current-buffer stdout-buffer
                         (buffer-substring-no-properties (point-min) (point-max))))
               (stderr (with-current-buffer stderr-buffer
                         (buffer-substring-no-properties (point-min) (point-max)))))
           (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
           (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
           (odineval--display-output stdout stderr exit-code show)))))))

(defun odineval-read-code ()
  "Read an Odin expression from the minibuffer, defaulting to symbol at point."
  (read-string "Odin expression: " (or (thing-at-point 'symbol t) "")))

(defun odineval--strip-line-comment-prefix (text)
  "Strip Odin // comment prefixes from TEXT."
  (string-join
   (mapcar
    (lambda (line)
      (replace-regexp-in-string "\\`[[:space:]]*//[[:space:]]?" "" line))
    (split-string text "\n"))
   "\n"))

(defun odineval--comment-line-p ()
  "Return non-nil when the current line starts with an Odin line comment."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[[:space:]]*//")))

(defun odineval--comment-block-bounds ()
  "Return bounds for the contiguous // comment block around point."
  (unless (odineval--comment-line-p)
    (error "Point is not inside a // comment block"))
  (save-excursion
    (let (start end)
      (while (and (not (bobp))
                  (progn
                    (forward-line -1)
                    (odineval--comment-line-p))))
      (unless (odineval--comment-line-p)
        (forward-line 1))
      (setq start (line-beginning-position))
      (while (and (not (eobp))
                  (odineval--comment-line-p))
        (forward-line 1))
      (setq end (point))
      (cons start end))))

(defun odineval-comment-block-code ()
  "Return uncommented code from the contiguous // comment block around point."
  (let* ((bounds (odineval--comment-block-bounds))
         (text (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (string-trim (odineval--strip-line-comment-prefix text))))

;;;###autoload
(defun odineval-run-expression (code)
  "Run Odin expression CODE in a generated runner for the current package."
  (interactive (list (odineval-read-code)))
  (odineval--run "run"
                 (odineval-package-directory)
                 code
                 odineval-default-no-print
                 odineval-show-generated))

;;;###autoload
(defun odineval-check-expression (code)
  "Check Odin expression CODE in a generated runner for the current package."
  (interactive (list (odineval-read-code)))
  (odineval--run "check"
                 (odineval-package-directory)
                 code
                 odineval-default-no-print
                 odineval-show-generated))

;;;###autoload
(defun odineval-run-region (start end &optional no-print)
  "Run the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (odineval--run "run"
                 (odineval-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated))

;;;###autoload
(defun odineval-check-region (start end &optional no-print)
  "Check the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (odineval--run "check"
                 (odineval-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated))

;;;###autoload
(defun odineval-run-comment-block (&optional no-print)
  "Run uncommented code from the contiguous // comment block around point.
With prefix argument NO-PRINT, treat the code as statements.

This is the Odin analogue of keeping exploratory calls in a Clojure
`(comment ...)` form:

  // target.answer()
  // target.some_proc(1, 2)"
  (interactive "P")
  (odineval--run "run"
                 (odineval-package-directory)
                 (odineval-comment-block-code)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated))

;;;###autoload
(defun odineval-check-comment-block (&optional no-print)
  "Check uncommented code from the contiguous // comment block around point.
With prefix argument NO-PRINT, treat the code as statements."
  (interactive "P")
  (odineval--run "check"
                 (odineval-package-directory)
                 (odineval-comment-block-code)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated))

;;;###autoload
(defun odineval-run-proc (name args)
  "Run target proc NAME with raw Odin ARGS."
  (interactive
   (list (read-string "Proc: " (or (thing-at-point 'symbol t) ""))
         (read-string "Args: ")))
  (odineval-run-expression (format "target.%s(%s)" name args)))

;;;###autoload
(defun odineval-run-proc-no-args ()
  "Run the target proc at point with no arguments."
  (interactive)
  (let ((name (or (thing-at-point 'symbol t)
                  (read-string "Proc: "))))
    (odineval-run-expression (format "target.%s()" name))))

;;;###autoload
(defun odineval-toggle-show-generated ()
  "Toggle generated Odin display for odineval commands."
  (interactive)
  (setq odineval-show-generated (not odineval-show-generated))
  (message "odineval-show-generated: %s" odineval-show-generated))

;;;###autoload
(defun odineval-switch-to-result ()
  "Display the odineval result buffer."
  (interactive)
  (pop-to-buffer odineval-result-buffer-name))

;;;###autoload
(defun odineval-switch-to-source ()
  "Return to the most recent odineval source buffer."
  (interactive)
  (if (buffer-live-p odineval--last-source-buffer)
      (pop-to-buffer odineval--last-source-buffer)
    (message "No odineval source buffer recorded.")))

(defun odineval-setup-odin-mode-keys ()
  "Install odineval keybindings in the current Odin buffer."
  (local-set-key (kbd "C-c C-e") #'odineval-run-expression)
  (local-set-key (kbd "C-c C-r") #'odineval-run-region)
  (local-set-key (kbd "C-c C-c") #'odineval-run-proc)
  (local-set-key (kbd "C-c C-x") #'odineval-run-comment-block)
  (local-set-key (kbd "C-c C-k") #'odineval-check-expression)
  (local-set-key (kbd "C-c C-s") #'odineval-toggle-show-generated)
  (local-set-key (kbd "C-c C-z") #'odineval-switch-to-result))

(provide 'odineval)

;;; odineval.el ends here
