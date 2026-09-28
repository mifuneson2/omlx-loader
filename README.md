# oMLX Loader

A small macOS menu bar app for the local [oMLX](https://github.com/jundot/omlx) inference server, so you don't have to remember the command lines.

From the menu bar icon you can:

- **Start / stop oMLX.** This runs `brew services start|stop jundot/omlx/omlx`. Stopping also turns off oMLX's start-at-login until you start it again.
- **Load a model.** Pick one from the list. Any other loaded model is unloaded first, and oMLX is started if it isn't running.
- **Unload** the current model.
- **Open the oMLX dashboard** at `http://127.0.0.1:8000/admin`.
- **Open oMLX Loader at login.**

| Icon | Meaning |
|---|---|
| `cpu` (dimmed) | oMLX stopped |
| `cpu` | Running, no model loaded |
| `cpu.fill` | Running, a model is loaded |
| `hourglass` | Starting, stopping, loading or unloading |
| `exclamationmark.triangle` | The last action failed. Open the menu for details. |

## Build and install

It needs Xcode's Swift toolchain. It has no other dependencies.

```bash
./build.sh            # builds build/oMLX Loader.app
./build.sh --install  # also copies it to ~/Applications and launches it
```

## Self-test

```bash
"build/oMLX Loader.app/Contents/MacOS/oMLXLoader" --selftest readerlm-v2
```

The self-test runs the app's own controller code against the live server using a small model.

- **If nothing is loaded:** it starts oMLX if needed, loads the model exclusively, unloads it, and stops oMLX again if it was stopped at the beginning.
- **If a model is already loaded:** it loads the test model next to it and unloads only the test model. It never evicts your model.

## How it talks to oMLX

- **Status:** `GET /v1/models/status`, polled every 3 seconds. Also `GET /health`.
- **Load:** `POST /admin/api/models/{id}/load`. This works without logging in only while `auth.skip_api_key_verification` is on in `~/.omlx/settings.json`. If it returns 401, the app falls back to a one-token chat completion, which also makes oMLX load the model.
- **Unload:** `POST /v1/models/{id}/unload`.
- **Port and model folder:** read from `~/.omlx/settings.json`.

Don't stop oMLX by killing the process. The brew launch agent has `KeepAlive` on, so launchd restarts it immediately.
