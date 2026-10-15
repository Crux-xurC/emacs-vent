# emacs-vent

A local WebSocket bridge between Emacs and [Tezcatl](https://github.com/Crux-xurC/tezcatl). The core sends Emacs events and context to a browser client and accepts normalized key input from it. Optional dialogue integrations can forward output from interactive tools.

The server binds to `127.0.0.1` and accepts one client connection. It is intended for local use with Tezcatl; it does not provide authentication or remote access.

## Features

- Sends a `hello` message and the current input target when a client connects.
- Sends `event` messages for Emacs messages, buffer changes, and compilation start/output/finish.
- Sends `context` when the selected window, buffer, or active minibuffer changes. Context is sent immediately and is not part of the event flush batch.
- Receives `kind: "input"` messages containing a sequence of normalized key events, converts them to Emacs events, and injects them through `unread-command-events`.
- Provides inbound and outbound filter hooks for dropping or transforming messages.
- Writes diagnostics to a rotating log under `$XDG_STATE_HOME/emacs-vent`, or `~/.local/state/emacs-vent` when `XDG_STATE_HOME` is unset.

The WebSocket protocol uses JSON. An input message has this shape:

```json
{
  "kind": "input",
  "sequence": [
    {"key": "x", "modifiers": ["control"]},
    {"key": "return", "modifiers": []}
  ]
}
```

Supported modifier names are `control`, `meta`, `shift`, and `super`. Special key names include `return`, `tab`, `backspace`, `delete`, `escape`, the arrow keys, `home`, `end`, `prior`, `next`, and `f1` through `f12`. Invalid messages and key sequences are dropped and logged.

## Development

The Nix development shell provides Emacs with the `websocket` package and `websocat`. It uses an isolated Emacs init directory.

```sh
nix develop
e
```

The `e` command starts the test harness in this repository's `init.el`. The harness loads `emacs-vent-out` and `emacs-vent-in`, enables the mode, and listens on port 4000 by default. To connect manually:

```sh
websocat ws://127.0.0.1:4000/
```

The port can be changed with `emacs-vent-port` before enabling `emacs-vent-mode`. The log directory can be changed with `emacs-vent-log-directory`.

For a normal Emacs configuration, add this directory to `load-path` and load the modules you need:

```elisp
(add-to-list 'load-path "/path/to/emacs-vent")
(require 'emacs-vent-out)
(require 'emacs-vent-in)
(emacs-vent-mode 1)
```

## Optional dialogue output

`emacs-vent-out-dialogue.el` contains an opt-in Proof General integration. It forwards the current goals and response panes as `proof-general.output` events. Load it only when Proof General is installed:

```elisp
(require 'emacs-vent-out-dialogue)
```

This integration is an optional extension. Its future maintenance will depend on user demand and maintainer availability.

`emacs-vent-in-dialogue.el` is currently an intentionally empty extension point. Dialogue tools that accept ordinary key input already work through `emacs-vent-in.el`; this module is not required for that use.

## Scope and limitations

- The bridge targets a single local client and a single Emacs instance.
- It forwards selected event/context data and normalized input; it is not a general-purpose remote-control or telemetry service.
- Incoming keys are injected as Emacs events. The bridge does not interpret commands or decide what a key sequence means.
- Errors in hooks and message processing are logged and contained so they do not propagate into normal Emacs command execution.
