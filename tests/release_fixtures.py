"""Shared fixtures: GitHub release and issue objects as the API returns them.

Release bodies carry verified-train lines in the form promote.yml appends
them; test_workflow_contract.py holds the fixture to what promote.yml
actually writes, so a format change breaks CI instead of orphaning it.
"""
from datetime import datetime, timedelta


def marker(train):
    return f"<!-- verified-train: {train} -->"


def release(tag, prerelease=False, draft=False, trains=(), body=None,
            published=None):
    """A release tagged v<N>. Published N hours after a fixed base, so a
    higher run number is newer unless `published` says otherwise."""
    run = int(tag[1:]) if tag[1:].isdigit() else 0
    if published is None:
        published = (datetime(2026, 1, 1) + timedelta(hours=run)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    if body is None:
        body = "The **NVIDIA driver installer** for TrueNAS.\n"
        for t in trains:
            body += f"\n\n{marker(t)}\n"
    return {"id": run or abs(hash(tag)), "tag_name": tag, "body": body,
            "prerelease": prerelease, "draft": draft,
            "html_url": f"https://example.test/releases/tag/{tag}",
            "published_at": published, "created_at": published}


def issue(tag, train=None, labels=("hardware-test",), number=1, title=None):
    """A hardware-test issue with the markers release.yml writes."""
    body = f"**Release:** {tag}\n<!-- release-tag: {tag} -->\n"
    if train:
        body += f"<!-- train: {train} -->\n"
    return {"number": number, "title": title or f"Hardware test: installer {tag}",
            "body": body, "labels": [{"name": name} for name in labels]}
