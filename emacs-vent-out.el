;;; emacs-vent-out.el --- Emacs -> Tezcatl event/context bridge  -*- lexical-binding: t; -*-

;; Phase 1 (design doc Part C): single client, 127.0.0.1 only, immediate send.
;; `emacs-vent-in-function' is the Phase 5 (vent-in) plug-in point.
;;
;; Context rework (2026-08-28): `context' is no longer a per-command state
;; snapshot flushed together with events. It is now a lightweight, flush-exempt
;; notification of *where vent-in input currently goes* (the selected window of
;; the selected frame, or the active minibuffer), sent only when that target
;; changes. See `emacs-vent--maybe-send-context'. This supersedes the
;; "Event/Context flushed as one unit" wording in design doc A-7 / ver0
;; §10-11,19.

(require 'websocket)
(require 'json)
(require 'compile)

(defgroup emacs-vent nil
  "Bridge between Emacs and an external UI (Tezcatl) over a local WebSocket."
  :group 'tools
  :prefix "emacs-vent-")

(defcustom emacs-vent-port 4000
  "Port emacs-vent-out listens on. Always bound to 127.0.0.1 only."
  :type 'integer
  :group 'emacs-vent)

(defcustom emacs-vent-out-filters '()
  "Functions run on an outgoing message plist before it is sent.
Each is called with the message and must return a message plist to
keep passing it on, or nil to drop it. Default is pass-through."
  :type 'hook
  :group 'emacs-vent)

(defcustom emacs-vent-source-function #'emacs-vent-source-default
  "Function mapping a command symbol to a source string, or nil."
  :type 'function
  :group 'emacs-vent)

(defcustom emacs-vent-serialize-function #'json-serialize
  "Function turning a message plist into bytes for sending."
  :type 'function
  :group 'emacs-vent)

(defcustom emacs-vent-in-function nil
  "Function called with (WS FRAME) for each incoming websocket message, or nil.
Left nil in Phase 1 (input ignored). `emacs-vent-in' sets this to its own
handler when loaded, so Phase 1's server plumbing needs no further changes
to support Phase 5 (design doc vent-in v0.2, in-filters position at receipt)."
  :type '(choice (const nil) function)
  :group 'emacs-vent)

(defvar emacs-vent--server nil)
(defvar emacs-vent--client nil
  "The single accepted client connection, or nil (Phase 1: one only).")

(defvar emacs-vent--id-table (make-hash-table :test 'eq :weakness 'key)
  "Maps live window/frame objects to a stable string id for this session.")
(defvar emacs-vent--id-counters nil
  "Alist of (PREFIX . LAST-N) backing `emacs-vent--id'.")
(defvar emacs-vent--last-target nil
  "Last (BUFFER-NAME WINDOW-ID FRAME-ID) sent as a context message, or nil.")

(defconst emacs-vent-log-buffer-name "*emacs-vent-log*")

(defmacro emacs-vent--protected (&rest body)
  "Run BODY, logging and swallowing any error instead of propagating it.
Required by design doc C-8: a hook error must never reach Emacs."
  `(condition-case err
       (progn ,@body)
     (error (emacs-vent--log "error: %S" err) nil)))

(defun emacs-vent--log (fmt &rest args)
  (with-current-buffer (get-buffer-create emacs-vent-log-buffer-name)
    (goto-char (point-max))
    (insert (apply #'format fmt args) "\n")))

(defun emacs-vent-source-default (symbol)
  "Best-effort source name for SYMBOL via `symbol-file'. See design doc B-1."
  (when symbol
    (let ((file (ignore-errors (symbol-file symbol))))
      (when file
        (file-name-sans-extension (file-name-nondirectory file))))))

(defun emacs-vent--current-source ()
  (emacs-vent--protected (funcall emacs-vent-source-function this-command)))

(defun emacs-vent--send (plist)
  "Run PLIST through `emacs-vent-out-filters', then send to the client.
Drops silently if no client is connected (design doc C-8)."
  (when emacs-vent--client
    (emacs-vent--protected
     (let ((msg plist))
       (catch 'emacs-vent-dropped
         (dolist (filter emacs-vent-out-filters)
           (setq msg (funcall filter msg))
           (unless msg (throw 'emacs-vent-dropped nil)))
         (websocket-send-text
          emacs-vent--client
          (funcall emacs-vent-serialize-function msg)))))))

(defun emacs-vent--send-event (type &optional content source)
  ;; `json-serialize' treats a bare Lisp nil value as an empty object, not
  ;; JSON null, so an unresolved source must be spelled out as `:null'
  ;; explicitly (design doc A-5: "解決に失敗した場合は null を送る").
  (emacs-vent--send
   (append (list :kind "event"
                 :source (or source (emacs-vent--current-source) :null)
                 :type type)
           (when content (list :content content)))))

(defun emacs-vent--id (object prefix)
  "Return a stable \"PREFIX-N\" string id for OBJECT (a window or frame),
assigning one on first sight. OBJECT is held weakly, so dead windows and
frames do not accumulate."
  (or (gethash object emacs-vent--id-table)
      (let* ((cell (or (assoc prefix emacs-vent--id-counters)
                       (car (push (cons prefix 0) emacs-vent--id-counters))))
             (n (setcdr cell (1+ (cdr cell)))))
        (puthash object (format "%s-%d" prefix n) emacs-vent--id-table))))

(defun emacs-vent--current-target ()
  "The current vent-in injection target as (BUFFER-NAME WINDOW-ID FRAME-ID):
the selected window of the selected frame, or the active minibuffer."
  (let ((win (selected-window)))
    (list (buffer-name (window-buffer win))
          (emacs-vent--id win "win")
          (emacs-vent--id (selected-frame) "frame"))))

(defun emacs-vent--context-plist (target)
  (list :kind "context"
        :buffer-name (nth 0 target)
        :window (nth 1 target)
        :frame (nth 2 target)))

(defun emacs-vent--send-context-now ()
  "Unconditionally send the current target as a context message.
Used on client connect to establish the initial target (ver0 §10)."
  (emacs-vent--protected
   (let ((target (emacs-vent--current-target)))
     (setq emacs-vent--last-target target)
     (emacs-vent--send (emacs-vent--context-plist target)))))

(defun emacs-vent--maybe-send-context (&optional _frame)
  "Send a context message iff the injection target changed since the last send.
Runs from `window-selection-change-functions' (hence the ignored FRAME arg),
`window-buffer-change-functions', and `minibuffer-setup-hook'. Context is
applied by the client on arrival -- it is not part of the flush contract."
  (emacs-vent--protected
   (let ((target (emacs-vent--current-target)))
     (unless (equal target emacs-vent--last-target)
       (setq emacs-vent--last-target target)
       (emacs-vent--send (emacs-vent--context-plist target))))))

;;;###autoload
(defun emacs-vent-send-context ()
  "Unconditionally (re-)send the current vent-in target as a context message.
Unlike `emacs-vent--maybe-send-context', this sends even when the target is
unchanged. A client that attached after the initial `hello'/`context'
handshake -- e.g. a browser tab reaching emacs-vent through the Phase 7
relay, which multiplexes many tabs onto this one client slot -- calls this
\(delivered as an `M-:' input) to obtain the current target. No-op when no
client is connected."
  (interactive)
  (emacs-vent--send-context-now))

(defun emacs-vent--send-flush ()
  (emacs-vent--send (list :kind "flush")))

;; --- Event sources (design doc C-4) ---

(defun emacs-vent--post-command ()
  "Command-boundary flush for batched events (design doc A-7 / C-7 step 6).
Context is sent separately now (`emacs-vent--maybe-send-context'), not here."
  (emacs-vent--protected
   (emacs-vent--send-flush)))

(defun emacs-vent--message-advice (orig-fn fmt &rest args)
  (let ((result (apply orig-fn fmt args)))
    (when (and emacs-vent-mode fmt)
      (emacs-vent--protected
       (emacs-vent--send-event "message" (apply #'format-message fmt args))))
    result))

(defun emacs-vent--after-change (_beg _end _len)
  ;; buffer.changed is notification-only: no content (design doc A-5/B-4).
  (emacs-vent--protected (emacs-vent--send-event "buffer.changed")))

(defun emacs-vent--compilation-start (_proc)
  (emacs-vent--protected
   (emacs-vent--send-event "compilation.started" nil "compilation")
   (emacs-vent--send-flush)))

(defun emacs-vent--compilation-filter ()
  (emacs-vent--protected
   (emacs-vent--send-event
    "compilation.output"
    (buffer-substring-no-properties compilation-filter-start (point))
    "compilation")
   (emacs-vent--send-flush)))

(defun emacs-vent--compilation-finish (_buffer msg)
  (emacs-vent--protected
   (emacs-vent--send-event "compilation.finished" (string-trim msg) "compilation")
   (emacs-vent--send-flush)))

;; --- Server lifecycle ---

(defun emacs-vent--on-open (ws)
  (if emacs-vent--client
      ;; Phase 1 accepts a single connection only (design doc C-2).
      (websocket-close ws)
    (setq emacs-vent--client ws)
    (emacs-vent--send (list :kind "hello"))
    ;; Establish the initial injection target right away (ver0 §10).
    (emacs-vent--send-context-now)))

(defun emacs-vent--on-message (ws frame)
  (when emacs-vent-in-function
    (funcall emacs-vent-in-function ws frame)))

(defun emacs-vent--on-close (ws)
  (when (eq ws emacs-vent--client)
    (setq emacs-vent--client nil)))

;;;###autoload
(define-minor-mode emacs-vent-mode
  "Serve Emacs events/context to Tezcatl over a local WebSocket.
Implements Part C (Phase 1 minimal form) of the emacs-vent-out design doc."
  :global t
  :group 'emacs-vent
  (if emacs-vent-mode
      (emacs-vent--start)
    (emacs-vent--stop)))

(defun emacs-vent--start ()
  (when emacs-vent--server
    (emacs-vent--stop))
  (setq emacs-vent--server
        (websocket-server
         emacs-vent-port
         :host 'local
         :on-open #'emacs-vent--on-open
         :on-message #'emacs-vent--on-message
         :on-close #'emacs-vent--on-close))
  (add-hook 'post-command-hook #'emacs-vent--post-command)
  (add-hook 'window-selection-change-functions #'emacs-vent--maybe-send-context)
  (add-hook 'window-buffer-change-functions #'emacs-vent--maybe-send-context)
  (add-hook 'minibuffer-setup-hook #'emacs-vent--maybe-send-context)
  (add-hook 'after-change-functions #'emacs-vent--after-change)
  (add-hook 'compilation-start-hook #'emacs-vent--compilation-start)
  (add-hook 'compilation-filter-hook #'emacs-vent--compilation-filter)
  (add-hook 'compilation-finish-functions #'emacs-vent--compilation-finish)
  (advice-add 'message :around #'emacs-vent--message-advice)
  (emacs-vent--log "started on 127.0.0.1:%s" emacs-vent-port))

(defun emacs-vent--stop ()
  (remove-hook 'post-command-hook #'emacs-vent--post-command)
  (remove-hook 'window-selection-change-functions #'emacs-vent--maybe-send-context)
  (remove-hook 'window-buffer-change-functions #'emacs-vent--maybe-send-context)
  (remove-hook 'minibuffer-setup-hook #'emacs-vent--maybe-send-context)
  (remove-hook 'after-change-functions #'emacs-vent--after-change)
  (setq emacs-vent--last-target nil)
  (remove-hook 'compilation-start-hook #'emacs-vent--compilation-start)
  (remove-hook 'compilation-filter-hook #'emacs-vent--compilation-filter)
  (remove-hook 'compilation-finish-functions #'emacs-vent--compilation-finish)
  (advice-remove 'message #'emacs-vent--message-advice)
  (when emacs-vent--client
    (websocket-close emacs-vent--client)
    (setq emacs-vent--client nil))
  (when emacs-vent--server
    (websocket-server-close emacs-vent--server)
    (setq emacs-vent--server nil))
  (emacs-vent--log "stopped"))

(provide 'emacs-vent-out)
;;; emacs-vent-out.el ends here
