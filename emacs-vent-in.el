;;; emacs-vent-in.el --- Tezcatl -> Emacs input injection  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Crux-xurC

;; Author: Crux-xurC
;; URL: https://github.com/Crux-xurC/emacs-vent
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

;; Converts normalized key input received from the client into Emacs
;; events and injects them via `unread-command-events', without
;; interpreting what they mean: Emacs's own keymaps decide that.
;;
;;   {"kind": "input",
;;    "sequence": [{"key": "x", "modifiers": ["control"]}, ...]}
;;
;; Plugs into emacs-vent-out's server via `emacs-vent-in-function':
;; emacs-vent-out owns the connection and its lifecycle, this file only
;; handles incoming messages.

;;; Code:

(require 'emacs-vent-out)
(require 'json)
(require 'seq)

(defcustom emacs-vent-in-filters '()
  "Functions run on an incoming message plist before it is acted on.
Each is called with the full parsed message (including its :kind) and
must return a message plist to keep passing it on, or nil to drop it.
Runs immediately after JSON parsing, before any event conversion.
Default is pass-through."
  :type 'hook
  :group 'emacs-vent)

(defconst emacs-vent-in--special-keys
  '("return" "tab" "backspace" "delete" "escape"
    "up" "down" "left" "right" "home" "end" "prior" "next"
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8" "f9" "f10" "f11" "f12")
  "Non-printable key names accepted from the wire protocol.
Any other key must be a single character.")

(defconst emacs-vent-in--modifier-prefix
  '(("control" . "C-") ("meta" . "M-") ("shift" . "S-") ("super" . "s-"))
  "Wire protocol modifier name -> `kbd' prefix letter.")

(defun emacs-vent-in--kbd-spec (key modifiers)
  "Build a single `kbd'-syntax spec string for one InputEvent.
KEY is a string (a literal printable character, or one of
`emacs-vent-in--special-keys'). MODIFIERS is a list/vector of strings
drawn from control/meta/shift/super. Signals an error on anything
unrecognized -- caught by the caller, which drops the whole sequence."
  (unless (and (stringp key) (> (length key) 0))
    (error "unrecognized key: %S" key))
  (let ((key-part
         (cond
          ((member key emacs-vent-in--special-keys) (format "<%s>" key))
          ;; A literal space is sent as the one-character key " " (`space'
          ;; is not a special-key name). `kbd' splits its spec on
          ;; whitespace, so " " parses to the empty key sequence and
          ;; `(aref (kbd " ") 0)' throws -- spell it "SPC" for `kbd'.
          ((equal key " ") "SPC")
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
single Emacs event (an integer or a symbol).
`kbd' is what actually applies the modifier bit/symbol-prefix, so a
modifier+key pair can never come apart into separate events."
  (let* ((key (plist-get input-event :key))
         (modifiers (plist-get input-event :modifiers))
         (spec (emacs-vent-in--kbd-spec key modifiers)))
    (aref (kbd spec) 0)))

(defun emacs-vent-in--handle-input (sequence)
  "SEQUENCE is a list of InputEvent plists. Convert all of them and
inject as one run of events, in order. If any one event in the sequence
fails to convert, the whole sequence is dropped rather than injecting a
partial key sequence (e.g. C-x without C-f). A SEQUENCE that is not a
list (a bare value or object where an array was expected) is dropped too.
Every drop is logged, never silently ignored."
  (if (not (listp sequence))
      (emacs-vent--log "in: input sequence not an array: %S, dropped" sequence)
    (condition-case err
        (let ((events (mapcar #'emacs-vent-in--event sequence)))
          (setq unread-command-events (append unread-command-events events)))
      (error
       (emacs-vent--log "in: bad input sequence %S: %S, dropped" sequence err)))))

(defun emacs-vent-in--apply-filters (msg)
  "Run MSG through `emacs-vent-in-filters'; nil (from a filter, or from
an error inside one) means drop."
  (condition-case err
      (catch 'emacs-vent-in-dropped
        (dolist (filter emacs-vent-in-filters)
          (setq msg (funcall filter msg))
          (unless msg (throw 'emacs-vent-in-dropped nil)))
        msg)
    (error (emacs-vent--log "in: in-filters error: %S, dropped" err) nil)))

(defun emacs-vent-in--on-message (_ws frame)
  "Entry point wired into `emacs-vent-in-function' (emacs-vent-out.el).
The only accepted kind is `input' -- there is a single input path; text
and pastes arrive as keys too:
  {\"kind\": \"input\", \"sequence\": [{\"key\": ..., \"modifiers\": [...]}, ...]}
Invalid JSON, another kind, or a missing `sequence' is dropped and logged."
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
           ("input"
            (if (plist-member msg :sequence)
                (emacs-vent-in--handle-input (plist-get msg :sequence))
              (emacs-vent--log "in: input message missing :sequence, dropped")))
           (kind (emacs-vent--log "in: unknown kind %S, dropped" kind))))))))

(setq emacs-vent-in-function #'emacs-vent-in--on-message)

(provide 'emacs-vent-in)
;;; emacs-vent-in.el ends here
