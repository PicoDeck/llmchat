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
