;;; probe.el --- Scratch Odin probing helpers -*- lexical-binding: t; -*-

;; This is intentionally small: it shells out to the probe CLI, displays
;; results in Emacs buffers, and leaves Odin semantics to Odin itself.

(require 'compile)
(require 'seq)
(require 'subr-x)

(defgroup probe nil
  "Scratch execution helpers for Odin."
  :group 'languages)

(defcustom probe-command "probe"
  "Fallback compiled probe executable."
  :type 'string
  :group 'probe)

(defcustom probe-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name default-directory))))
  "Path to the local probe checkout."
  :type 'directory
  :group 'probe)

(defcustom probe-result-buffer-name "*Probe*"
  "Buffer name used for probe command output."
  :type 'string
  :group 'probe)

(defcustom probe-inline-result-prefix "=> "
  "Prefix used for inline probe result overlays."
  :type 'string
  :group 'probe)

(defcustom probe-runner-buffer-name "*Probe Generated*"
  "Buffer name used for generated Odin when `probe-show-generated' is non-nil."
  :type 'string
  :group 'probe)

(defcustom probe-show-generated nil
  "When non-nil, request and display generated Odin before command output."
  :type 'boolean
  :group 'probe)

(defcustom probe-default-no-print nil
  "When non-nil, default probe commands run snippets as statements."
  :type 'boolean
  :group 'probe)

(defcustom probe-test-after-build nil
  "When non-nil, run `odin test .' after a successful package build."
  :type 'boolean
  :group 'probe)

(defcustom probe-test-command "odin test . -define:ODIN_TEST_LOG_LEVEL=warning"
  "Odin command used by probe test commands.
The default suppresses the verbose successful test-runner info logs while still
showing warnings, errors, and the final test summary."
  :type 'string
  :group 'probe)

(defvar probe--last-source-buffer nil)

(defun probe-clear-inline-results ()
  "Delete probe inline result overlays in the current buffer."
  (remove-overlays (point-min) (point-max) 'probe-result-overlay t))

(defun probe--enable-inline-result-clearing ()
  "Clear probe inline overlays before the next command in this buffer."
  (add-hook 'pre-command-hook #'probe-clear-inline-results nil t))

(defun probe--project-root (&optional start)
  "Return a likely Odin project root for START or the current buffer."
  (let* ((path (cond
                ((bufferp start) (or (buffer-file-name start) default-directory))
                ((stringp start) start)
                ((buffer-file-name) (buffer-file-name))
                (t default-directory)))
         (dir (if (and path (file-directory-p path))
                  path
                (file-name-directory (expand-file-name path)))))
    (let ((find-entry-point-dir
           (lambda (directory)
             (let ((current (file-name-as-directory (expand-file-name directory)))
                   (found nil))
               (while (and current (not found))
                 (when (probe--directory-has-entry-point-p current)
                   (setq found current))
                 (let ((parent (file-name-directory (directory-file-name current))))
                   (if (or (null parent) (string= parent current))
                       (setq current nil)
                     (setq current parent))))
               found))))
      (or (locate-dominating-file dir "ols.json")
          (locate-dominating-file dir "odin.json")
          (funcall find-entry-point-dir dir)
          (locate-dominating-file dir ".git")
          dir))))

(defun probe-package-directory ()
  "Return the Odin package directory for the current buffer.
For Odin this is usually the directory containing the current file."
  (if buffer-file-name
      (file-name-directory (expand-file-name buffer-file-name))
    default-directory))

(defun probe--directory-has-entry-point-p (directory)
  "Return non-nil when DIRECTORY contains a package `main` with `main :: proc`."
  (seq-some
   (lambda (path)
     (with-temp-buffer
       (insert-file-contents path)
       (and (re-search-forward "^[[:space:]]*package[[:space:]]+main\\b" nil t)
            (re-search-forward "^[[:space:]]*main[[:space:]]*::[[:space:]]*proc\\b" nil t))))
   (directory-files directory t "\\.odin\\'")))

(defun probe-project-directory ()
  "Return the current Odin project directory."
  (file-name-as-directory (probe--project-root)))

(defun probe--cli-args (command package code &optional no-print show internal save generated)
  "Return probe CLI args for COMMAND, PACKAGE, and CODE."
  (append
   (list command package code)
   (when no-print (list "--no-print"))
   (when show (list "--show"))
   (when internal (list "--internal"))
   (when save (list "--save" save))
   (when generated (list "--generated" generated))))

(defun probe--compiled-command ()
  "Return the compiled probe executable, or nil."
  (let* ((root (file-name-as-directory (expand-file-name probe-root)))
         (local (expand-file-name "probe" root)))
    (cond
     ((file-executable-p local) local)
     ((executable-find probe-command) (executable-find probe-command))
     (t nil))))

(defun probe--compiled-command-or-error ()
  "Return the compiled probe executable or signal a user-facing error."
  (or (probe--compiled-command)
      (user-error "Compiled probe CLI not found; run `odin build cmd/probe -out:probe`")))

(defun probe--process-command (args)
  "Return a process command for probe ARGS."
  (cons (probe--compiled-command-or-error) args))

(defun probe--read-generated-file (path)
  "Return generated Odin from PATH, deleting PATH when possible."
  (when (and path (file-exists-p path))
    (unwind-protect
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))
      (ignore-errors
        (delete-file path)))))

(defun probe--prepare-buffer (name)
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

(defun probe--split-generated-output (text)
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

(defun probe--visible-output (stdout stderr show-generated)
  "Return (GENERATED . VISIBLE-OUTPUT) from STDOUT and STDERR."
  (let* ((split (and show-generated (probe--split-generated-output stdout)))
         (generated (car-safe split))
         (visible-stdout (if split (cdr split) stdout))
         (visible (string-trim
                   (concat visible-stdout
                           (unless (or (string-empty-p visible-stdout)
                                       (string-empty-p stderr))
                             "\n")
                           stderr))))
    (cons generated visible)))

(defun probe--show-inline-result (buffer beg end text exit-code)
  "Show TEXT inline in BUFFER after BEG and END."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (remove-overlays beg end 'probe-result-overlay t)
      (let* ((trimmed (string-trim text))
             (display-text (if (string-empty-p trimmed)
                               (format " %s<exit %s>" probe-inline-result-prefix exit-code)
                             (format " %s%s" probe-inline-result-prefix
                                     (replace-regexp-in-string "[\n\r\t ]+" " " trimmed))))
             (ov (make-overlay beg end)))
        (put-text-property 0 1 'cursor 0 display-text)
        (put-text-property 0 (length display-text) 'face
                           (if (zerop exit-code) 'shadow 'error)
                           display-text)
        (overlay-put ov 'probe-result-overlay t)
        (overlay-put ov 'priority 1000)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'after-string display-text)))))

(defun probe--message-result (text exit-code)
  "Show a concise minibuffer message for TEXT and EXIT-CODE."
  (let ((trimmed (string-trim text)))
    (message "%s"
             (cond
              ((not (zerop exit-code))
               (if (string-empty-p trimmed)
                   (format "probe exited %s" exit-code)
                 (replace-regexp-in-string "[\n\r\t ]+" " " trimmed)))
              ((string-empty-p trimmed) "")
              (t (replace-regexp-in-string "[\n\r\t ]+" " " trimmed))))))

(defun probe--insert-comment-result (buffer line-end text exit-code)
  "Insert TEXT as a // => result comment in BUFFER after LINE-END."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char line-end)
        (end-of-line)
        (if (eobp)
            (insert "\n")
          (forward-line 1))
        (while (and (not (eobp))
                    (looking-at-p "[[:space:]]*//[[:space:]]*=>"))
          (delete-region (line-beginning-position)
                         (min (point-max) (1+ (line-end-position)))))
        (let* ((trimmed (string-trim text))
               (single-line (replace-regexp-in-string "[\n\r\t ]+" " " trimmed)))
          (insert (format "// => %s%s\n"
                          (if (zerop exit-code) "" (format "<exit %s> " exit-code))
                          single-line)))))))

(defun probe--display-generated (generated)
  "Display GENERATED Odin in a separate buffer when non-nil."
  (when generated
    (let ((runner-buffer (probe--prepare-buffer probe-runner-buffer-name)))
      (with-current-buffer runner-buffer
        (let ((inhibit-read-only t))
          (insert generated)
          (when (fboundp 'odin-mode)
            (odin-mode))))
      (display-buffer runner-buffer))))

(defun probe--display-output (stdout stderr exit-code show-generated)
  "Display STDOUT and STDERR with EXIT-CODE.
When SHOW-GENERATED is non-nil, split generated Odin into a separate buffer when
possible."
  (let* ((visible-data (probe--visible-output stdout stderr show-generated))
         (generated (car visible-data))
         (visible (cdr visible-data))
         (result-buffer (probe--prepare-buffer probe-result-buffer-name)))
    (probe--display-generated generated)
    (with-current-buffer result-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ probe exited %s\n\n" exit-code))
        (unless (string-empty-p visible)
          (insert visible)
          (unless (string-suffix-p "\n" visible)
            (insert "\n")))
        (goto-char (point-min))))
    (display-buffer result-buffer)
    (message "probe exited %s" exit-code)))

(defun probe--run (command package code &optional no-print show internal display bounds save)
  "Run probe COMMAND for PACKAGE and CODE."
  (setq probe--last-source-buffer (current-buffer))
  (let* ((source-buffer (current-buffer))
         (bounds (or bounds
                     (and (memq display '(inline comment))
                          (cons (line-beginning-position) (line-end-position)))))
         (default-directory (file-name-as-directory (expand-file-name probe-root)))
         (compiled (probe--compiled-command-or-error))
         (generated-file (and show (make-temp-file "probe-generated-" nil ".odin")))
         (stdout-buffer (generate-new-buffer " *probe-stdout*"))
         (stderr-buffer (generate-new-buffer " *probe-stderr*"))
         (args (probe--cli-args command package code no-print (and show (not generated-file)) internal save generated-file)))
    (make-process
     :name "probe"
     :buffer stdout-buffer
     :stderr stderr-buffer
     :command (cons compiled args)
     :noquery t
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (let ((exit-code (process-exit-status process))
               (stdout (with-current-buffer stdout-buffer
                         (buffer-substring-no-properties (point-min) (point-max))))
               (stderr (with-current-buffer stderr-buffer
                         (buffer-substring-no-properties (point-min) (point-max))))
               (generated-from-file (probe--read-generated-file generated-file)))
           (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
           (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
           (pcase display
             ('inline
              (let* ((visible-data (probe--visible-output stdout stderr show))
                     (generated (or generated-from-file (car visible-data)))
                     (visible (cdr visible-data)))
                (probe--display-generated generated)
                (probe--show-inline-result source-buffer (car bounds) (cdr bounds) visible exit-code)
                (probe--message-result visible exit-code)))
             ('comment
              (let* ((visible-data (probe--visible-output stdout stderr show))
                     (generated (or generated-from-file (car visible-data)))
                     (visible (cdr visible-data)))
                (probe--display-generated generated)
                (probe--insert-comment-result source-buffer (cdr bounds) visible exit-code)
                (probe--message-result visible exit-code)))
             (_
              (if generated-from-file
                  (progn
                    (probe--display-generated generated-from-file)
                    (probe--display-output stdout stderr exit-code nil))
                (probe--display-output stdout stderr exit-code show))))))))))

(defun probe--run-store-command (args)
  "Run a probe store command with ARGS and display the result buffer."
  (let* ((default-directory (file-name-as-directory (expand-file-name probe-root)))
         (stdout-buffer (generate-new-buffer " *probe-store-stdout*"))
         (stderr-buffer (generate-new-buffer " *probe-store-stderr*")))
    (make-process
     :name "probe-store"
     :buffer stdout-buffer
     :stderr stderr-buffer
     :command (probe--process-command (cons "store" args))
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
           (probe--display-output stdout stderr exit-code nil)))))))

(defun probe-read-code ()
  "Read an Odin expression from the minibuffer, defaulting to symbol at point."
  (read-string "Odin expression: " (or (thing-at-point 'symbol t) "")))

(defun probe--strip-line-comment-prefix (text)
  "Strip Odin // comment prefixes from TEXT."
  (string-join
   (mapcar
    (lambda (line)
      (replace-regexp-in-string "\\`[[:space:]]*//[[:space:]]?" "" line))
    (split-string text "\n"))
   "\n"))

(defun probe--comment-line-p ()
  "Return non-nil when the current line starts with an Odin line comment."
  (save-excursion
    (beginning-of-line)
    (and (looking-at-p "[[:space:]]*//")
         (not (looking-at-p "[[:space:]]*//[[:space:]]*=>")))))

(defun probe--comment-block-bounds ()
  "Return bounds for the enclosing /* ... */ comment block around point."
  (let* ((cursor (point))
         (line-delimiter-p
          (save-excursion
            (beginning-of-line)
            (or (looking-at-p "[[:space:]]*/\\*[[:space:]]*$")
                (looking-at-p "[[:space:]]*\\*/[[:space:]]*$"))))
         (line-start (save-excursion (beginning-of-line) (point)))
         (line-end (save-excursion (end-of-line) (point)))
         (line-close-p
          (save-excursion
            (beginning-of-line)
            (looking-at-p "[[:space:]]*\\*/[[:space:]]*$")))
         (scan-end (if line-delimiter-p (line-end-position) cursor))
         (stack '())
         (line-close-bounds nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "/\\*\\|\\*/" scan-end t)
        (if (string= (match-string 0) "/*")
            (push (match-beginning 0) stack)
          (when stack
            (let ((closed (cons (pop stack) (match-end 0))))
              (when (and line-close-p
                         (>= (match-beginning 0) line-start)
                         (<= (match-end 0) line-end))
                (setq line-close-bounds closed)))))))
    (cond
     (line-close-p
      (or line-close-bounds
          (error "Point is not inside a /* ... */ comment block")))
     ((consp stack)
      (save-excursion
        (goto-char cursor)
        (unless (search-forward "*/" nil t)
          (error "Unterminated /* ... */ comment block around point"))
        (cons (car stack) (point))))
     (t
      (error "Point is not inside a /* ... */ comment block")))))

(defun probe--strip-comment-block-prefix (text)
  "Strip Odin /* ... */ comment markers from TEXT and normalize lines."
  (let* ((without-open
          (replace-regexp-in-string
           "\\`[[:space:]]*/\\*" "" text))
         (without-close
          (replace-regexp-in-string
           "\\*/[[:space:]]*\\'" "" without-open))
         (lines
          (mapcar
           (lambda (line)
             (replace-regexp-in-string "\\`[[:space:]]*\\*+[[:space:]]*" "" line))
           (split-string without-close "\n")))
         (without-results
          (string-join
           (seq-remove
            (lambda (line)
              (string-match-p "\\`[[:space:]]*//[[:space:]]*=>" line))
            lines)
           "\n")))
    (string-trim without-results)))

(defun probe--result-comment-line-p ()
  "Return non-nil when the current line is a probe // => result line."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[[:space:]]*//[[:space:]]*=>")))

(defun probe-comment-block-code ()
  "Return uncommented code from the enclosing /* ... */ comment block around point."
  (let* ((bounds (probe--comment-block-bounds))
         (text (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (text-no-markers (probe--strip-comment-block-prefix text)))
    (string-trim (probe--strip-line-comment-prefix text-no-markers))))

(defun probe-current-line-code ()
  "Return code from the current line, stripping a leading // if present."
  (let ((line (string-trim
               (buffer-substring-no-properties
                (line-beginning-position)
                (line-end-position)))))
    (string-trim (probe--strip-line-comment-prefix line))))

(defun probe--call-bounds-before-point ()
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

(defun probe--atom-bounds-before-point ()
  "Return bounds of the Odin atom ending at or before point."
  (save-excursion
    (skip-chars-backward " \t\n")
    (let ((end (point)))
      (skip-chars-backward "A-Za-z0-9_\\.$")
      (when (< (point) end)
        (cons (point) end)))))

(defun probe-current-line-call-or-atom-unit ()
  "Return current call/atom before point, falling back to current line."
  (if-let ((bounds (or (probe--call-bounds-before-point)
                       (probe--atom-bounds-before-point))))
      (cons (buffer-substring-no-properties (car bounds) (cdr bounds)) bounds)
    (cons (probe-current-line-code)
          (cons (line-beginning-position) (line-end-position)))))

(defun probe-current-line-bounds ()
  "Return bounds of the current line."
  (cons (line-beginning-position) (line-end-position)))

(defun probe-current-unit ()
  "Return (CODE . BOUNDS) for the current probe unit.
When point is inside a `/* ... */` block, the unit is the whole block.
Otherwise prefer the parenthesized call ending before point, falling back to the
atom before point, then the current line."
  (if-let ((bounds (ignore-errors (probe--comment-block-bounds))))
      (cons (probe-comment-block-code) bounds)
    (probe-current-line-call-or-atom-unit)))

;;;###autoload
(defun probe-run-expression (code)
  "Run Odin expression CODE in a generated runner for the current package."
  (interactive (list (probe-read-code)))
  (probe--run "run"
                 (probe-package-directory)
                 code
                 probe-default-no-print
                 probe-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun probe-run-expression-save (code name)
  "Run Odin expression CODE and save successful stdout to store slot NAME."
  (interactive (list (probe-read-code)
                     (read-string "Save result as: ")))
  (probe--run "run"
                 (probe-package-directory)
                 code
                 probe-default-no-print
                 probe-show-generated
                 nil
                 'buffer
                 nil
                 name))

;;;###autoload
(defun probe-check-expression (code)
  "Check Odin expression CODE in a generated runner for the current package."
  (interactive (list (probe-read-code)))
  (probe--run "check"
                 (probe-package-directory)
                 code
                 probe-default-no-print
                 probe-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun probe-store-save (name value)
  "Save VALUE to probe store slot NAME for the current package."
  (interactive (list (read-string "Store name: ")
                     (read-string "Value: ")))
  (probe--run-store-command (list "save" (probe-package-directory) name value)))

;;;###autoload
(defun probe-store-load (name)
  "Load probe store slot NAME for the current package into `*Probe*'."
  (interactive (list (read-string "Load store name: ")))
  (probe--run-store-command (list "load" (probe-package-directory) name)))

;;;###autoload
(defun probe-store-list ()
  "List probe store slots for the current package."
  (interactive)
  (probe--run-store-command (list "list" (probe-package-directory))))

;;;###autoload
(defun probe-store-remove (name)
  "Remove probe store slot NAME for the current package."
  (interactive (list (read-string "Remove store name: ")))
  (probe--run-store-command (list "rm" (probe-package-directory) name)))

;;;###autoload
(defun probe-store-path ()
  "Show the probe store path for the current package."
  (interactive)
  (probe--run-store-command (list "path" (probe-package-directory))))

;;;###autoload
(defun probe-run-line (&optional no-print)
  "Run the current probe unit and show the result inline.
If point is inside a scratch `/* ... */` block, run the whole block.
Otherwise run the current line. This is intended for scratch blocks such as:

  /*
  add(5,2)
  */

With prefix argument NO-PRINT, treat the line as statements."
  (interactive "P")
  (let ((unit (probe-current-unit)))
    (probe--run "run"
                   (probe-package-directory)
                   (car unit)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'inline
                   (cdr unit))))

;;;###autoload
(defun probe-run-whole-line (&optional no-print)
  "Run the whole current line and show the result inline.
This intentionally ignores point-sensitive call/atom selection."
  (interactive "P")
  (probe--run "run"
                 (probe-package-directory)
                 (probe-current-line-code)
                 (or no-print probe-default-no-print)
                 probe-show-generated
                 t
                 'inline
                 (probe-current-line-bounds)))

;;;###autoload
(defun probe-insert-line-result (&optional no-print)
  "Run the current probe unit and insert the result as a // => comment."
  (interactive "P")
  (let ((unit (probe-current-unit)))
    (probe--run "run"
                   (probe-package-directory)
                   (car unit)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'comment
                   (cdr unit))))

;;;###autoload
(defun probe-popup-line (&optional no-print)
  "Run the current probe unit and show output in the probe result buffer."
  (interactive "P")
  (let ((unit (probe-current-unit)))
    (probe--run "run"
                   (probe-package-directory)
                   (car unit)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'buffer
                   (cdr unit))))

;;;###autoload
(defun probe-run-line-save (&optional no-print)
  "Run the current probe unit and save successful stdout to a named store slot."
  (interactive "P")
  (let ((unit (probe-current-unit))
        (name (read-string "Save result as: ")))
    (probe--run "run"
                   (probe-package-directory)
                   (car unit)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'buffer
                   (cdr unit)
                   name)))

;;;###autoload
(defun probe-insert-comment-block-result (&optional no-print)
  "Run the current `/* ... */` comment block and insert a // => result comment."
  (interactive "P")
  (let ((bounds (probe--comment-block-bounds)))
    (probe--run "run"
                   (probe-package-directory)
                   (probe-comment-block-code)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'comment
                   bounds)))

;;;###autoload
(defun probe-check-line (&optional no-print)
  "Check the current line as Odin code inside the current package.
If the line starts with `//`, strip the comment prefix first."
  (interactive "P")
  (probe--run "check"
                 (probe-package-directory)
                 (probe-current-line-code)
                 (or no-print probe-default-no-print)
                 probe-show-generated
                 t
                 'buffer))

;;;###autoload
(defun probe-run-region (start end &optional no-print)
  "Run the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (probe--run "run"
                 (probe-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print probe-default-no-print)
                 probe-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun probe-check-region (start end &optional no-print)
  "Check the selected Odin expression or statement region.
With prefix argument NO-PRINT, treat the region as statements."
  (interactive "r\nP")
  (probe--run "check"
                 (probe-package-directory)
                 (buffer-substring-no-properties start end)
                 (or no-print probe-default-no-print)
                 probe-show-generated
                 nil
                 'buffer))

;;;###autoload
(defun probe-run-comment-block (&optional no-print)
  "Run uncommented code from the enclosing `/* ... */` comment block.
With prefix argument NO-PRINT, treat the code as statements.

This is the Odin analogue of keeping exploratory calls in a Clojure
`(comment ...)` form:

  /*
  target.answer()
  target.some_proc(1, 2)
  */"
  (interactive "P")
  (let ((bounds (probe--comment-block-bounds)))
    (probe--run "run"
                   (probe-package-directory)
                   (probe-comment-block-code)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'inline
                   bounds)))

;;;###autoload
(defun probe-check-comment-block (&optional no-print)
  "Check uncommented code from the enclosing `/* ... */` comment block.
With prefix argument NO-PRINT, treat the code as statements."
  (interactive "P")
  (let ((bounds (probe--comment-block-bounds)))
    (probe--run "check"
                   (probe-package-directory)
                   (probe-comment-block-code)
                   (or no-print probe-default-no-print)
                   probe-show-generated
                   t
                   'buffer
                   bounds)))

(defun probe--command-buffer (directory)
  "Return the command output buffer for DIRECTORY."
  (let ((buffer (get-buffer-create probe-result-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ cd %s\n" (abbreviate-file-name directory))))
      (special-mode)
      (setq-local truncate-lines nil)
      (setq-local word-wrap t)
      (visual-line-mode 1))
    buffer))

(defun probe--compact-command-output (stdout stderr)
  "Return compact one-line command output from STDOUT and STDERR."
  (let ((output (string-trim
                 (concat stdout
                         (unless (or (string-empty-p stdout)
                                     (string-empty-p stderr))
                           "\n")
                         stderr))))
    (replace-regexp-in-string "[\n\r\t ]+" " " output)))

(defun probe--run-odin-command (directory command &optional on-success show-output-on-success)
  "Run Odin COMMAND in DIRECTORY.
Show `probe-result-buffer-name' only on failure. Run ON-SUCCESS on exit 0.
When SHOW-OUTPUT-ON-SUCCESS is non-nil, show command output in the minibuffer."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (buffer (probe--command-buffer directory))
         (stdout-buffer (generate-new-buffer " *probe-command-stdout*"))
         (stderr-buffer (generate-new-buffer " *probe-command-stderr*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "$ %s\n\n" command))))
    (let ((default-directory directory))
      (make-process
       :name "probe-command"
       :buffer stdout-buffer
       :stderr stderr-buffer
       :command (list shell-file-name shell-command-switch command)
       :connection-type 'pipe
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
             (with-current-buffer buffer
               (let ((inhibit-read-only t))
                 (goto-char (point-max))
                 (unless (string-empty-p stdout)
                   (insert stdout)
                   (unless (string-suffix-p "\n" stdout) (insert "\n")))
                 (unless (string-empty-p stderr)
                   (insert stderr)
                   (unless (string-suffix-p "\n" stderr) (insert "\n")))))
             (if (zerop exit-code)
                 (progn
                   (let ((compact-output (probe--compact-command-output stdout stderr)))
                     (message "%s"
                              (if (and show-output-on-success
                                       (not (string-empty-p compact-output)))
                                  compact-output
                                (format "%s: ok" command))))
                   (when on-success (funcall on-success)))
               (display-buffer buffer)
               (message "%s: failed" command)))))))))

(defun probe--odin-in-package (command &optional on-success show-output-on-success)
  "Run Odin COMMAND in the current package directory."
  (probe--run-odin-command (probe-package-directory) command on-success show-output-on-success))

(defun probe--odin-in-project (command &optional on-success show-output-on-success)
  "Run Odin COMMAND in the current project directory."
  (probe--run-odin-command (probe-project-directory) command on-success show-output-on-success))

;;;###autoload
(defun probe-run-package ()
  "Run `odin run .' in the current Odin package directory."
  (interactive)
  (probe--odin-in-package "odin run ."))

;;;###autoload
(defun probe-build-package ()
  "Run `odin build .' in the current Odin package directory."
  (interactive)
  (probe--odin-in-package
   "odin build ."
   (when probe-test-after-build
     (lambda () (probe-test-package)))))

;;;###autoload
(defun probe-check-package ()
  "Run `odin check .' in the current Odin package directory."
  (interactive)
  (probe--odin-in-package "odin check ."))

;;;###autoload
(defun probe-test-package ()
  "Run `odin test .' in the current Odin package directory."
  (interactive)
  (probe--odin-in-package probe-test-command nil t))

;;;###autoload
(defun probe-run-project ()
  "Run `odin run .' in the current Odin project directory."
  (interactive)
  (probe--odin-in-project "odin run ."))

;;;###autoload
(defun probe-build-project ()
  "Run `odin build .' in the current Odin project directory."
  (interactive)
  (probe--odin-in-project "odin build ."))

;;;###autoload
(defun probe-check-project ()
  "Run `odin check .' in the current Odin project directory."
  (interactive)
  (probe--odin-in-project "odin check ."))

;;;###autoload
(defun probe-test-project ()
  "Run `odin test .' in the current Odin project directory."
  (interactive)
  (probe--odin-in-project probe-test-command nil t))

;;;###autoload
(defun probe-toggle-test-after-build ()
  "Toggle running `odin test .' after successful package builds."
  (interactive)
  (setq probe-test-after-build (not probe-test-after-build))
  (message "probe-test-after-build: %s" probe-test-after-build))

;;;###autoload
(defun probe-run-proc (name args)
  "Run target proc NAME with raw Odin ARGS."
  (interactive
   (list (read-string "Proc: " (or (thing-at-point 'symbol t) ""))
         (read-string "Args: ")))
  (probe-run-expression (format "target.%s(%s)" name args)))

;;;###autoload
(defun probe-run-proc-no-args ()
  "Run the target proc at point with no arguments."
  (interactive)
  (let ((name (or (thing-at-point 'symbol t)
                  (read-string "Proc: "))))
    (probe-run-expression (format "target.%s()" name))))

;;;###autoload
(defun probe-toggle-show-generated ()
  "Toggle generated Odin display for probe commands."
  (interactive)
  (setq probe-show-generated (not probe-show-generated))
  (message "probe-show-generated: %s" probe-show-generated))

;;;###autoload
(defun probe-switch-to-result ()
  "Display the probe result buffer."
  (interactive)
  (pop-to-buffer probe-result-buffer-name))

;;;###autoload
(defun probe-switch-to-source ()
  "Return to the most recent probe source buffer."
  (interactive)
  (if (buffer-live-p probe--last-source-buffer)
      (pop-to-buffer probe--last-source-buffer)
    (message "No probe source buffer recorded.")))

(defun probe-setup-odin-mode-keys ()
  "Install probe keybindings in the current Odin buffer."
  (probe--enable-inline-result-clearing)
  (local-set-key (kbd "C-c C-e") #'probe-run-line)
  (local-set-key (kbd "C-c C-p") #'probe-popup-line)
  (local-set-key (kbd "C-c C-i") #'probe-insert-line-result)
  (local-set-key (kbd "C-c C-r") #'probe-run-region)
  (local-set-key (kbd "C-c C-c") #'probe-run-whole-line)
  (local-set-key (kbd "C-c C-x") #'probe-run-comment-block)
  (local-set-key (kbd "C-c C-k") #'probe-check-expression)
  (local-set-key (kbd "C-c C-a") #'probe-run-package)
  (local-set-key (kbd "C-c C-b") #'probe-build-package)
  (local-set-key (kbd "C-c C-v") #'probe-check-package)
  (local-set-key (kbd "C-c C-t") #'probe-test-package)
  (local-set-key (kbd "C-c C-s") #'probe-toggle-show-generated)
  (local-set-key (kbd "C-c C-z") #'probe-switch-to-result))

(provide 'probe)

;;; probe.el ends here
