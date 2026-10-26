-- LLM Chat: chat with Claude, and with the models on OpenCode, OpenRouter and
-- Vercel AI Gateway, on PicoDeck.
if not require then
    picocalc.ui.splash("LLM Chat needs a newer PicoDeck", "Update the firmware to 0.5.0 or later")
    picocalc.sys.sleep(3000)
    return
end
require("src.app").new(picocalc, APP_ID, APP_DIR):run()
