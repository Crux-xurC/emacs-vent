;;; emacs-vent-out-dialogue.el --- emacs-vent-out's dialogue half  -*- lexical-binding: t; -*-

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

;; The "dialogue" half of emacs-vent-out: bridging tools that produce
;; *continuous* output (as opposed to a one-shot `M-:' value returned
;; through a `message') -- Proof General is the first one. Its counterpart
;; on the input side is `emacs-vent-in-dialogue.el', and together with
;; `emacs-vent-in.el' / `emacs-vent-out.el' that makes four files in this
;; package. On the Tezcatl side, the `dialogue-output.html' panel shows
;; these events.
;;
;; Kept in a separate file from `emacs-vent-out.el', not because it is a
;; different package (it isn't -- it freely reuses `emacs-vent-out.el's
;; private `emacs-vent--send-event' / `emacs-vent--send-flush' /
;; `emacs-vent--protected', the same way the `compilation.*' hooks in that
;; file do), but so that loading it is opt-in: a third-party package such as
;; Proof General must not become a hard dependency of the core. Load this
;; file yourself (after `emacs-vent-out') only if Proof General is also
;; installed.
;;
;; Wire shape is deliberately identical to `compilation.*': exactly one new
;; `event.type' per bridged tool, no new `kind', no changes to
;; emacs-vent-in / the relay / context.
;;
;; Why `context' needs no changes: Proof General's normal step commands
;; (`proof-goto-point', `C-c C-n', ...) display the `*goals*'/`*response*'
;; buffers without selecting them, so the injection target (the scripting
;; buffer) does not move -- Tezcatl's browser side can already tell "we are in
;; a Proof General session" from the existing `context' message's
;; `buffer-name' (e.g. a `.v' suffix), no new capture required. (Verify this
;; assumption on the actual buffer-display config in use; if some
;; configuration does select an auxiliary buffer, fix it with
;; `display-buffer-alist' there, not here.)

;;; Code:

(require 'emacs-vent-out)
(require 'proof-shell)

(defun emacs-vent--proof-general-delayed-output ()
  "Forward Proof General's goals/response buffers as a `proof-general.output' event.
Hooked onto `proof-shell-handle-delayed-output-hook', which runs after
`proof-shell-last-goals-output' and `proof-shell-last-response-output' are
set for this step (possibly to the empty string, meaning \"clear this pane\"
-- see that hook's docstring). Both are sent every time, whichever is empty
this round included, so the browser side can just replace-in-place rather
than infer which pane changed from `proof-shell-last-output-kind'."
  (emacs-vent--protected
   (emacs-vent--send-event
    "proof-general.output"
    (list :goals (or proof-shell-last-goals-output "")
          :response (or proof-shell-last-response-output ""))
    "proof-general")
   (emacs-vent--send-flush)))

(add-hook 'proof-shell-handle-delayed-output-hook
          #'emacs-vent--proof-general-delayed-output)

;; `emacs-vent-out.el's `emacs-vent--stop' (run when `emacs-vent-mode' turns
;; off) has no knowledge of this file's hook -- by design, this file never
;; touches core's `--start'/`--stop' (see the file header). Without the
;; following, disabling `emacs-vent-mode' would leave
;; `emacs-vent--proof-general-delayed-output' firing on every Proof General
;; step for the rest of the session -- harmless (it only reaches a no-op
;; when `emacs-vent--send' finds `emacs-vent--client' nil) but wasted work,
;; and it quietly breaks the expectation that turning the mode off fully
;; deactivates emacs-vent. `emacs-vent-mode-hook' is the public hook
;; `define-minor-mode' already provides for exactly this kind of add-on,
;; run on every toggle with `emacs-vent-mode' already set to the new state.
(defun emacs-vent--dialogue-sync-hooks ()
  "Keep the dialogue output hook in sync with `emacs-vent-mode' on/off."
  (if emacs-vent-mode
      (add-hook 'proof-shell-handle-delayed-output-hook
                #'emacs-vent--proof-general-delayed-output)
    (remove-hook 'proof-shell-handle-delayed-output-hook
                 #'emacs-vent--proof-general-delayed-output)))

(add-hook 'emacs-vent-mode-hook #'emacs-vent--dialogue-sync-hooks)

;; Future dialogue tools (a REPL, a debugger, ...) get their own hook
;; function + `add-hook' pair here, following the same shape -- this file is
;; the shared home for "dialogue" output sources, the way `emacs-vent-out.el'
;; itself is the shared home for `compilation.*'.

(provide 'emacs-vent-out-dialogue)
;;; emacs-vent-out-dialogue.el ends here
