"""Small local BM25/vector search with frozen queries and transparent RRF."""

import math
import re
from collections import Counter
from pathlib import Path

import numpy as np

from common.files import fingerprint, read_json, tokens, write_json
from common.inputs import render_block

QUERIES = {
    "identity": [
        "project name identifier report number implementing agency",
        "publication date effectiveness actual closing implementation period",
    ],
    "geography": [
        "project implementation countries geographic coverage districts sites",
        "countries receiving support project components intervention locations",
    ],
    "rationale": [
        "climate risks drought flood vulnerability project rationale context",
        "target beneficiaries farmers livelihoods gender women social inclusion",
    ],
    "results": [
        "results framework indicator baseline original revised target actual achieved completion",
        "direct project beneficiaries farmers households reached actual total",
        "effectiveness outputs achieved hectares production income adoption failed shortfall",
    ],
    "finance": [
        "financing original amount total project cost grant credit cofinancing",
        "actual disbursed expenditure financing sources implementing agencies partners",
    ],
}


def words(text: str) -> list[str]:
    """Tokenize Unicode words and identifiers without language-model calls."""
    return re.findall(r"\w+", text.casefold())


def bm25(texts: list[str], query: str) -> np.ndarray:
    """Calculate BM25 with k1=1.5, b=0.75 and positive Robertson IDF."""
    counts = [Counter(words(text)) for text in texts]
    lengths = np.array([sum(c.values()) for c in counts], dtype=float)
    average = max(float(lengths.mean()), 1.0)
    scores = np.zeros(len(texts))
    for word in set(words(query)):
        frequencies = np.array([c[word] for c in counts], dtype=float)
        df = int(np.count_nonzero(frequencies))
        idf = math.log(1 + (len(texts) - df + 0.5) / (df + 0.5))
        denominator = frequencies + 1.5 * (0.25 + 0.75 * lengths / average)
        scores += idf * frequencies * 2.5 / denominator
    return scores


def ranking(scores: np.ndarray, positive_only: bool = False) -> list[int]:
    """Rank candidates deterministically, breaking ties by original order."""
    return [
        i
        for i in sorted(range(len(scores)), key=lambda i: (-scores[i], i))
        if not positive_only or scores[i] > 0
    ]


def embeddings(texts: list[str], client: object, cache: Path, config: dict) -> np.ndarray:
    """Embed uncached inputs in small batches and reuse vectors across trials."""
    keys = [fingerprint([config["embedding_model"], config["dimensions"], t]) for t in texts]
    vectors = {}
    for key in set(keys):
        path = cache / "embeddings" / f"{key}.json"
        if path.exists():
            vectors[key] = read_json(path)
    missing = list(dict.fromkeys(k for k in keys if k not in vectors))
    lookup = dict(zip(keys, texts, strict=True))
    for start in range(0, len(missing), 32):
        batch = missing[start : start + 32]
        values = client.embed([lookup[k] for k in batch])
        if len(values) != len(batch):
            raise ValueError("Embedding API returned the wrong number of vectors.")
        for key, value in zip(batch, values, strict=True):
            vectors[key] = value
            write_json(cache / "embeddings" / f"{key}.json", value)
    matrix = np.array([vectors[key] for key in keys], dtype=float)
    if matrix.shape != (len(texts), config["dimensions"]) or not np.isfinite(matrix).all():
        raise ValueError("Embedding dimensions or numeric values are invalid; rebuild this cache.")
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    if np.any(norms == 0):
        raise ValueError("Embedding API/cache returned a zero vector.")
    return matrix / norms


def retrieve(document: dict, group: str, client: object, cache: Path, config: dict) -> dict:
    """Search within one document and retain both retrieval channels for evaluation."""
    chunks = document["chunks"]
    texts = [c["search_text"] for c in chunks]
    queries = [
        q + (" " + document["focus"] if document.get("focus") else "") for q in QUERIES[group]
    ]
    matrix = embeddings(texts + queries, client, cache, config)
    vectors, query_vectors = matrix[: len(texts)], matrix[len(texts) :]
    fused = Counter()
    channel_scores = {"bm25": Counter(), "embedding": Counter()}
    query_runs = []
    for query, vector in zip(queries, query_vectors, strict=True):
        channels = {
            "bm25": ranking(bm25(texts, query), True),
            "embedding": ranking(vectors @ vector),
        }
        query_runs.append(
            {
                "query": query,
                **{
                    k: [chunks[i]["id"] for i in v[: config["candidate_count"]]]
                    for k, v in channels.items()
                },
            }
        )
        for channel, order in channels.items():
            for rank, index in enumerate(order[: config["candidate_count"]], 1):
                score = 1 / (config["rrf_constant"] + rank)
                fused[index] += score
                channel_scores[channel][index] += score
    order = sorted(fused, key=lambda i: (-fused[i], i))
    packed = pack(chunks, order, config["packet_tokens"])
    return {
        **packed,
        "queries": query_runs,
        "rankings": {
            "hybrid": [chunks[i]["id"] for i in order],
            **{
                key: [chunks[i]["id"] for i in sorted(value, key=lambda i: (-value[i], i))]
                for key, value in channel_scores.items()
            },
        },
        "scores": {chunks[i]["id"]: fused[i] for i in order},
    }


def pack(chunks: list[dict], order: list[int], budget: int) -> dict:
    """Pack unique evidence first, then same-section neighbors, without cutting tables."""
    selected, selected_text, excluded = [], set(), []
    used = 0

    # Relevant chunks get priority over adjacent context.
    neighbors = list(
        dict.fromkeys(
            j
            for i in order
            for j in (i - 1, i + 1)
            if 0 <= j < len(chunks) and chunks[j]["section_id"] == chunks[i]["section_id"]
        )
    )
    for index in list(order) + neighbors:
        chunk = chunks[index]
        identity = fingerprint([chunk["pages"], chunk["text"]])
        if index in selected or identity in selected_text:
            continue
        cost = tokens(render_block(chunk)) + 2
        if used + cost > budget:
            excluded.append(chunk["id"])
            continue
        selected.append(index)
        selected_text.add(identity)
        used += cost
    selected.sort()
    return {
        "text": "\n\n".join(render_block(chunks[i]) for i in selected),
        "selected": [chunks[i]["id"] for i in selected],
        "excluded": list(dict.fromkeys(excluded)),
        "tokens": used,
    }
