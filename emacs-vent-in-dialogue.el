;;; emacs-vent-in-dialogue.el --- emacs-vent-in's dialogue half (currently a no-op seat)  -*- lexical-binding: t; -*-

;; Counterpart to `emacs-vent-out-dialogue.el' on the input side. Driving a
;; dialogue tool (e.g. sending Proof General's `C-c C-n') needs no new
;; mechanism today: it goes through the existing `kind:"input"' path in
;; `emacs-vent-in.el' unchanged, landing in whichever window is selected
;; (Tezcatl's `dialogue-input.html' reuses `input-panel.js' as-is for this
;; reason -- see the browser-side panels under my_app/tezcatl/panels/).
;;
;; This file exists anyway, deliberately near-empty, as the reserved seat for
;; the day driving a dialogue tool needs its own input semantics that plain
;; key injection cannot express (e.g. picking one of several structured
;; choices rather than sending keystrokes) -- the same "insert an empty stage
;; on purpose" move as Tezcatl's Input Middleware seam
;; (overview.md §7: "空でも1段挟む"). Until that day, requiring this file
;; buys nothing beyond documenting where that code would go; it does not need
;; to be loaded for dialogue driving to work.

(require 'emacs-vent-in)

(provide 'emacs-vent-in-dialogue)
;;; emacs-vent-in-dialogue.el ends here
