# LLM Chat

Chat with Claude, and with the models on OpenCode, OpenRouter and Vercel AI Gateway, on a [PicoDeck](https://picodeck.net) PicoCalc, and have the model write small Lua programs that you run on the spot without leaving the app.

- It opens on a fresh chat with the cursor in the compose box. Type, press Enter, and the reply streams in word by word.
- Every model is named `<service>/<model>`, like `anthropic/claude-opus-5-5` or `vercel/google/gemini-3.8-flash`. F4 picks one from a list: your recent models first, then each service's models. Type to filter. You can switch models in the middle of a chat.
- Recent chats are kept (the newest 50) and can be reopened.
- A model's Lua program is saved on the card and runs from F3 or the Programs tab. If it crashes, one key asks the model to fix it.

## Set up
1. Install LLM Chat from the PicoDeck App Store. The device needs WiFi and PicoDeck 0.7.0 or later.
2. Give it an API key for one or more of the services: Anthropic (Claude), [OpenCode](https://opencode.ai), [OpenRouter](https://openrouter.ai) and [Vercel AI Gateway](https://vercel.com/ai-gateway). Either:
   - open Settings (F5), move to the service's row under **API keys** and press Enter to type or paste the key; or
   - put the keys in a file `keys.txt` in the app's data folder, `/data/net.picodeck.llmchat/`, from a computer over USB or with the Text Editor app. One key per line, `#` starts a comment:
     ```
     # LLM Chat API keys
     anthropic=sk-ant-...
     opencode=...
     openrouter=sk-or-v1-...
     vercel=...
     ```
     A `claude=` line from an older `keys.txt` still works as the Anthropic key.
3. Press **F4** in a chat to pick a model. The first time, the app downloads the model list of each service you have a key for (only the names are kept, in `models/` in the data folder); **F2** in the picker downloads them again. Anthropic's models are built in. A model missing from the lists can be typed whole, for example `openrouter/qwen/qwen3.8-max`.
4. Settings also sets how hard the model thinks (Low, Medium, High; sent the way each service expects it), the reply font (Sans or System 6x8) and extra instructions added to the system prompt. Esc saves and goes back.

Keys are shown masked in Settings, and each one is only ever sent to its own service's server.

## Keys
Every command also works from a game controller, and follows **Settings → Controls** in the system menu: F1-F5 and Tab act as the gamepad buttons they are bound to (by default Start, L, R, A and B; Tab is Select), and so do the arrows, Enter, Esc, Del and Backspace everywhere but where you type. The Pad column below names the button. Where you type (the compose box, the picker's filter, a key or the instructions in Settings) the keyboard types: a key there never also acts as the button it is bound to, and writing a message needs a keyboard. With only a controller you can still read and open chats, pick a model, change Settings and run programs; Home opens the system menu, where **Exit App** quits.

**Chat**

| Key | Action |
|---|---|
| typing, Left / Right, Backspace, Del | edit the compose box |
| Enter | send. When the last line is an error and the box is empty, Enter retries |
| Shift+Enter | new line in the compose box |
| Up / Down | scroll the conversation a row (hold to repeat) |
| Shift+Up / Shift+Down | scroll a page |
| Esc | while a reply arrives: stop it. Otherwise quit (an unsent message is kept as a draft) |
| F1 | Recent chats and programs |
| F2 | new chat |
| F3 | run the newest program in this chat (when one exists and no reply is arriving) |
| F4 | pick a model (the next message goes to it, with the conversation so far; a dim "now `<model>`" line marks the switch) |
| F5 | Settings |

**Model picker** (F4)

| Key | Action |
|---|---|
| typing, Left / Right, Backspace, Del | filter: every word you type must appear in the model's name (`ds flash`, `vercel gem`) |
| Up / Down | move between models (hold to repeat); Shift for a page |
| Enter | pick the model, or "Use `<id>`" for a whole id you typed, and go back to the chat |
| Esc | clear the filter; when it's empty, go back without changing anything |
| F2 | download the services' model lists again |

**Recent chats and programs** (Left / Right switch between the Chats and Programs tabs)

| Key | Pad | Chats tab | Programs tab |
|---|---|---|---|
| Up / Down | Up / Down | move in the list | move in the list |
| Enter, F4 | A | open the chat | run the program |
| F2 | L | new chat | |
| Backspace | Y | | open the chat that made the program |
| Del | X | delete the chat (asks first) | delete the program (asks first) |
| Esc, F5 | B | back to the chat | back to the chat |

**Program stopped** (after a crash)

| Key | Action |
|---|---|
| Left / Right | move between "Ask the model to fix" and "Back to chat" |
| Enter | choose the button |
| F3 | run the program again |
| Esc | back to the chat |

**Settings**

| Key | Action |
|---|---|
| Up / Down | move between rows |
| Enter | change the row, or edit a key or the instructions (an empty key removes it) |
| Esc | while editing: cancel (instructions: done); otherwise save and go back |

## Programs
Ask for one in plain words: "write a dice roller", "a program that shows a clock". The model answers with a Lua program in a code block, headed by a comment that names the file, such as `-- dice.lua`. The system prompt teaches it the PicoDeck API.

- When the reply finishes, each program is saved as `programs/<name>.lua` in the data folder, and the code block shows an "F3" line with "saved as dice.lua". A name taken by another chat gets a number (`dice-2.lua`). Names are lower-case, `a-z 0-9 _ -`, up to 24 characters.
- **F3** runs the newest program in the chat. The **Programs** tab (F1, then Right) lists every saved program; Enter runs one.
- A program runs on the whole screen. Esc usually ends it (that is up to the program), and you come back to the chat with a line such as "dice.lua ended after 12 s" ("stopped after" when you used Stop program). A program that calls `sys.exit()` also returns you to the chat.
- **Stuck program:** open the system menu and choose **Stop program**. If the program is in a tight loop the menu can take several seconds to appear: wait about 5 s before choosing. A program that wraps its code in its own `pcall` can swallow the stop; **Exit App** in the same menu is the last resort, and loses nothing, as the chat is already saved.
- **Crash:** the error screen shows the message, how long it ran and the last lines it printed. **Ask the model to fix** sends the error to the current model and saves the fixed program over the file (the old version is kept as `<name>.lua.prev`). F3 runs it again as it is. A program whose chat was deleted can still be run; fixing it starts a new chat.
- Each program has its own folder, `programs/<name>.data/`, for the files and settings it saves. Deleting a program (Del in the Programs tab) deletes that folder too, and its saved data with it.

### What the sandbox does and doesn't do
A program runs inside the chat app, so the app fences it in. The fence is built to hold against any program, a hostile one included: a program must not be able to read your API keys or your chats, and must not take the app down.
- **Kept out:** a program cannot read or write the chat's files or `keys.txt`; its files live only in its own folder. It gets its own copies of the standard libraries, and cannot reach the chat's globals or the real `sys.exit`. The screen is cleared before it starts, so it can't read the chat's last frame. The moment it ends, everything it could call stops working: its menu items and its network and sound callbacks are cut off, and the app closes the fonts, files, connections and players it opened. Lua still runs the program's `<close>` handlers as its stack unwinds. By then they can reach no file, network or menu (at most they draw with the images and other objects the program made), except after an out-of-memory error, when they run before the program's functions stop working; Stop program ends them either way. The chat only accepts a local test server in place of the real API address, so a key can't be redirected elsewhere.
- **Not kept out** (the fence's known limits):
  - A program shares the chat's memory, so a greedy one can use it all (the run then ends with "not enough memory").
  - While it runs, it can draw over the screen, play sound, and use the network, since the app has the `http` permission.
  - A program written to catch errors can ignore "Stop program": its own `pcall` or `xpcall` catches the stop, and so do `coroutine.resume` and `coroutine.close`, and the firmware when it runs a network or sound callback from `sys.sleep`, or a copy or unzip progress callback. A program can also catch it in a reader function it gives `load`, but then it runs on with nothing it can call. So can a program whose `<close>` handlers each set up another before they loop, as each Stop ends only the handler that is running. **Exit App** in the system menu is the fallback.
  - Not yet checked on a device: the firmware also runs network and sound callbacks from its own background service, where Lua runs no hooks. A program callback there that never returns can't be reached by Stop program or Exit App, as the system menu can't open, and the device probably restarts when its watchdog runs out.
- Reading a program before you run it is still a good habit.

A stronger wall would need firmware support (running a program as its own app, in its own Lua state); that is not built.

## Credits
The Sans reading font is converted from X.Org's Adobe bitmap fonts; [fonts/LICENSE](fonts/LICENSE) has the licence.
- Sans: Helvetica 12. Copyright 1984-1989, 1994 Adobe Systems Incorporated. Copyright 1988, 1994 Digital Equipment Corporation. Helvetica is a trademark of Linotype-Hell AG and/or its subsidiaries.

## Development
- `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
- `make e2e`: smoke tests in the PicoDeck simulator against a fake API server on `127.0.0.1` (the app reaches it through the hidden `anthropic_base`, `opencode_base`, `openrouter_base` and `vercel_base` overrides in `prefs.json`, loopback only). They need a PicoDeck checkout (`PICODECK_ROOT`, default `~/Projects/PicoDeck/picodeck`); run `make simulator` there first.
- `make test-tools`: pytest tests of `tools/record_stream.py`, which send no request and read no keys.
- [docs/device-checklist.md](docs/device-checklist.md): the checks to run on a real PicoCalc before a release.
- `tools/make_icon.py` redraws `icon.png`; `tools/record_stream.py <anthropic|opencode|openrouter|vercel> <case>` records real API replies for test fixtures and logs their cost in `docs/research/api-spend.md`; `tools/probes/` holds the verify-first probes.
- Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP, `picodeck-llmchat-v<version>.zip` (named after the tag).
