# API spend

Written by tools/record_stream.py, a row per request. An error reply is not billed.

| case | status | model | in | out | cost |
|---|---|---|---|---|---|
| claude-text | 200 | claude-opus-5-5 | 39 | 70 | $0.0016 |
| claude-thinking | 200 | claude-haiku-5-5 | 37 | 112 | $0.0001 |
| claude-maxtokens | 200 | claude-opus-5-5 | 39 | 20 | $0.0006 |
| claude-title | 200 | claude-haiku-5-5 | 58 | 13 | $0.0000 |
| claude-401 | 401 | - | 0 | 0 | $0.0000 |
