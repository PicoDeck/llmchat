"""tools/record_stream.py without the network or the owner's keys.

Every test points KEYS, FIXTURES and SPEND into its own tmp_path, and post()
fails the test if anything calls it, so nothing here reads
~/.config/llmchat/keys.txt or sends a request."""
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import record_stream as rs  # noqa: E402

KEY = "sk-ant-test-0123456789"


@pytest.fixture(autouse=True)
def offline(tmp_path, monkeypatch):
    def no_post(*_):
        raise AssertionError("a test tried to send a request")
    monkeypatch.setattr(rs, "post", no_post)
    monkeypatch.setattr(rs, "KEYS", str(tmp_path / "no-keys.txt"))
    monkeypatch.setattr(rs, "FIXTURES", str(tmp_path / "fixtures"))
    monkeypatch.setattr(rs, "SPEND", str(tmp_path / "docs" / "research" / "api-spend.md"))
    os.makedirs(rs.FIXTURES)


def keys_file(path, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("claude=%s\nopenai=sk-test-9876543210\n" % KEY)
    path.chmod(mode)
    return str(path)


@pytest.mark.parametrize("mode", [0o640, 0o620, 0o604, 0o602, 0o644, 0o660, 0o666])
def test_load_key_refuses_a_file_others_can_read_or_write(tmp_path, monkeypatch, capsys, mode):
    monkeypatch.setattr(rs, "KEYS", keys_file(tmp_path / "keys.txt", mode))
    with pytest.raises(SystemExit) as e:
        rs.load_key("claude")
    msg = str(e.value)
    assert "chmod 600 " in msg
    out = capsys.readouterr()
    for text in (msg, out.out, out.err):
        assert "sk-" not in text


def test_load_key_message_names_the_path_to_chmod(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(rs, "KEYS", keys_file(tmp_path / ".config" / "llmchat" / "keys.txt", 0o644))
    with pytest.raises(SystemExit) as e:
        rs.load_key("openai")
    assert "chmod 600 ~/.config/llmchat/keys.txt" in str(e.value)
    assert "sk-" not in str(e.value)


@pytest.mark.parametrize("mode", [0o600, 0o400, 0o700])
def test_load_key_reads_a_private_file(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(rs, "KEYS", keys_file(tmp_path / "keys.txt", mode))
    assert rs.load_key("claude") == KEY


def test_scrub_replaces_every_kind_of_id():
    text = "\n".join([
        'event: response.output_item.added',
        'data: {"type":"response.output_item.added","item":{"id":"rs_68ab01cd23ef","type":"reasoning"}}',
        'data: {"item":{"id":"fc_68cd45ef67ab","call_id":"call_9"},"item_id":"msg_68ef89ab01cd"}',
        'data: {"type":"item_reference","id":"item_Bx9aQ2rT7"}',
        '{"id":"msg_01XFDUDYJgAACzvnptvVoYEL","request_id":"req_011CUabc9","response":{"id":"resp_68ab12"}}',
        'Authorization: Bearer %s' % KEY,
    ])
    out = rs.scrub(text)
    for kept in ('response.output_item.added', '"item_id":', '"type":"item_reference"', '"call_id":"call_9"'):
        assert kept in out, kept
    for gone in ("rs_68ab01cd23ef", "fc_68cd45ef67ab", "msg_68ef89ab01cd", "item_Bx9aQ2rT7",
                 "msg_01XFDUDYJgAACzvnptvVoYEL", "req_011CUabc9", "resp_68ab12", KEY):
        assert gone not in out, gone
    for fixture in ("rs_fixture", "fc_fixture", "item_fixture", "msg_fixture", "req_fixture", "resp_fixture"):
        assert fixture in out, fixture


CLAUDE_TEXT = "\n".join([
    'event: message_start',
    'data: {"type":"message_start","message":{"id":"msg_01Abc9","model":"claude-haiku-5-5",'
    '"usage":{"input_tokens":1000,"output_tokens":1}}}',
    '',
    'event: message_delta',
    'data: {"type":"message_delta","usage":{"output_tokens":2000}}',
    '',
])
ERROR_BODY = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'


def spend_rows():
    return [line for line in Path(rs.SPEND).read_text().splitlines() if line.startswith("| ")]


def test_log_spend_writes_the_header_once():
    rs.log_spend("claude", "text", 200, CLAUDE_TEXT)
    rs.log_spend("claude", "text", 200, CLAUDE_TEXT)
    text = Path(rs.SPEND).read_text()
    assert text.startswith("# API spend\n")
    assert text.count("| case | status | model | in | out | cost |") == 1
    rows = spend_rows()
    assert rows[0] == "| case | status | model | in | out | cost |"
    assert rows[1:] == ["| claude-text | 200 | claude-haiku-5-5 | 1000 | 2000 | $0.0011 |"] * 2


def test_log_spend_adds_rows_to_an_existing_log():
    os.makedirs(os.path.dirname(rs.SPEND))
    Path(rs.SPEND).write_text("# API spend\n\n| case | status | model | in | out | cost |\n|---|---|---|---|---|---|\n")
    rs.log_spend("claude", "text", 200, CLAUDE_TEXT)
    assert Path(rs.SPEND).read_text().count("| case |") == 1
    assert spend_rows()[-1] == "| claude-text | 200 | claude-haiku-5-5 | 1000 | 2000 | $0.0011 |"


@pytest.mark.parametrize("status, body", [(401, ERROR_BODY), (529, ERROR_BODY), (502, "<html>Bad gateway</html>")])
def test_log_spend_error_body_is_a_clear_row(capsys, status, body):
    rs.log_spend("claude", "401", status, body)
    assert spend_rows()[-1] == "| claude-401 | %d | - | 0 | 0 | $0.0000 |" % status
    assert "not billed" in capsys.readouterr().out


def test_main_records_without_a_real_request(monkeypatch):
    monkeypatch.setattr(rs, "load_key", lambda provider: KEY)
    monkeypatch.setattr(rs, "post", lambda provider, case, key: (200, CLAUDE_TEXT + "x-api-key: " + key + "\n"))
    rs.main(["claude", "text"])
    saved = Path(rs.FIXTURES, "claude-text.sse").read_text()
    assert "msg_fixture" in saved and "msg_01Abc9" not in saved
    assert KEY not in saved
    assert spend_rows()[-1].startswith("| claude-text | 200 | claude-haiku-5-5 |")


def test_main_401_records_the_error_row(monkeypatch):
    monkeypatch.setattr(rs, "post", lambda provider, case, key: (401, ERROR_BODY))
    rs.main(["claude", "401"])
    assert Path(rs.FIXTURES, "claude-401.json").read_text().startswith("#status 401\n")
    assert spend_rows()[-1] == "| claude-401 | 401 | - | 0 | 0 | $0.0000 |"


def test_dry_run_reads_no_key_and_sends_nothing(monkeypatch, capsys):
    def no_key(provider):
        raise AssertionError("--dry-run read a key")
    monkeypatch.setattr(rs, "load_key", no_key)
    rs.main(["openai", "reasoning", "--dry-run"])
    out = capsys.readouterr().out
    assert out.startswith("POST https://api.openai.com/v1/responses")
    assert "Bearer <key>" in out
    assert not os.path.exists(rs.SPEND)
