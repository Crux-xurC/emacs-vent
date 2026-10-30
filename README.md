# emacs-vent

A local WebSocket bridge between Emacs and [Tezcatl](https://github.com/Crux-xurC/tezcatl). The core sends Emacs events and context to one client and accepts normalized key input from it. Optional dialogue integrations can forward output from interactive tools.

The server binds to `127.0.0.1` and accepts one client connection. It is intended for local use with Tezcatl (whose relay holds the connection and serves the browser); it does not provide authentication or remote access.

## Requirements

- Emacs 27.1 or later (native JSON, window change hooks). Checked with Emacs 30.2.
- The [`websocket`](https://github.com/ahyatt/emacs-websocket) package. Checked with the MELPA version 20260301.157.

## Installation

Add this directory to `load-path` and load the modules you need:

```elisp
(add-to-list 'load-path "/path/to/emacs-vent")
(require 'emacs-vent-out)
(require 'emacs-vent-in)
(emacs-vent-mode 1)
```

`emacs-vent-out` alone sends but ignores input; `emacs-vent-in` adds key input. Set `emacs-vent-port` before enabling the mode to listen on a port other than 4000.

## Connections

- One client at a time. A second connection is closed at once.
- A connection whose handshake carries an `Origin` header is refused and logged. Browsers always send `Origin`, so web pages cannot connect directly, even while no client holds the slot; Tezcatl's relay and command-line tools such as `websocat` send none.
- There is no authentication: any local program that connects without `Origin` can inject keys, and `M-:` runs arbitrary Emacs Lisp. Use it only on a machine where you trust the local users and programs.

## Protocol

One JSON object per text frame, always with a string field `kind`. The editor-neutral agreement is Tezcatl's [docs/protocol.md](https://github.com/Crux-xurC/tezcatl/blob/main/docs/protocol.md); this section describes what emacs-vent sends and accepts.

### Emacs → client

| `kind` | When | Shape |
|---|---|---|
| `hello` | once, when the client connects | `{"kind":"hello"}` |
| `context` | right after `hello`, then whenever the input target changes | `{"kind":"context","buffer-name":"foo.el","window":"win-3","frame":"frame-1"}` |
| `event` | something happened (below) | `{"kind":"event","source":…,"type":…,"content":…}` |
| `flush` | at the end of every command | `{"kind":"flush"}` |

`context` says where injected keys go now: the selected window of the selected frame, or the active minibuffer (` *Minibuf-1*`). `window` and `frame` are ids stable for the session. It is sent only when one of the three values changes, and is applied on arrival rather than batched with events. Calling `emacs-vent-send-context` (for example through `M-:`) sends it unconditionally, for a client that needs the current value later.

| `event` `type` | `source` | `content` |
|---|---|---|
| `message` | the file that defined the running command (e.g. `"simple"`), or `null` | the formatted message |
| `buffer.changed` | as above | none (a notification only) |
| `compilation.started` | `"compilation"` | none |
| `compilation.output` | `"compilation"` | the text appended to the compilation buffer |
| `compilation.finished` | `"compilation"` | the end message |

Events sent between two `flush` messages belong to one command. The `compilation.*` events send their own `flush`. A value from `M-:` comes back as a `message` event.

### Client → Emacs

```json
{
  "kind": "input",
  "sequence": [
    {"key": "x", "modifiers": ["control"]},
    {"key": "return", "modifiers": []}
  ]
}
```

- `key` is a single character (a space is `" "`) or one of `return`, `tab`, `backspace`, `delete`, `escape`, `up`, `down`, `left`, `right`, `home`, `end`, `prior`, `next`, `f1` … `f12`.
- `modifiers` are `control`, `meta`, `shift` and `super`.
- The keys are converted to Emacs events and appended to `unread-command-events`, so Emacs's own keymaps decide what they mean. emacs-vent never interprets them.
- If one key of a sequence cannot be converted, the whole sequence is dropped, never a part of it (no `C-x` without the `C-f`). Invalid JSON, another `kind`, or a missing `sequence` is dropped too. Every drop is logged.

## Customization

| Variable | Default | What |
|---|---|---|
| `emacs-vent-port` | `4000` | the port on `127.0.0.1` (set before enabling the mode) |
| `emacs-vent-log-directory` | `$XDG_STATE_HOME/emacs-vent`, else `~/.local/state/emacs-vent` | where the log goes |
| `emacs-vent-out-filters` | `()` | functions run on each outgoing message plist; return a plist to pass it on, `nil` to drop it |
| `emacs-vent-in-filters` | `()` | the same for each incoming message, right after JSON parsing |
| `emacs-vent-source-function` | `emacs-vent-source-default` | maps the running command to an event's `source` |
| `emacs-vent-serialize-function` | `json-serialize` | turns a message plist into text |

The log is `log.txt`, one file per start of Emacs; the previous run's is kept as `log.1.txt`. Errors in hooks and message processing are logged and contained, so they never reach Emacs's own command execution.

## Optional dialogue output

`emacs-vent-out-dialogue.el` contains an opt-in Proof General integration. After each step it sends a `proof-general.output` event (`source` `"proof-general"`) whose `content` is `{"goals": …, "response": …}`, both panes every time (an empty string clears one). Load it after `emacs-vent-out`, only when Proof General is installed:

```elisp
(require 'emacs-vent-out-dialogue)
```

This integration is an optional extension. Its future maintenance will depend on user demand and maintainer availability.

`emacs-vent-in-dialogue.el` is currently an intentionally empty extension point. Dialogue tools that accept ordinary key input already work through `emacs-vent-in.el`; this module is not required for that use.

## Development

The Nix development shell provides Emacs with the `websocket` package and `websocat`. It uses this repository as an isolated Emacs init directory, apart from your own configuration.

```sh
nix develop
e
```

The `e` command starts Emacs with this repository's `init.el`, which loads `emacs-vent-out` and `emacs-vent-in`, enables the mode and listens on port 4000. To connect manually:

```sh
websocat ws://127.0.0.1:4000/
```

## Scope and limitations

- The bridge targets a single local client and a single Emacs instance.
- It forwards selected event/context data and normalized input; it is not a general-purpose remote-control or telemetry service.
- Incoming keys are injected as Emacs events. The bridge does not interpret commands or decide what a key sequence means.
- It does not send the contents of buffers; `buffer.changed` does not even say which buffer changed.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
