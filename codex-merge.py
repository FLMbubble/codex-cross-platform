#!/usr/bin/env python3
"""三方合并 Codex session 文件。
用法: python3 codex-merge.py <local_file> <remote_file> <output_file>
输出: NO_REMOTE_NEW | NO_LOCAL_NEW | MERGED:<details>
"""
import json, sys
from datetime import datetime, timezone

def now_str():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')

local_path, remote_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(local_path) as f:
    local_lines = f.readlines()
with open(remote_path) as f:
    remote_lines = f.readlines()

# 找共同前缀
common = 0
for i in range(min(len(local_lines), len(remote_lines))):
    try:
        ld = json.loads(local_lines[i])
        rd = json.loads(remote_lines[i])
        lt = ld.get("timestamp", "") + ld.get("type", "")
        rt = rd.get("timestamp", "") + rd.get("type", "")
        if lt != rt:
            break
        common = i + 1
    except:
        break

local_only = local_lines[common:]
remote_only = remote_lines[common:]

if not remote_only:
    with open(output_path, "w") as f:
        f.writelines(local_lines)
    print("NO_REMOTE_NEW")
    sys.exit(0)

if not local_only:
    with open(output_path, "w") as f:
        f.writelines(remote_lines)
    print("NO_LOCAL_NEW")
    sys.exit(0)

# 两边都有新内容：本地全部 + [合并标记] + 远程的对话条目
remote_items = []
for line in remote_only:
    try:
        d = json.loads(line)
        if d.get("type") == "response_item":
            payload = d.get("payload", {})
            if payload.get("role") in ("user", "assistant"):
                remote_items.append(line)
    except:
        pass

marker = json.dumps({
    "timestamp": now_str(),
    "type": "response_item",
    "payload": {
        "role": "user",
        "content": [{"type": "input_text", "text": f"[_auto_merged_from_remote] 远程会话新增 {len(remote_items)} 条对话"}]
    }
}) + "\n"

merged = local_lines + [marker] + remote_items

with open(output_path, "w") as f:
    f.writelines(merged)

print(f"MERGED: local_new={len(local_only)} remote_new={len(remote_items)}")
