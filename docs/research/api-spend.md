# API spend

Written by tools/record_stream.py, a row per request. An error reply is not billed.

| case | status | model | in | out | cost |
|---|---|---|---|---|---|
| claude-text | 200 | claude-opus-5-5 | 39 | 70 | $0.0016 |
| claude-thinking | 200 | claude-haiku-5-5 | 37 | 112 | $0.0001 |
| claude-maxtokens | 200 | claude-opus-5-5 | 39 | 20 | $0.0006 |
| claude-title | 200 | claude-haiku-5-5 | 58 | 13 | $0.0000 |
| claude-401 | 401 | - | 0 | 0 | $0.0000 |
| gateway probe: openrouter x3 (deepseek, minimax, gemini) | 401 | - | 0 | 0 | $0.0000 |
| gateway probe: vercel | 200 | deepseek/deepseek-v4.1-flash-1017 | 44 | 47 | $0.0000 (BYOK: upstream $0.00003) |
| gateway probe: opencode | 200 | deepseek-v4.1-flash | 44 | 51 | $0.0001 |
| gateway probe: bad key x3 | 401 | - | 0 | 0 | $0.0000 |
| gateway probe: vercel | 200 | minimax/minimax-m3.1-flash | 208 | 46 | $0.0000 |
| gateway probe: vercel | 200 | google/gemini-3.8-flash | 14 | 28 | $0.0001 |
| probe opencode long effort=low | 403 | deepseek-v4.1-flash | 0 | 0 | $0.0000 |
| probe vercel long effort=low | 200 | google/gemini-3.8-flash | 38 | 3313 | $0.0125 |
| probe vercel long effort=low | 200 | deepseek/deepseek-v4.1-flash-1017 | 62 | 6155 | $0.0000 |
| probe vercel long effort=low | 200 | minimax/minimax-m3.1-flash | 226 | 5979 | $0.0036 |
| probe opencode long effort=low | 200 | deepseek-v4.1-flash | 62 | 7072 | $0.0085 |
| probe vercel effort=low | 200 | mistral/mistral-small | 37 | 30 | $0.0000 |
| probe vercel effort=low | 200 | amazon/nova-micro | 20 | 14 | $0.0000 |
| probe opencode effort=low | 400 | mistral-large-4 | 0 | 0 | $0.0000 |
| probe opencode effort=none | 200 | mistral-large-4 | 25 | 414 | $0.0009 |
| probe opencode effort=medium | 400 | mistral-large-4 | 0 | 0 | $0.0000 |
| probe opencode effort=high | 200 | mistral-large-4 | 25 | 403 | $0.0009 |
| probe opencode effort=low | 200 | glm-5.3-flash | 33 | 33 | $0.0000 |
| probe opencode effort=low | 403 | kimi-k3 | 0 | 0 | $0.0000 |
| probe opencode effort=low | 200 | minimax-m3 | 138 | 54 | $0.0001 |
| probe opencode effort=low | 200 | qwen3.8-max | 61 | 59 | $0.0005 |
| probe opencode effort=low | 200 | deepseek-v4-pro | 24 | 43 | $0.0002 |
| vercel-text | 200 | deepseek/deepseek-v4.1-flash-1017 | 50 | 53 | $0.0001 |
| vercel-reasoning | 200 | deepseek/deepseek-v4.1-flash-1017 | 51 | 53 | $0.0001 |
| vercel-length | 200 | deepseek/deepseek-v4.1-flash-1017 | 50 | 40 | $0.0001 |
| vercel-title | 200 | deepseek/deepseek-v4.1-flash-1017 | 67 | 64 | $0.0001 |
| vercel-401 | 401 | - | 0 | 0 | $0.0000 |
| opencode-text | 200 | deepseek-v4.1-flash | 50 | 43 | $0.0001 |
| opencode-reasoning | 200 | deepseek-v4.1-flash | 51 | 51 | $0.0001 |
| opencode-length | 200 | deepseek-v4.1-flash | 50 | 40 | $0.0001 |
| opencode-title | 200 | deepseek-v4.1-flash | 67 | 64 | $0.0001 |
| opencode-401 | 401 | - | 0 | 0 | $0.0000 |
| openrouter-401 | 401 | - | 0 | 0 | $0.0000 |
| device check: anthropic key (laptop, 1 token) and the device chat | 401 | - | 0 | 0 | $0.0000 |
| device check: vercel chat + title (estimated; BYOK, upstream) | 200 | deepseek/deepseek-v4.1-flash-1017 | ~200 | ~150 | ~$0.0001 |
| device check: opencode chat + title (estimated) | 200 | deepseek-v4.1-flash | ~300 | ~150 | ~$0.0002 |
| connection-lost debug: d20 reply timed on the laptop (BYOK, upstream) | 200 | deepseek/deepseek-v4.1-flash-1017 | 4956 | 2596 | $0.0016 |
| connection-lost debug: 7 d20 replies on the device, 3 complete, 4 cut (estimated; BYOK, upstream) | 200 | deepseek/deepseek-v4.1-flash-1017 | ~35000 | ~15000 | ~$0.012 |
| connection-lost debug: opencode replay (laptop key rejected) | 401 | - | 0 | 0 | $0.0000 |
| connection-lost debug: 5 long program replies on the device (2 cut, 3 complete) plus titles (estimated; BYOK, upstream) | 200 | deepseek/deepseek-v4.1-flash-1017 | ~30000 | ~35000 | ~$0.045 |
