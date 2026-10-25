# LLM Chat

Chat with Claude and OpenAI models on a [PicoDeck](https://picodeck.net) PicoCalc, and have the model write small Lua programs that you run on the spot without leaving the app.

- It opens on a fresh chat with the cursor in the compose box. Type, press Enter, and the reply streams in word by word.
- Recent chats are kept (the newest 50) and can be reopened.
- A model's Lua program is saved on the card and runs from F3 or the Programs tab. If it crashes, one key asks the model to fix it.

## Set up
1. Install LLM Chat from the PicoDeck App Store. The device needs WiFi.
2. Give it an API key for Claude, OpenAI or both. Either:
   - open Settings (F5), move to **Claude key** or **OpenAI key** and press Enter to type or paste it; or
   - put it in a file `keys.txt` in the app's data folder, `/data/net.picodeck.llmchat/`, from a computer over USB or with the Text Editor app. One key per line, `#` starts a comment:
     ```
     # LLM Chat API keys
     claude=sk-ant-...
     openai=sk-...
     ```
3. Settings also picks the provider, the model (or **Custom...** for any model id), how hard the model thinks (Low, Medium, High), the reply font (Sans or System 6x8) and extra instructions added to the system prompt. Esc saves and goes back.

Keys are shown masked in Settings and are only ever sent to the provider's own server.

## Keys
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
| F5 | Settings |

**Recent chats and programs** (Left / Right switch between the Chats and Programs tabs)

| Key | Chats tab | Programs tab |
|---|---|---|
| Up / Down | move in the list | move in the list |
| Enter | open the chat | run the program |
| F2 | new chat | new chat (Chats tab only) |
| F4 | | open the chat that made the program |
| Del | delete the chat (asks first) | delete the program (asks first) |
| Esc | back to the chat | back to the chat |

**Program stopped** (after a crash)

| Key | Action |
|---|---|
| Left / Right | move between "Ask ... to fix" and "Back to chat" |
| Enter | choose the button |
| F3 | run the program again |
| Esc | back to the chat |

**Settings**

| Key | Action |
|---|---|
| Up / Down | move between rows |
| Left / Right | Claude / OpenAI, on the Provider row |
| Enter | change the row, or edit a key, the instructions, or a custom model id |
| Esc | while editing: cancel (instructions: done); otherwise save and go back |

## Programs
Ask for one in plain words: "write a dice roller", "a program that shows a clock". The model answers with a Lua program in a code block, headed by a comment that names the file, such as `-- dice.lua`. The system prompt teaches it the PicoDeck API.

- When the reply finishes, each program is saved as `programs/<name>.lua` in the data folder, and the code block shows an "F3" line with "saved as dice.lua". A name taken by another chat gets a number (`dice-2.lua`). Names are lower-case, `a-z 0-9 _ -`, up to 24 characters.
- **F3** runs the newest program in the chat. The **Programs** tab (F1, then Right) lists every saved program; Enter runs one.
- A program runs on the whole screen. Esc usually ends it (that is up to the program), and you come back to the chat with a line such as "dice.lua ended after 12 s" ("stopped after" when you used Stop program). A program that calls `sys.exit()` also returns you to the chat.
- **Stuck program:** open the system menu and choose **Stop program**. If the program is in a tight loop the menu can take several seconds to appear: wait about 5 s before choosing. A program that wraps its code in its own `pcall` can swallow the stop; **Exit App** in the same menu is the last resort, and loses nothing, as the chat is already saved.
- **Crash:** the error screen shows the message, how long it ran and the last lines it printed. **Ask Claude to fix** (or OpenAI) sends the error to the model and saves the fixed program over the file (the old version is kept as `<name>.lua.prev`). F3 runs it again as it is. A program whose chat was deleted can still be run; fixing it starts a new chat.
- Each program has its own folder, `programs/<name>.data/`, for the files and settings it saves. Deleting a program (Del in the Programs tab) deletes that folder too, and its saved data with it.

### What the sandbox does and doesn't do
A program runs inside the chat app, so the app fences it in. The fence is built to hold against any program, a hostile one included: a program must not be able to read your API keys or your chats, and must not take the app down.
- **Kept out:** a program cannot read or write the chat's files or `keys.txt`; its files live only in its own folder. It gets its own copies of the standard libraries, and cannot reach the chat's globals or the real `sys.exit`. The screen is cleared before it starts, so it can't read the chat's last frame. The moment it ends, everything it could call stops working: its menu items and its network and sound callbacks are cut off, and the app closes the fonts, files, connections and players it opened. Lua still runs the program's `<close>` handlers as its stack unwinds. By then they can reach no file, network or menu (at most they draw with the images and other objects the program made), except after an out-of-memory error, when they run before the program's functions stop working; Stop program ends them either way. The chat only accepts a local test server in place of the real API address, so a key can't be redirected elsewhere.
- **Not kept out** (the fence's known limits):
  - A program shares the chat's memory, so a greedy one can use it all (the run then ends with "not enough memory").
  - While it runs, it can draw over the screen, play sound, and use the network, since the app has the `http` permission.
  - A program written to catch errors can ignore "Stop program": its own `pcall` or `xpcall` catches the stop, and so do `coroutine.resume`, `load` (in a reader function it is given) and the firmware, which runs network, sound and progress callbacks protected. So can a program whose `<close>` handlers each set up another before they loop, as each Stop ends only the handler that is running. **Exit App** in the system menu is the fallback.
- Reading a program before you run it is still a good habit.

A stronger wall would need firmware support (running a program as its own app, in its own Lua state); that is not built.

## Credits
The Sans reading font is converted from X.Org's Adobe bitmap fonts; [fonts/LICENSE](fonts/LICENSE) has the licence.
- Sans: Helvetica 12. Copyright 1984-1989, 1994 Adobe Systems Incorporated. Copyright 1988, 1994 Digital Equipment Corporation. Helvetica is a trademark of Linotype-Hell AG and/or its subsidiaries.

## Development
- `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
- `make e2e`: smoke tests in the PicoDeck simulator against a fake API server on `127.0.0.1` (the app reaches it through hidden `claude_base` / `openai_base` overrides in `prefs.json`). They need a PicoDeck checkout (`PICODECK_ROOT`, default `~/Projects/PicoDeck/picodeck`); run `make simulator` there first.
- [docs/device-checklist.md](docs/device-checklist.md): the checks to run on a real PicoCalc before a release.
- `tools/make_icon.py` redraws `icon.png`; `tools/record_stream.py` records real API streams for test fixtures.
- Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP, `picodeck-llmchat-v<version>.zip` (named after the tag).
