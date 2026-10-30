;;; emacs-vent-in-dialogue.el --- emacs-vent-in's dialogue half (currently a no-op seat)  -*- lexical-binding: t; -*-

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

;; Counterpart to `emacs-vent-out-dialogue.el' on the input side. Driving a
;; dialogue tool (e.g. sending Proof General's `C-c C-n') needs no new
;; mechanism today: it goes through the existing `kind:"input"' path in
;; `emacs-vent-in.el' unchanged, landing in whichever window is selected
;; (Tezcatl's `dialogue-input.html' panel reuses its ordinary input panel
;; as-is for this reason).
;;
;; This file exists anyway, deliberately near-empty, as the reserved seat for
;; the day driving a dialogue tool needs its own input semantics that plain
;; key injection cannot express (e.g. picking one of several structured
;; choices rather than sending keystrokes). Until then, requiring this file
;; buys nothing beyond documenting where that code would go; it does not need
;; to be loaded for dialogue driving to work.

;;; Code:

(require 'emacs-vent-in)

(provide 'emacs-vent-in-dialogue)
;;; emacs-vent-in-dialogue.el ends here
