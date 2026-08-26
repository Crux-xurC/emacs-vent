;;; emacs-vent-in.el --- Tezcatl -> Emacs input injection  -*- lexical-binding: t; -*-

;; Phase 5 (emacs-vent-in設計文書_v0.2.md). Converts normalized input
;; received from Tezcatl into Emacs events and injects them via
;; `unread-command-events', without interpreting what they mean (§1/§2).
;; Plugs into emacs-vent-out's existing server via `emacs-vent-in-function'
;; (§ "responsibility split": emacs-vent-out owns the connection/lifecycle,
;; vent-in only ever handles incoming messages).

(require 'emacs-vent-out)
(require 'json)
(require 'seq)

(defcustom emacs-vent-in-filters '()
  "Functions run on an incoming message plist before it is acted on.
Each is called with the full parsed message (including its :kind) and
must return a message plist to keep passing it on, or nil to drop it.
Runs immediately after JSON parsing, before any event conversion or
kill-ring mutation (design doc §8.1) -- applies to both key input and
clipboard text (§8.2). Default is pass-through (§8.3)."
  :type 'hook
  :group 'emacs-vent)

(defconst emacs-vent-in--special-keys
  '("return" "tab" "backspace" "delete" "escape"
    "up" "down" "left" "right" "home" "end" "prior" "next"
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8" "f9" "f10" "f11" "f12")
  "Non-printable key names accepted from the wire protocol (design doc §6.2).")

(defconst emacs-vent-in--modifier-prefix
  '(("control" . "C-") ("meta" . "M-") ("shift" . "S-") ("super" . "s-"))
  "Wire protocol modifier name -> `kbd' prefix letter (design doc §4).")

(defun emacs-vent-in--kbd-spec (key modifiers)
  "Build a single `kbd'-syntax spec string for one InputEvent.
KEY is a string (a literal printable character, or one of
`emacs-vent-in--special-keys'). MODIFIERS is a list/vector of strings
drawn from control/meta/shift/super. Signals an error on anything
unrecognized -- caught by the caller per design doc §13."
  (unless (and (stringp key) (> (length key) 0))
    (error "unrecognized key: %S" key))
  (let ((key-part
         (cond
          ((member key emacs-vent-in--special-keys) (format "<%s>" key))
          ((= (length key) 1) key)
          (t (error "unrecognized key: %S" key)))))
    ;; Validate every supplied modifier before using any of them -- the
    ;; canonical-order pass below silently ignores anything not in its
    ;; fixed list, so an unrecognized modifier must be caught here first.
    (seq-do (lambda (m)
              (unless (assoc m emacs-vent-in--modifier-prefix)
                (error "unrecognized modifier: %S" m)))
            modifiers)
    (let ((prefixes
           ;; Canonical order keeps this readable; `kbd' does not require it.
           (mapconcat
            (lambda (m) (cdr (assoc m emacs-vent-in--modifier-prefix)))
            (seq-filter (lambda (m) (seq-contains-p modifiers m #'equal))
                        '("control" "meta" "shift" "super"))
            "")))
      (concat prefixes key-part))))

(defun emacs-vent-in--event (input-event)
  "Convert one wire-protocol InputEvent plist (:key :modifiers) to a
single Emacs event (an integer or a symbol), per design doc §5/§9.1:
`kbd' is what actually applies the modifier bit/symbol-prefix, so a
modifier+key pair can never come apart into separate events."
  (let* ((key (plist-get input-event :key))
         (modifiers (plist-get input-event :modifiers))
         (spec (emacs-vent-in--kbd-spec key modifiers)))
    (aref (kbd spec) 0)))

(defun emacs-vent-in--handle-input (sequence)
  "SEQUENCE is a list of InputEvent plists (design doc §7). Convert all
of them and inject as one run of events, in order. If any one event in
the sequence fails to convert, the whole sequence is dropped rather
than injecting a partial key sequence (e.g. C-x without C-f) -- design
doc §13 says discard on conversion/injection failure without specifying
per-event granularity; whole-message atomicity is the safer reading."
  (condition-case err
      (let ((events (mapcar #'emacs-vent-in--event sequence)))
        (setq unread-command-events (append unread-command-events events)))
    (error
     (emacs-vent--log "in: bad input sequence %S: %S, dropped" sequence err))))

(defun emacs-vent-in--handle-clipboard (text)
  "Load TEXT onto the kill-ring (design doc §11.3). Never inserts text --
the actual paste is a normal C-y key event, handled like any other input."
  (if (stringp text)
      (condition-case err
          (kill-new text)
        (error (emacs-vent--log "in: kill-new failed: %S, dropped" err)))
    (emacs-vent--log "in: clipboard text not a string: %S, dropped" text)))

(defun emacs-vent-in--apply-filters (msg)
  "Run MSG through `emacs-vent-in-filters'; nil (from a filter, or from
an error inside one) means drop (design doc §13 in-filters row)."
  (condition-case err
      (catch 'emacs-vent-in-dropped
        (dolist (filter emacs-vent-in-filters)
          (setq msg (funcall filter msg))
          (unless msg (throw 'emacs-vent-in-dropped nil)))
        msg)
    (error (emacs-vent--log "in: in-filters error: %S, dropped" err) nil)))

(defun emacs-vent-in--on-message (_ws frame)
  "Entry point wired into `emacs-vent-in-function' (emacs-vent-out.el).
NOTE: the design doc describes the input/clipboard wire shape only at
the field level (§8.2's table, §7's sequence structure) without pinning
exact JSON key names. This implementation assumes:
  {\"kind\": \"input\", \"sequence\": [{\"key\": ..., \"modifiers\": [...]}, ...]}
  {\"kind\": \"clipboard\", \"text\": \"...\"}
mirroring emacs-vent-out's own `:kind' convention. Flag to the user if
the Tezcatl side expects something different."
  (emacs-vent--protected
   (let ((msg (condition-case nil
                  (json-parse-string (websocket-frame-text frame)
                                      :object-type 'plist
                                      :array-type 'list
                                      :false-object :false)
                (error
                 (emacs-vent--log "in: invalid JSON, dropped") nil))))
     (when msg
       (setq msg (emacs-vent-in--apply-filters msg))
       (when msg
         (pcase (plist-get msg :kind)
           ("input" (emacs-vent-in--handle-input (plist-get msg :sequence)))
           ("clipboard" (emacs-vent-in--handle-clipboard (plist-get msg :text)))
           (kind (emacs-vent--log "in: unknown kind %S, dropped" kind))))))))

(setq emacs-vent-in-function #'emacs-vent-in--on-message)

(provide 'emacs-vent-in)
;;; emacs-vent-in.el ends here
