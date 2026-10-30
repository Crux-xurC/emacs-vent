;;; emacs-vent-out.el --- Emacs -> Tezcatl event/context bridge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Crux-xurC

;; Author: Crux-xurC
;; URL: https://github.com/Crux-xurC/emacs-vent
;; Package-Requires: ((emacs "27.1") (websocket "1.12"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `emacs-vent-mode' serves a WebSocket on 127.0.0.1 (`emacs-vent-port')
;; for one client -- Tezcatl's relay, or any tool that speaks the same JSON.
;; It sends:
;;
;;   hello    once, when the client connects
;;   context  where key input goes now (the selected window of the selected
;;            frame, or the active minibuffer): on connect, and whenever it
;;            changes; never batched (see `emacs-vent--maybe-send-context')
;;   event    something that happened: `message', `buffer.changed',
;;            `compilation.started' / `.output' / `.finished'
;;   flush    the end of a command: the events since the last flush belong
;;            to that command
;;
;; Incoming messages go to `emacs-vent-in-function', which `emacs-vent-in'
;; sets.  A connection carrying an Origin header (a browser) is refused, and
;; so is a second client while one is connected.

;;; Code:

(require 'websocket)
(require 'json)
(require 'compile)
(require 'subr-x)                       ; `string-trim' before Emacs 29

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
When nil, incoming messages are ignored.  Loading `emacs-vent-in' sets this
to its own handler, so the server here needs no change to take input."
  :type '(choice (const nil) function)
  :group 'emacs-vent)

(defvar emacs-vent--server nil)
(defvar emacs-vent--client nil
  "The single accepted client connection, or nil (only one is accepted).")

(defvar emacs-vent--id-table (make-hash-table :test 'eq :weakness 'key)
  "Maps live window/frame objects to a stable string id for this session.")
(defvar emacs-vent--id-counters nil
  "Alist of (PREFIX . LAST-N) backing `emacs-vent--id'.")
(defvar emacs-vent--last-target nil
  "Last (BUFFER-NAME WINDOW-ID FRAME-ID) sent as a context message, or nil.")

(defcustom emacs-vent-log-directory
  (expand-file-name "emacs-vent"
                    (let ((x (getenv "XDG_STATE_HOME")))
                      (if (and x (file-name-absolute-p x)) x "~/.local/state")))
  "Where emacs-vent writes its log, one file per start of Emacs.
`log.txt' is this Emacs's; the one before it is kept as `log.1.txt' (the
log of a run that went down is there to read), and older ones go."
  :type 'directory
  :group 'emacs-vent)

(defvar emacs-vent--log-rotated nil
  "Non-nil once this Emacs has moved the previous run's log aside.")

(defun emacs-vent-log-file ()
  "This Emacs's log file."
  (expand-file-name "log.txt" emacs-vent-log-directory))

(defmacro emacs-vent--protected (&rest body)
  "Run BODY, logging and swallowing any error instead of propagating it.
A hook error must never reach Emacs's own command execution."
  `(condition-case err
       (progn ,@body)
     (error (emacs-vent--log "error: %S" err) nil)))

(defun emacs-vent--rotate-log ()
  "Once per Emacs: the previous run's log becomes `log.1.txt' (the one
before that goes), and this run starts a new `log.txt'."
  (unless emacs-vent--log-rotated
    (setq emacs-vent--log-rotated t)
    (ignore-errors
      (make-directory emacs-vent-log-directory t)
      (let ((cur (emacs-vent-log-file))
            (prev (expand-file-name "log.1.txt" emacs-vent-log-directory)))
        (when (file-exists-p cur)
          (rename-file cur prev t))))))

(defun emacs-vent--log (fmt &rest args)
  "Append one line to this Emacs's log file (`emacs-vent-log-file').
Written from a string, so no buffer changes (no `buffer.changed' event) and
nothing is kept in memory; `silent' keeps `write-region' from messaging (a
message is itself sent on). A log that cannot be written is let go."
  (ignore-errors
    (emacs-vent--rotate-log)
    (write-region (concat (format-time-string "%F %T ") (apply #'format fmt args) "\n")
                  nil (emacs-vent-log-file) t 'silent)))

(defun emacs-vent-source-default (symbol)
  "Best-effort source name for SYMBOL via `symbol-file': the file it was
defined in, without directory or extension (e.g. \"simple\")."
  (when symbol
    (let ((file (ignore-errors (symbol-file symbol))))
      (when file
        (file-name-sans-extension (file-name-nondirectory file))))))

(defun emacs-vent--current-source ()
  (emacs-vent--protected (funcall emacs-vent-source-function this-command)))

(defun emacs-vent--utf8 (s)
  "Return string S as clean UTF-8 multibyte text, or S unchanged if it is
already fine (or not a string).

`json-serialize' signals `wrong-type-argument json-value-p' -- which
`emacs-vent--protected' then swallows, so the whole message silently never
reaches the client -- on two kinds of string:

  * a unibyte string carrying a byte >= #x80.  The raw UTF-8 that
    `json-serialize' itself returns is exactly this, and Tezcatl's resolver
    feeds it straight back via
    `(message \"tez:%s ok %s\" corr (json-serialize VALUE))'.  So any
    non-ASCII `M-:' result -- a kanji path in an `ok' payload, the curly
    quotes in nearly every built-in Emacs error string on the `err' path --
    would never produce a `message' event, and the resolver would time out
    with a misleading \"no tez: line\" instead of the real answer.

  * a multibyte string carrying a raw eight-bit byte (#x3FFF80..#x3FFFFF),
    which is what `format' / `format-message' produce when such a unibyte
    string is spliced into a *non-ASCII* format string.

Reinterpreting the bytes as UTF-8 fixes both.  A clean string is left
untouched -- the check is one C-level `string-match-p'."
  (if (and (stringp s)
           (if (multibyte-string-p s)
               (string-match-p "[\x3FFF80-\x3FFFFF]" s)
             (string-match-p "[\x80-\xFF]" s)))
      (decode-coding-string (encode-coding-string s 'utf-8) 'utf-8)
    s))

(defun emacs-vent--sanitize (x)
  "Recursively run every string inside X (a message plist, or a nested
list / vector value within one) through `emacs-vent--utf8'.
Belt-and-suspenders for `emacs-vent--send': `emacs-vent--message-advice'
already decodes its own args, so in practice this only catches a raw-byte
string introduced by an `emacs-vent-out-filters' entry or a future caller."
  (cond
   ((stringp x) (emacs-vent--utf8 x))
   ((and (consp x) (proper-list-p x)) (mapcar #'emacs-vent--sanitize x))
   ((vectorp x) (apply #'vector (mapcar #'emacs-vent--sanitize x)))
   (t x)))

(defun emacs-vent--send (plist)
  "Run PLIST through `emacs-vent-out-filters', then send to the client.
Drops silently if no client is connected.

String values pass through `emacs-vent--sanitize' first so a unibyte or
raw-byte string (see `emacs-vent--utf8') cannot make
`emacs-vent-serialize-function' signal.  A serialize failure that survives
that is logged with the message's `:kind'/`:type' and a content preview,
so the log tells which message was lost."
  (when emacs-vent--client
    (emacs-vent--protected
     (let ((msg plist))
       (catch 'emacs-vent-dropped
         (dolist (filter emacs-vent-out-filters)
           (setq msg (funcall filter msg))
           (unless msg (throw 'emacs-vent-dropped nil)))
         (setq msg (emacs-vent--sanitize msg))
         (let ((text (condition-case err
                         (funcall emacs-vent-serialize-function msg)
                       (error
                        (emacs-vent--log
                         "drop: serialize failed (kind=%S type=%S): %S -- content=%.160S"
                         (plist-get msg :kind) (plist-get msg :type)
                         err (plist-get msg :content))
                        (throw 'emacs-vent-dropped nil)))))
           (websocket-send-text emacs-vent--client text)))))))

(defun emacs-vent--send-event (type &optional content source)
  ;; `json-serialize' treats a bare Lisp nil value as an empty object, not
  ;; JSON null, so an unresolved source must be spelled out as `:null'
  ;; explicitly (an unresolved source is sent as null).
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
Used on client connect to establish the initial target."
  (emacs-vent--protected
   (let ((target (emacs-vent--current-target)))
     (setq emacs-vent--last-target target)
     (emacs-vent--send (emacs-vent--context-plist target)))))

(defun emacs-vent--maybe-send-context (&optional _frame)
  "Send a context message iff the injection target changed since the last send.
Runs from `window-selection-change-functions' (hence the ignored FRAME arg),
`window-buffer-change-functions', `minibuffer-setup-hook', and
`post-command-hook' (a catch-all safety net: some exits -- e.g. aborting a
minibuffer read with \\[keyboard-quit] -- are not reliably reported by any of
the other three; `minibuffer-exit-hook' cannot substitute for this because it
runs before the minibuffer window is deselected, so `emacs-vent--current-target'
would still read the minibuffer and the diff guard below would suppress the
send). The diff guard makes the extra `post-command-hook' call cheap: it only
ever sends when something actually changed, so this does not turn context
into a per-command message the way `emacs-vent--post-command' is. Context is
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
handshake -- e.g. a browser tab reaching emacs-vent through Tezcatl's
relay, which multiplexes many tabs onto this one client slot -- calls this
\(delivered as an `M-:' input) to obtain the current target. No-op when no
client is connected."
  (interactive)
  (emacs-vent--send-context-now))

(defun emacs-vent--send-flush ()
  (emacs-vent--send (list :kind "flush")))

;; --- Event sources ---

(defun emacs-vent--post-command ()
  "Send `flush' at the end of every command: the events sent since the
last flush belong to that command.  Context is not part of this; it is
sent on its own by `emacs-vent--maybe-send-context'."
  (emacs-vent--protected
   (emacs-vent--send-flush)))

(defun emacs-vent--message-advice (orig-fn fmt &rest args)
  ;; Decode any unibyte string arg (and FMT) to UTF-8 *before* formatting the
  ;; event content. The dominant caller is Tezcatl's resolver, which does
  ;; `(message "tez:%s ok %s" corr (json-serialize VALUE))' where
  ;; `json-serialize' hands back raw UTF-8 bytes as a unibyte string; without
  ;; this the formatted content carries those bytes and `emacs-vent--send'
  ;; cannot serialize it (see `emacs-vent--utf8'). ORIG-FN is still called
  ;; with the untouched args -- what Emacs echoes is out of scope here.
  (let ((result (apply orig-fn fmt args)))
    (when (and emacs-vent-mode fmt)
      (emacs-vent--protected
       (emacs-vent--send-event
        "message"
        (apply #'format-message
               (emacs-vent--utf8 fmt)
               (mapcar #'emacs-vent--utf8 args)))))
    result))

(defun emacs-vent--after-change (_beg _end _len)
  ;; buffer.changed is notification-only: no content, not even which buffer.
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
  (cond
   ;; A browser always sends `Origin' with a WebSocket handshake, and page JS
   ;; cannot drop or forge it; the clients meant for this port (Tezcatl's
   ;; relay, websocat) send none. Without this, any web page open in the
   ;; user's browser could take the single slot whenever the relay does not
   ;; hold it (before it connects, while it restarts) and inject keys --
   ;; `M-:' is arbitrary elisp. Binding to 127.0.0.1 does not stop that: the
   ;; handshake is outside the same-origin policy. Checked before the slot
   ;; test, so a refused page never holds the slot. Not authentication: who
   ;; connects is not asked, only whether a browser does.
   ((websocket-origin ws)
    (emacs-vent--log "refused a connection with Origin %s (browsers go through the relay)"
                     (websocket-origin ws))
    (websocket-close ws))
   (emacs-vent--client
    ;; One client at a time: a second is closed at once.
    (websocket-close ws))
   (t
    (setq emacs-vent--client ws)
    (emacs-vent--send (list :kind "hello"))
    ;; Establish the initial injection target right away.
    (emacs-vent--send-context-now))))

(defun emacs-vent--on-message (ws frame)
  (when emacs-vent-in-function
    (funcall emacs-vent-in-function ws frame)))

(defun emacs-vent--on-close (ws)
  (when (eq ws emacs-vent--client)
    (setq emacs-vent--client nil)))

;;;###autoload
(define-minor-mode emacs-vent-mode
  "Serve Emacs events/context to Tezcatl over a local WebSocket.
Listens on 127.0.0.1:`emacs-vent-port' for one client.  With
`emacs-vent-in' loaded, key input from that client is injected too."
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
  (add-hook 'post-command-hook #'emacs-vent--maybe-send-context)
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
  (remove-hook 'post-command-hook #'emacs-vent--maybe-send-context)
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
