;;; init.el --- emacs-vent test harness  -*- lexical-binding: t; -*-

;; Plain: no personal config. Just enough to load emacs-vent-out and
;; connect to it from outside (e.g. `websocat ws://127.0.0.1:4000/`).

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(require 'websocket)
(require 'emacs-vent-out)
(require 'emacs-vent-in)

(emacs-vent-mode 1)

(message "emacs-vent ready on 127.0.0.1:%s (log: %s)" emacs-vent-port (emacs-vent-log-file))
