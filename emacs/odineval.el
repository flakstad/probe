;;; odineval.el --- REPL-like Odin eval helpers -*- lexical-binding: t; -*-

;; This is intentionally small: it shells out to the local Python odineval CLI,
;; displays results in Emacs buffers, and leaves Odin semantics to Odin itself.

(require 'compile)
(require 'seq)
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

(defcustom odineval-inline-result-prefix "=> "
  "Prefix used for inline odineval result overlays."
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

(defun odineval-clear-inline-results ()
  "Delete odineval inline result overlays in the current buffer."
  (remove-overlays (point-min) (point-max) 'odineval-result-overlay t))

(defun odineval--enable-inline-result-clearing ()
  "Clear odineval inline overlays before the next command in this buffer."
  (add-hook 'pre-command-hook #'odineval-clear-inline-results nil t))

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

(defun odineval--cli-args (command package code &optional no-print show internal)
  "Return odineval CLI args for COMMAND, PACKAGE, and CODE."
  (append
   (list "-m" "src.odineval" command package code)
   (when no-print (list "--no-print"))
   (when show (list "--show"))
   (when internal (list "--internal"))))

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

(defun odineval--visible-output (stdout stderr show-generated)
  "Return (GENERATED . VISIBLE-OUTPUT) from STDOUT and STDERR."
  (let* ((split (and show-generated (odineval--split-generated-output stdout)))
         (generated (car-safe split))
         (visible-stdout (if split (cdr split) stdout))
         (visible (string-trim
                   (concat visible-stdout
                           (unless (or (string-empty-p visible-stdout)
                                       (string-empty-p stderr))
                             "\n")
                           stderr))))
    (cons generated visible)))

(defun odineval--show-inline-result (buffer beg end text exit-code)
  "Show TEXT inline in BUFFER after BEG and END."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (remove-overlays beg end 'odineval-result-overlay t)
      (let* ((trimmed (string-trim text))
             (display-text (if (string-empty-p trimmed)
                               (format " %s<exit %s>" odineval-inline-result-prefix exit-code)
                             (format " %s%s" odineval-inline-result-prefix
                                     (replace-regexp-in-string "[\n\r\t ]+" " " trimmed))))
             (ov (make-overlay beg end)))
        (put-text-property 0 1 'cursor 0 display-text)
        (put-text-property 0 (length display-text) 'face
                           (if (zerop exit-code) 'shadow 'error)
                           display-text)
        (overlay-put ov 'odineval-result-overlay t)
        (overlay-put ov 'priority 1000)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'after-string display-text)))))

(defun odineval--insert-comment-result (buffer line-end text exit-code)
  "Insert TEXT as a // => result comment in BUFFER after LINE-END."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char line-end)
        (forward-line 1)
        (while (and (not (eobp))
                    (looking-at-p "[[:space:]]*//[[:space:]]*=>"))
          (delete-region (line-beginning-position)
                         (min (point-max) (1+ (line-end-position)))))
        (let* ((trimmed (string-trim text))
               (single-line (replace-regexp-in-string "[\n\r\t ]+" " " trimmed)))
          (insert (format "// => %s%s\n"
                          (if (zerop exit-code) "" (format "<exit %s> " exit-code))
                          single-line)))))))

(defun odineval--display-generated (generated)
  "Display GENERATED Odin in a separate buffer when non-nil."
  (when generated
    (let ((runner-buffer (odineval--prepare-buffer odineval-runner-buffer-name)))
      (with-current-buffer runner-buffer
        (let ((inhibit-read-only t))
          (insert generated)
          (when (fboundp 'odin-mode)
            (odin-mode))))
      (display-buffer runner-buffer))))

(defun odineval--display-output (stdout stderr exit-code show-generated)
  "Display STDOUT and STDERR with EXIT-CODE.
When SHOW-GENERATED is non-nil, split generated Odin into a separate buffer when
possible."
  (let* ((visible-data (odineval--visible-output stdout stderr show-generated))
         (generated (car visible-data))
         (visible (cdr visible-data))
         (result-buffer (odineval--prepare-buffer odineval-result-buffer-name)))
    (odineval--display-generated generated)
    (with-current-buffer result-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ odineval exited %s\n\n" exit-code))
        (unless (string-empty-p visible)
          (insert visible)
          (unless (string-suffix-p "\n" visible)
            (insert "\n")))
        (goto-char (point-min))))
    (display-buffer result-buffer)
    (message "odineval exited %s" exit-code)))

(defun odineval--run (command package code &optional no-print show internal display bounds)
  "Run odineval COMMAND for PACKAGE and CODE."
  (setq odineval--last-source-buffer (current-buffer))
  (let* ((source-buffer (current-buffer))
         (bounds (or bounds
                     (and (memq display '(inline comment))
                          (cons (line-beginning-position) (line-end-position)))))
         (default-directory (file-name-as-directory (expand-file-name odineval-root)))
         (stdout-buffer (generate-new-buffer " *odineval-stdout*"))
         (stderr-buffer (generate-new-buffer " *odineval-stderr*"))
         (args (odineval--cli-args command package code no-print show internal)))
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
           (pcase display
             ('inline
              (let* ((visible-data (odineval--visible-output stdout stderr show))
                     (generated (car visible-data))
                     (visible (cdr visible-data)))
                (odineval--display-generated generated)
                (odineval--show-inline-result source-buffer (car bounds) (cdr bounds) visible exit-code)
                (message "odineval exited %s" exit-code)))
             ('comment
              (let* ((visible-data (odineval--visible-output stdout stderr show))
                     (generated (car visible-data))
                     (visible (cdr visible-data)))
                (odineval--display-generated generated)
                (odineval--insert-comment-result source-buffer (cdr bounds) visible exit-code)
                (message "odineval exited %s" exit-code)))
             (_
              (odineval--display-output stdout stderr exit-code show)))))))))

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
    (and (looking-at-p "[[:space:]]*//")
         (not (looking-at-p "[[:space:]]*//[[:space:]]*=>")))))

(defun odineval--result-comment-line-p ()
  "Return non-nil when the current line is an odineval // => result line."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[[:space:]]*//[[:space:]]*=>")))

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
         (text (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (without-results
          (string-join
           (seq-remove
            (lambda (line)
              (string-match-p "\\`[[:space:]]*//[[:space:]]*=>" line))
            (split-string text "\n"))
           "\n")))
    (string-trim (odineval--strip-line-comment-prefix without-results))))

(defun odineval-current-line-code ()
  "Return code from the current line, stripping a leading // if present."
  (let ((line (string-trim
               (buffer-substring-no-properties
                (line-beginning-position)
                (line-end-position)))))
    (string-trim (odineval--strip-line-comment-prefix line))))

(defun odineval--call-bounds-before-point ()
  "Return bounds of the parenthesized call ending at or before point.
This is a lightweight Odin-aware helper for cases like:

  fmt.println(add(5,2)|)

where point is just after the inner call."
  (save-excursion
    (skip-chars-backward " \t\n")
    (when (and (> (point) (point-min))
               (eq (char-before) ?\)))
      (let ((end (point))
            (depth 0)
            (open nil))
        (while (and (> (point) (point-min))
                    (not open))
          (backward-char)
          (cond
           ((eq (char-after) ?\))
            (setq depth (1+ depth)))
           ((eq (char-after) ?\()
            (setq depth (1- depth))
            (when (zerop depth)
              (setq open (point))))))
        (when open
          (goto-char open)
          (skip-chars-backward " \t")
          (skip-chars-backward "A-Za-z0-9_\\.")
          (when (< (point) open)
            (cons (point) end)))))))

(defun odineval-current-line-or-call-unit ()
  "Return current call expression before point, falling back to current line."
  (if-let ((bounds (odineval--call-bounds-before-point)))
      (cons (buffer-substring-no-properties (car bounds) (cdr bounds)) bounds)
    (cons (odineval-current-line-code)
          (cons (line-beginning-position) (line-end-position)))))

(defun odineval-current-line-bounds ()
  "Return bounds of the current line."
  (cons (line-beginning-position) (line-end-position)))

(defun odineval-current-unit ()
  "Return (CODE . BOUNDS) for the current eval unit.
When point is inside a scratch // block, the unit is the whole block.
Otherwise prefer the parenthesized call ending before point, falling back to the
current line."
  (if (odineval--comment-line-p)
      (let ((bounds (odineval--comment-block-bounds)))
        (cons (odineval-comment-block-code) bounds))
    (odineval-current-line-or-call-unit)))

;;;###autoload
(defun odineval-run-expression (code)
  "Run Odin expression CODE in a generated runner for the current package."
  (interactive (list (odineval-read-code)))
  (odineval--run "run"
                 (odineval-package-directory)
                 code
                 odineval-default-no-print
                 odineval-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun odineval-check-expression (code)
  "Check Odin expression CODE in a generated runner for the current package."
  (interactive (list (odineval-read-code)))
  (odineval--run "check"
                 (odineval-package-directory)
                 code
                 odineval-default-no-print
                 odineval-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun odineval-run-line (&optional no-print)
  "Run the current eval unit and show the result inline.
If point is inside a scratch // block, run the whole block. Otherwise run the
current line. This is intended for Clojure-style scratch lines such as:

  // add(5,2)

With prefix argument NO-PRINT, treat the line as statements."
  (interactive "P")
  (let ((unit (odineval-current-unit)))
    (odineval--run "run"
                   (odineval-package-directory)
                   (car unit)
                   (or no-print odineval-default-no-print)
                   odineval-show-generated
                   t
                   'inline
                   (odineval-current-line-bounds))))

;;;###autoload
(defun odineval-insert-line-result (&optional no-print)
  "Run the current eval unit and insert the result as a // => comment."
  (interactive "P")
  (let ((unit (odineval-current-unit)))
    (odineval--run "run"
                   (odineval-package-directory)
                   (car unit)
                   (or no-print odineval-default-no-print)
                   odineval-show-generated
                   t
                   'comment
                   (cdr unit))))

;;;###autoload
(defun odineval-popup-line (&optional no-print)
  "Run the current eval unit and show output in the odineval result buffer."
  (interactive "P")
  (let ((unit (odineval-current-unit)))
    (odineval--run "run"
                   (odineval-package-directory)
                   (car unit)
                   (or no-print odineval-default-no-print)
                   odineval-show-generated
                   t
                   'buffer
                   (cdr unit))))

;;;###autoload
(defun odineval-insert-comment-block-result (&optional no-print)
  "Run the current // comment block and insert a // => result comment."
  (interactive "P")
  (let ((bounds (odineval--comment-block-bounds)))
    (odineval--run "run"
                   (odineval-package-directory)
                   (odineval-comment-block-code)
                   (or no-print odineval-default-no-print)
                   odineval-show-generated
                   t
                   'comment
                   bounds)))

;;;###autoload
(defun odineval-check-line (&optional no-print)
  "Check the current line as Odin code inside the current package.
If the line starts with `//`, strip the comment prefix first."
  (interactive "P")
  (odineval--run "check"
                 (odineval-package-directory)
                 (odineval-current-line-code)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated
                 t
                 'buffer))

;;;###autoload
(defun odineval-run-region (start end &optional no-print)
  "Run the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (odineval--run "run"
                 (odineval-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun odineval-check-region (start end &optional no-print)
  "Check the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (odineval--run "check"
                 (odineval-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated
                 nil
                 'buffer))

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
                 odineval-show-generated
                 t
                 'inline
                 (odineval-current-line-bounds)))

;;;###autoload
(defun odineval-check-comment-block (&optional no-print)
  "Check uncommented code from the contiguous // comment block around point.
With prefix argument NO-PRINT, treat the code as statements."
  (interactive "P")
  (odineval--run "check"
                 (odineval-package-directory)
                 (odineval-comment-block-code)
                 (or no-print odineval-default-no-print)
                 odineval-show-generated
                 t
                 'buffer))

(defun odineval--compile-in-package (command)
  "Run Odin COMMAND in the current package directory via `compile'."
  (let ((default-directory (file-name-as-directory (odineval-package-directory))))
    (compile command)))

;;;###autoload
(defun odineval-run-package ()
  "Run `odin run .' in the current Odin package directory."
  (interactive)
  (odineval--compile-in-package "odin run ."))

;;;###autoload
(defun odineval-build-package ()
  "Run `odin build .' in the current Odin package directory."
  (interactive)
  (odineval--compile-in-package "odin build ."))

;;;###autoload
(defun odineval-check-package ()
  "Run `odin check .' in the current Odin package directory."
  (interactive)
  (odineval--compile-in-package "odin check ."))

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
  (odineval--enable-inline-result-clearing)
  (local-set-key (kbd "C-c C-e") #'odineval-run-line)
  (local-set-key (kbd "C-c C-p") #'odineval-popup-line)
  (local-set-key (kbd "C-c C-i") #'odineval-insert-line-result)
  (local-set-key (kbd "C-c C-r") #'odineval-run-region)
  (local-set-key (kbd "C-c C-c") #'odineval-run-proc)
  (local-set-key (kbd "C-c C-x") #'odineval-run-comment-block)
  (local-set-key (kbd "C-c C-k") #'odineval-check-expression)
  (local-set-key (kbd "C-c C-a") #'odineval-run-package)
  (local-set-key (kbd "C-c C-v") #'odineval-build-package)
  (local-set-key (kbd "C-c C-s") #'odineval-toggle-show-generated)
  (local-set-key (kbd "C-c C-z") #'odineval-switch-to-result))

(provide 'odineval)

;;; odineval.el ends here
