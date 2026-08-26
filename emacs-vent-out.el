;;; emacs-vent-out.el --- Emacs -> Tezcatl event/context bridge  -*- lexical-binding: t; -*-

;; Phase 1 (design doc Part C) only: no vent-in, no capability negotiation
;; content, no batching. Immediate send, single client, 127.0.0.1 only.

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

(defun emacs-vent--send-context ()
  (emacs-vent--send
   (list :kind "context"
         :buffer-name (buffer-name)
         :major-mode (symbol-name major-mode)
         :point (point)
         :read-only (if buffer-read-only t :false))))

(defun emacs-vent--send-flush ()
  (emacs-vent--send (list :kind "flush")))

;; --- Event sources (design doc C-4) ---

(defun emacs-vent--post-command ()
  "The one command-boundary flush point (design doc A-7 / C-7 step 6)."
  (emacs-vent--protected
   (emacs-vent--send-context)
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
    (emacs-vent--send (list :kind "hello"))))

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
  (add-hook 'after-change-functions #'emacs-vent--after-change)
  (add-hook 'compilation-start-hook #'emacs-vent--compilation-start)
  (add-hook 'compilation-filter-hook #'emacs-vent--compilation-filter)
  (add-hook 'compilation-finish-functions #'emacs-vent--compilation-finish)
  (advice-add 'message :around #'emacs-vent--message-advice)
  (emacs-vent--log "started on 127.0.0.1:%s" emacs-vent-port))

(defun emacs-vent--stop ()
  (remove-hook 'post-command-hook #'emacs-vent--post-command)
  (remove-hook 'after-change-functions #'emacs-vent--after-change)
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
