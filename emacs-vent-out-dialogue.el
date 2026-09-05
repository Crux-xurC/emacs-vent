;;; emacs-vent-out-dialogue.el --- emacs-vent-out's dialogue half  -*- lexical-binding: t; -*-

;; The "dialogue" half of emacs-vent-out: bridging tools that produce
;; *continuous* output (as opposed to a one-shot `M-:' value return like the
;; `magit.*' intents) -- Proof General is the first one. Its counterpart on
;; the input side is `emacs-vent-in-dialogue.el' (driving), and together with
;; `emacs-vent-in.el' / `emacs-vent-out.el' (command in/out) that makes four
;; files total in this package. See the Tezcatl side's
;; my_app/tezcatl/forAI/overview.md for the browser panels
;; (`dialogue-input.html' / `dialogue-output.html').
;;
;; Kept in a separate file from `emacs-vent-out.el', not because it is a
;; different package (it isn't -- it freely reuses `emacs-vent-out.el's
;; private `emacs-vent--send-event' / `emacs-vent--send-flush' /
;; `emacs-vent--protected', the same way the `compilation.*' hooks in that
;; file do), but so that loading it is opt-in: a third-party package such as
;; Proof General must not become a hard dependency of `emacs-vent-out.el'
;; core (overview.md principle 10, "Tezcatl Core を肥大化させない"). Load
;; this file yourself (after `emacs-vent-out') only if Proof General is also
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

;; Future dialogue tools (a REPL, a debugger, ...) get their own hook
;; function + `add-hook' pair here, following the same shape -- this file is
;; the shared home for "dialogue" output sources, the way `emacs-vent-out.el'
;; itself is the shared home for `compilation.*'.

(provide 'emacs-vent-out-dialogue)
;;; emacs-vent-out-dialogue.el ends here
