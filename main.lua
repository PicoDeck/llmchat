-- LLM Chat: chat with Claude and OpenAI models on PicoDeck.
if not require then
    picocalc.ui.splash("LLM Chat needs a newer PicoDeck", "Update the firmware to 0.2.0 or later")
    picocalc.sys.sleep(3000)
    return
end
require("src.app").new(picocalc, APP_ID, APP_DIR):run()
