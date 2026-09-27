import json
import os
import re
import urllib.error
import urllib.request

import boto3

_REPO = os.environ.get("GITHUB_DISPATCH_REPO", "Arshdeep54/nitor-deploy")
_EVENT = os.environ.get("GITHUB_DISPATCH_EVENT", "nitor-release")
_MIGRATE_REPO = os.environ.get("ECR_MIGRATE_REPOSITORY", "tracker/migrate")
_TAG_RE = re.compile(r"^v")


def _dispatch(tag: str, token: str) -> None:
    body = json.dumps(
        {
            "event_type": _EVENT,
            "client_payload": {
                "tag": tag,
                "release_api": True,
                "release_agent": True,
                "run_migrations": True,
                "source": "ecr",
            },
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.github.com/repos/{_repo}/dispatches",
        data=body,
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            if res.status not in (200, 204):
                raise RuntimeError(f"unexpected status {res.status}")
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub dispatch failed {e.code}: {payload}") from e


def handler(event, context):
    detail = event.get("detail") or {}
    if detail.get("action-type") != "PUSH" or detail.get("result") != "SUCCESS":
        return {"skipped": "not a successful push"}
    if detail.get("repository-name") != _MIGRATE_REPO:
        return {"skipped": "not migrate repository"}
    tag = detail.get("image-tag") or detail.get("imageTag")
    if not tag or not _TAG_RE.match(tag):
        return {"skipped": "tag not a release version"}
    secret_id = os.environ.get("GITHUB_TOKEN_SECRET_ID")
    if not secret_id:
        raise RuntimeError("GITHUB_TOKEN_SECRET_ID is not set")
    sm = boto3.client("secretsmanager")
    token = (sm.get_secret_value(SecretId=secret_id).get("SecretString") or "").strip()
    if not token:
        raise RuntimeError("GitHub token secret is empty")
    _dispatch(tag, token)
    return {"dispatched": tag}
