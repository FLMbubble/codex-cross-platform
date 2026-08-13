#!/usr/bin/env python3
"""从 rollout 文件提取元数据并注册/更新 Codex thread 到 state DB。

用法:
  python3 codex-thread-register.py <rollout_file> <state_db> [--remote-host HOST]

从 rollout 文件提取 first_user_message / preview / title，
然后 upsert 到 threads 表，确保 codex resume 能找到该会话。

根因修复：codex resume picker 使用 WHERE preview <> '' 过滤，
旧同步脚本 INSERT 时 preview='' 导致会话不可见。
"""
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone


def extract_first_user_message(rollout_path):
    """从 rollout 文件提取第一条真实用户消息。

    codex 的提取逻辑：
    1. 跳过以 <environment_context> 开头的系统注入消息
    2. 如果消息包含 '## My request for Codex:\\n'，取其后的部分
    3. 否则取完整文本（去除首尾空白）
    """
    with open(rollout_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") != "response_item":
                continue
            payload = d.get("payload", {})
            if payload.get("role") != "user":
                continue
            content = payload.get("content", [])
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") != "input_text":
                    continue
                text = item.get("text", "")
                if not text:
                    continue
                # 跳过系统注入的 environment_context
                if text.lstrip().startswith("<environment_context>"):
                    continue
                # Chrome 扩展格式：提取 '## My request for Codex:' 之后的内容
                if "## My request for Codex:" in text:
                    parts = text.split("## My request for Codex:\n", 1)
                    if len(parts) > 1 and parts[1].strip():
                        return parts[1].strip()
                # 普通格式：直接返回（去除首尾空白）
                stripped = text.strip()
                if stripped:
                    return stripped
    return ""


def extract_session_meta(rollout_path):
    """从 rollout 文件提取 session_meta 行的元数据。"""
    with open(rollout_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") == "session_meta":
                return d.get("payload", {})
    return {}


def register_thread(rollout_path, db_path, remote_cwd=None):
    """注册或更新 thread 到 state DB。

    Args:
        rollout_path: rollout .jsonl 文件的绝对路径
        db_path: state_5.sqlite 的绝对路径
        remote_cwd: 远程工作目录（如 None 则从 session_meta 提取）

    Returns:
        (action, session_id) 其中 action 为 'inserted' 或 'updated'
    """
    meta = extract_session_meta(rollout_path)
    session_id = meta.get("session_id") or meta.get("id")
    if not session_id:
        # 从文件名提取 UUID
        basename = os.path.basename(rollout_path)
        # rollout-YYYY-MM-DDTHH-MM-SS-<UUID>.jsonl
        parts = basename.rsplit("-", 1)
        if len(parts) == 2 and parts[1].endswith(".jsonl"):
            session_id = parts[1][:-6]
    if not session_id:
        raise ValueError("无法从 rollout 文件提取 session_id")

    first_user_message = extract_first_user_message(rollout_path)
    # preview / title / first_user_message 三者在 codex 中通常相同
    preview = first_user_message
    title = first_user_message or meta.get("title", "Synced session")

    # cwd: 优先用显式指定的 remote_cwd；
    # 否则从 session_meta 取，但如果该路径在当前机器上不存在（如本地路径在远程运行），
    # 则回退到当前工作目录或 $HOME
    meta_cwd = meta.get("cwd", "")
    if remote_cwd:
        cwd = remote_cwd
    elif meta_cwd and os.path.isdir(meta_cwd):
        cwd = meta_cwd
    else:
        cwd = os.getcwd()
    source = meta.get("source", "vscode")
    model_provider = meta.get("model_provider", "custom")
    cli_version = meta.get("cli_version", "")
    thread_source = meta.get("thread_source", "user")
    history_mode = meta.get("history_mode", "legacy")

    now = int(time.time())
    now_ms = now * 1000

    # 从 session_meta 的 timestamp 提取创建时间
    ts_str = meta.get("timestamp", "")
    created_at = now
    if ts_str:
        try:
            dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            created_at = int(dt.timestamp())
        except (ValueError, TypeError):
            pass
    created_at_ms = created_at * 1000

    db = sqlite3.connect(db_path)
    cur = db.cursor()

    # 检查是否已存在
    cur.execute("SELECT id FROM threads WHERE id=?", (session_id,))
    exists = cur.fetchone() is not None

    if exists:
        # 更新：确保 preview / first_user_message / title 非空，
        # 同时修正 model_provider / source / cwd（picker 用这些字段过滤）
        cur.execute(
            """UPDATE threads SET
               rollout_path = ?,
               archived = 0,
               model_provider = ?,
               source = ?,
               cwd = ?,
               preview = CASE WHEN preview = '' OR preview IS NULL THEN ? ELSE preview END,
               first_user_message = CASE WHEN first_user_message = '' OR first_user_message IS NULL THEN ? ELSE first_user_message END,
               title = CASE WHEN title = '' OR title IS NULL THEN ? ELSE title END,
               has_user_event = 1,
               updated_at = ?,
               updated_at_ms = ?,
               recency_at = ?,
               recency_at_ms = ?
               WHERE id = ?""",
            (rollout_path, model_provider, source, cwd,
             preview, first_user_message, title,
             now, now_ms, now, now_ms, session_id),
        )
        action = "updated"
    else:
        # 获取一个 sandbox_policy 模板（从现有 thread 复制）
        cur.execute("SELECT sandbox_policy FROM threads LIMIT 1")
        row = cur.fetchone()
        sandbox_policy = row[0] if row else "{}"

        cur.execute(
            """INSERT INTO threads
               (id, rollout_path, created_at, updated_at, source, model_provider,
                cwd, title, sandbox_policy, approval_mode, tokens_used,
                has_user_event, archived, cli_version, first_user_message,
                thread_source, preview, recency_at, recency_at_ms, history_mode,
                is_pinned, created_at_ms, updated_at_ms, memory_mode)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (session_id, rollout_path, created_at, now, source, model_provider,
             cwd, title, sandbox_policy, "on-request", 0,
             1, 0, cli_version, first_user_message,
             thread_source, preview, now, now_ms, history_mode,
             0, created_at_ms, now_ms, "enabled"),
        )
        action = "inserted"

    db.commit()
    db.close()
    return action, session_id


def main():
    if len(sys.argv) < 3:
        print(f"用法: {sys.argv[0]} <rollout_file> <state_db> [remote_cwd]")
        print(f"示例: {sys.argv[0]} ~/.codex/sessions/2026/08/03/rollout-*.jsonl ~/.codex/state_5.sqlite")
        sys.exit(1)

    rollout_path = os.path.expanduser(sys.argv[1])
    db_path = os.path.expanduser(sys.argv[2])
    remote_cwd = sys.argv[3] if len(sys.argv) > 3 else None

    if not os.path.exists(rollout_path):
        print(f"错误: rollout 文件不存在: {rollout_path}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(db_path):
        print(f"错误: state DB 不存在: {db_path}", file=sys.stderr)
        sys.exit(1)

    action, session_id = register_thread(rollout_path, db_path, remote_cwd)
    print(f"✓ thread {action}: {session_id}")
    print(f"  rollout: {rollout_path}")
    print(f"  db: {db_path}")


if __name__ == "__main__":
    main()
