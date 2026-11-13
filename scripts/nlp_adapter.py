#!/usr/bin/env python3
"""Host-side NLP adapter (续四十五).

MemoryCorridor stays a memory/knowledge engine: the MoonBit core never calls a
model. This adapter is the host's perception layer for two jobs:

  affect  user text -> {valence, arousal, salience, topics, entities}
  expand  query     -> {queries: [original, ...]}

Both have a deterministic lexicon provider (tests, offline) and an optional
OpenAI-compatible provider (real deployments). The output is structured input
for the engine (`evo-observe`, `search.queries`), never a write.

Usage:
  python3 scripts/nlp_adapter.py affect --text "今天很开心"
  python3 scripts/nlp_adapter.py affect --text "..." --provider llm
  python3 scripts/nlp_adapter.py expand --query "青瓷的来源"
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.request

POSITIVE = ["开心", "高兴", "喜欢", "满意", "期待", "感谢", "顺利", "成功", "温暖",
            "安心", "有趣", "惊喜", "爱", "优秀", "希望", "轻松", "快乐", "赞",
            "good", "great", "happy", "love", "nice", "thanks", "excited",
            "calm", "wonderful", "glad"]
NEGATIVE = ["难过", "生气", "焦虑", "担心", "失望", "失败", "痛苦", "孤独", "害怕",
            "烦躁", "讨厌", "糟糕", "崩溃", "压力", "烦", "差", "坏",
            "bad", "sad", "angry", "anxious", "worried", "fail", "hate",
            "awful", "tired", "stress", "lonely", "afraid"]
INTENSIFIERS = ["非常", "特别", "太", "超", "极", "很", "really", "very", "so",
                "extremely"]
NEGATIONS = ["不", "没", "无", "别", "未", "not", "no", "never"]
TOPIC_WORDS = ["记忆", "来源", "资料", "页面", "证据", "知识", "项目", "情感",
               "人格", "梦", "检索", "向量", "青瓷", "memory", "source",
               "evidence", "knowledge", "search", "vector", "emotion"]
SYNONYMS = {
    "记忆": ["回忆", "记性"], "来源": ["出处", "证据"], "青瓷": ["瓷器", "陶瓷"],
    "检索": ["搜索", "查找"], "情感": ["情绪", "感受"], "人格": ["性格", "个性"],
    "梦": ["梦境", "睡眠"], "资料": ["材料", "文档"],
    "memory": ["recall", "recollection"], "source": ["origin", "evidence"],
    "search": ["retrieve", "lookup"], "emotion": ["feeling", "affect"],
}


def clamped(value, low, high):
    return max(low, min(high, float(value)))


def has_near(text, index, words, width=3):
    window = text[max(0, index - width):index]
    return any(word in window for word in words)


def lexicon_affect(text):
    lowered = text.lower()
    pos = 0.0
    neg = 0.0
    for word in POSITIVE:
        start = 0
        while True:
            index = lowered.find(word, start)
            if index < 0:
                break
            weight = 1.5 if has_near(lowered, index, INTENSIFIERS) else 1.0
            if has_near(lowered, index, NEGATIONS):
                neg += weight
            else:
                pos += weight
            start = index + len(word)
    for word in NEGATIVE:
        start = 0
        while True:
            index = lowered.find(word, start)
            if index < 0:
                break
            weight = 1.5 if has_near(lowered, index, INTENSIFIERS) else 1.0
            if has_near(lowered, index, NEGATIONS):
                pos += weight
            else:
                neg += weight
            start = index + len(word)
    hits = pos + neg
    valence = clamped((pos - neg) / (hits + 1.0), -1.0, 1.0)
    marks = text.count("!") + text.count("！") + text.count("?") + text.count("？")
    intensifiers = sum(1 for word in INTENSIFIERS if word in lowered)
    arousal = clamped(0.2 + 0.08 * marks + 0.06 * intensifiers +
                      min(len(text) / 400.0, 0.3), 0.0, 1.0)
    salience = clamped(0.3 + 0.1 * hits + min(len(text) / 200.0, 0.3), 0.0, 1.0)
    topics = [word for word in TOPIC_WORDS if word in lowered]
    topics = sorted(set(topics))[:8]
    return {
        "valence": valence, "arousal": arousal, "salience": salience,
        "topics": topics, "entities": [],
        "provider": "lexicon",
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "chars": len(text),
    }


def llm_json(system, user, endpoint, model, key):
    if not endpoint or not model:
        raise RuntimeError("set NLP_LLM_ENDPOINT and NLP_LLM_MODEL")
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "max_tokens": 256,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions",
                                     data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"].strip()


def parse_json_object(text):
    value = json.loads(text)
    if not isinstance(value, dict):
        raise RuntimeError("model did not return a JSON object")
    return value


def affect(text, provider="lexicon", endpoint=None, model=None, key=None):
    if not text:
        raise RuntimeError("empty text")
    if len(text.encode("utf-8")) > 8192:
        raise RuntimeError("text too long")
    if provider == "lexicon":
        return lexicon_affect(text)
    if provider != "llm":
        raise RuntimeError("unknown provider: " + provider)
    raw = llm_json(
        "Return only JSON: {\"valence\": -1..1, \"arousal\": 0..1, "
        "\"salience\": 0..1, \"topics\": [..], \"entities\": [..]}. "
        "Do not explain.", text, endpoint, model, key)
    value = parse_json_object(raw)
    topics = value.get("topics") or []
    entities = value.get("entities") or []
    for items in (topics, entities):
        if not isinstance(items, list) or len(items) > 16:
            raise RuntimeError("model list field invalid")
        if any(not isinstance(item, str) or not item or len(item) > 64 for item in items):
            raise RuntimeError("model list item invalid")
    return {
        "valence": clamped(value.get("valence", 0.0), -1.0, 1.0),
        "arousal": clamped(value.get("arousal", 0.0), 0.0, 1.0),
        "salience": clamped(value.get("salience", 0.0), 0.0, 1.0),
        "topics": topics, "entities": entities,
        "provider": "llm",
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "chars": len(text),
    }


def expand(query, provider="lexicon", endpoint=None, model=None, key=None):
    if not query or len(query.encode("utf-8")) > 1024:
        raise RuntimeError("query invalid")
    if provider == "lexicon":
        lowered = query.lower()
        expansions = []
        for word, alternatives in SYNONYMS.items():
            if word in lowered:
                for alternative in alternatives:
                    candidate = query + " " + alternative
                    if candidate not in expansions:
                        expansions.append(candidate)
        return {"queries": [query] + expansions[:7], "provider": "lexicon",
                "query_sha256": hashlib.sha256(query.encode("utf-8")).hexdigest()}
    if provider != "llm":
        raise RuntimeError("unknown provider: " + provider)
    raw = llm_json(
        "Return only JSON: {\"queries\": [strings]}. Produce 1-8 short search "
        "queries including the original meaning; no explanation.",
        query, endpoint, model, key)
    value = parse_json_object(raw)
    queries = value.get("queries")
    if not isinstance(queries, list) or not 1 <= len(queries) <= 8:
        raise RuntimeError("model queries invalid")
    clean = []
    for item in queries:
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > 256:
            raise RuntimeError("model query invalid")
        clean.append(item)
    return {"queries": clean, "provider": "llm",
            "query_sha256": hashlib.sha256(query.encode("utf-8")).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description="Host-side NLP adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    affect_parser = sub.add_parser("affect")
    affect_parser.add_argument("--text", required=True)
    affect_parser.add_argument("--provider", default="lexicon", choices=["lexicon", "llm"])
    affect_parser.add_argument("--endpoint", default=os.environ.get("NLP_LLM_ENDPOINT"))
    affect_parser.add_argument("--model", default=os.environ.get("NLP_LLM_MODEL"))
    affect_parser.add_argument("--api-key", default=os.environ.get("NLP_LLM_API_KEY"))
    expand_parser = sub.add_parser("expand")
    expand_parser.add_argument("--query", required=True)
    expand_parser.add_argument("--provider", default="lexicon", choices=["lexicon", "llm"])
    expand_parser.add_argument("--endpoint", default=os.environ.get("NLP_LLM_ENDPOINT"))
    expand_parser.add_argument("--model", default=os.environ.get("NLP_LLM_MODEL"))
    expand_parser.add_argument("--api-key", default=os.environ.get("NLP_LLM_API_KEY"))
    args = parser.parse_args()
    try:
        if args.command == "affect":
            result = affect(args.text, args.provider, args.endpoint, args.model, args.api_key)
        else:
            result = expand(args.query, args.provider, args.endpoint, args.model, args.api_key)
    except Exception as error:  # noqa: BLE001 - CLI reports, does not traceback
        print(f"nlp_adapter: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())