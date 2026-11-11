-- LLM Chat: chat with Claude, and with the models on OpenCode, OpenRouter and
-- Vercel AI Gateway, on PicoDeck.
-- 0.7.0: require (0.5.0) and picocalc.gamepad.getNavPressed, which every screen reads.
if not require or not (picocalc.gamepad and picocalc.gamepad.getNavPressed) then
    picocalc.ui.splash("LLM Chat needs a newer PicoDeck", "Update the firmware to 0.7.0 or later")
    picocalc.sys.sleep(3000)
    return
end
require("src.app").new(picocalc, APP_ID, APP_DIR):run()
