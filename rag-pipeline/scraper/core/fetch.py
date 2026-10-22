"""HTTP client shared by every source: polite, retrying and safe to use from many threads."""

from __future__ import annotations

import contextlib
import logging
import random
import re
import threading
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import requests
from bs4 import BeautifulSoup

LOG = logging.getLogger("scraper")

USER_AGENT = "Mozilla/5.0 (compatible; AdaptationInsights/1.0; academic research)"
ROBOTS_AGENT = "adaptationinsights"
RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}
MAX_RETRY_AFTER_SECONDS = 300
CHUNK_BYTES = 1024 * 1024
MAX_REDIRECTS = 30


class RequestFailed(Exception):
    """A request failed after every retry, or failed in a way that a retry cannot fix."""

    def __init__(self, url: str, message: str, status: int | None = None) -> None:
        """Keep the URL and HTTP status so callers can record them."""
        super().__init__(f"{message}: {url}")
        self.url = url
        self.status = status


class BlockedByRobots(RequestFailed):
    """The site's robots.txt does not allow this URL."""


class Client:
    """One HTTP client per run: a session per thread and a rate limit per host."""

    def __init__(
        self,
        request_interval: float = 1.0,
        attempts: int = 4,
        timeout: float = 60,
        headers: dict[str, str] | None = None,
    ) -> None:
        """Set the per-host interval, retry count, timeout and extra default headers."""
        self.request_interval = request_interval
        self.attempts = attempts
        self.timeout = timeout
        self.headers = {"User-Agent": USER_AGENT, **(headers or {})}
        self.request_count = 0
        self._local = threading.local()
        self._lock = threading.Lock()
        self._robots_lock = threading.Lock()
        self._next_request: dict[str, float] = {}
        self._robots: dict[str, tuple[list[tuple[bool, str]], float]] = {}
        self._blocked: dict[str, RequestFailed] = {}

    @property
    def session(self) -> requests.Session:
        """Return this thread's session, creating it on first use."""
        session = getattr(self._local, "session", None)
        if session is None:
            session = requests.Session()
            session.headers.update(self.headers)
            self._local.session = session
        return session

    def get(
        self, url: str, params: dict | None = None, headers: dict | None = None
    ) -> requests.Response:
        """Send a GET request and return the successful response."""
        return self.request("GET", url, params=params, headers=headers)

    def get_json(
        self, url: str, params: dict | None = None, headers: dict | None = None
    ) -> dict | list:
        """Send a GET request and return the decoded JSON body."""
        response = self.get(url, params=params, headers=headers)
        try:
            return response.json()
        except ValueError as error:
            raise RequestFailed(url, f"Response is not JSON ({error})") from error

    def get_html(
        self, url: str, params: dict | None = None, headers: dict | None = None
    ) -> BeautifulSoup:
        """Send a GET request and return the page parsed as HTML."""
        response = self.get(url, params=params, headers=headers)
        return BeautifulSoup(response.content, "lxml")

    def get_xml(
        self, url: str, params: dict | None = None, headers: dict | None = None
    ) -> BeautifulSoup:
        """Send a GET request and return the body parsed as XML."""
        response = self.get(url, params=params, headers=headers)
        return BeautifulSoup(response.content, "xml")

    def post(
        self,
        url: str,
        data: dict | str | None = None,
        json_body: dict | list | None = None,
        headers: dict | None = None,
    ) -> requests.Response:
        """Send a POST request with form data or a JSON body."""
        return self.request("POST", url, data=data, json=json_body, headers=headers)

    def download(self, url: str, part_path: Path) -> dict:
        """Stream a file to part_path and return the final URL and byte count.

        The caller checks the file and renames it. A size that differs from
        Content-Length raises RequestFailed, so a cut connection is never kept.
        """
        response = self.request("GET", url, stream=True)
        try:
            with response, part_path.open("wb") as handle:
                for chunk in response.iter_content(CHUNK_BYTES):
                    handle.write(chunk)
        except (requests.RequestException, OSError) as error:
            raise RequestFailed(url, f"Download interrupted ({error})") from error

        # Compare with Content-Length only when the body was not re-encoded in transit.
        size = part_path.stat().st_size
        length = response.headers.get("Content-Length")
        encoded = response.headers.get("Content-Encoding")
        if length and not encoded and int(length) != size:
            raise RequestFailed(url, f"Received {size} bytes, Content-Length was {length}")
        return {"resolved_url": response.url, "bytes": size}

    def request(self, method: str, url: str, **options: object) -> requests.Response:
        """Send a request, following redirects one hop at a time.

        Each hop gets its own robots.txt check and rate limit, so a permitted page
        cannot redirect into a disallowed file.
        """
        # Put the query in the URL first, so robots rules see the URL actually requested.
        if options.get("params"):
            url = requests.Request(method, url, params=options.pop("params")).prepare().url
        for _ in range(MAX_REDIRECTS):
            response = self._request_once(method, url, allow_redirects=False, **options)
            if not response.is_redirect:
                return response
            response.close()

            # As in a browser, a 303, or a 301 or 302 after a POST, continues as a GET.
            if response.status_code == 303 or (
                response.status_code in {301, 302} and method == "POST"
            ):
                method = "GET"
                options.pop("data", None)
                options.pop("json", None)
            url = urljoin(url, response.headers["Location"])
        raise RequestFailed(url, "Too many redirects")

    def _request_once(self, method: str, url: str, **options: object) -> requests.Response:
        """Send one URL with its rate limit, robots.txt check and retries."""
        self._check_robots(url)
        host = urlsplit(url).netloc
        problem, status = "no attempt made", None
        for attempt in range(1, self.attempts + 1):
            self._wait_turn(host)
            with self._lock:
                if host in self._blocked:
                    raise self._blocked[host]
                self.request_count += 1
            try:
                response = self.session.request(method, url, timeout=self.timeout, **options)
            except requests.RequestException as error:
                problem, status, retry_after = str(error), None, 0.0
            else:
                if response.status_code < 400:
                    return response
                problem, status = f"HTTP {response.status_code}", response.status_code
                retry_after = retry_after_seconds(response.headers.get("Retry-After", ""))
                response.close()
                if status in {401, 403}:
                    raise self._block(host, RequestFailed(url, problem, status))
                if status not in RETRY_STATUSES:
                    raise RequestFailed(url, problem, status)

            # Back off before the next attempt. The pause applies to every thread on this host.
            if attempt == self.attempts:
                break
            if retry_after > MAX_RETRY_AFTER_SECONDS:
                raise RequestFailed(url, f"{problem}, Retry-After {retry_after:.0f}s", status)
            delay = max(retry_after, backoff_seconds(attempt))
            self._pause_host(host, delay)
            LOG.warning(
                "Retry %d of %d in %.1fs (%s): %s", attempt, self.attempts - 1, delay, problem, url
            )
        raise RequestFailed(url, f"{problem} after {self.attempts} attempts", status)

    def _wait_turn(self, host: str) -> None:
        """Sleep until this host may receive another request, then claim the slot."""
        while True:
            with self._lock:
                now = time.monotonic()
                ready_at = self._next_request.get(host, 0.0)
                if now >= ready_at:
                    crawl_delay = self._robots.get(host, ([], 0.0))[1]
                    self._next_request[host] = now + max(self.request_interval, crawl_delay)
                    return
                delay = ready_at - now
            time.sleep(delay)

    def _pause_host(self, host: str, delay: float) -> None:
        """Hold back every request to this host for at least delay seconds."""
        with self._lock:
            ready_at = time.monotonic() + delay
            self._next_request[host] = max(self._next_request.get(host, 0.0), ready_at)

    def _check_robots(self, url: str) -> None:
        """Raise BlockedByRobots when robots.txt disallows the URL."""
        parts = urlsplit(url)
        if parts.scheme not in {"http", "https"}:
            raise RequestFailed(url, "Only HTTP and HTTPS URLs are supported")
        with self._lock:
            if parts.netloc in self._blocked:
                raise self._blocked[parts.netloc]
        rules = self._robots_rules(parts.scheme, parts.netloc)[0]
        path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        if not robots_allows(rules, path):
            raise BlockedByRobots(url, "robots.txt disallows this URL")

    def _robots_rules(self, scheme: str, host: str) -> tuple[list[tuple[bool, str]], float]:
        """Cache robots rules; stop when a temporary failure prevents reading them."""
        with self._robots_lock:
            if host in self._robots:
                return self._robots[host]

            # Missing robots files allow crawling; outages and throttling do not grant access.
            rules: tuple[list[tuple[bool, str]], float] = ([], 0.0)
            robots_url = f"{scheme}://{host}/robots.txt"
            self._wait_turn(host)
            try:
                with self.session.get(robots_url, timeout=self.timeout) as response:
                    status = response.status_code
                    if status in {401, 403, 429} or status >= 500:
                        failure = RequestFailed(robots_url, "Cannot read robots.txt", status)
                        raise self._block(host, failure)
                    if status == 200:
                        # Some servers return their homepage for unknown paths (D-Portal,
                        # 2026-10-15). Parse valid directives regardless of the MIME type.
                        rules = parse_robots(response.text)
            except requests.RequestException as error:
                failure = RequestFailed(robots_url, f"Cannot read robots.txt ({error})")
                raise self._block(host, failure) from error
            self._robots[host] = rules
            return rules

    def _block(self, host: str, failure: RequestFailed) -> RequestFailed:
        """Remember that a host refused access, so later requests to it fail at once."""
        with self._lock:
            self._blocked[host] = failure
        return failure


def retry_after_seconds(value: str) -> float:
    """Read a Retry-After header given in seconds or as an HTTP date."""
    if not value:
        return 0.0
    try:
        return max(0.0, float(value))
    except ValueError:
        pass
    try:
        moment = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return 0.0
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return max(0.0, (moment - datetime.now(timezone.utc)).total_seconds())


def backoff_seconds(attempt: int) -> float:
    """Return an exponential backoff with a little jitter: about 1, 2, 4 ... up to 30 seconds."""
    return min(30.0, 2.0 ** (attempt - 1)) + random.uniform(0, 0.5)


def parse_robots(text: str, agent: str = ROBOTS_AGENT) -> tuple[list[tuple[bool, str]], float]:
    """Return the Allow and Disallow rules, and the Crawl-delay, that apply to our agent."""
    # Group the lines: consecutive User-agent lines share the rules that follow them.
    groups: list[tuple[list[str], list[tuple[bool, str]], list[float]]] = []
    previous_was_agent = False
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        field, value = (part.strip() for part in line.split(":", 1))
        field = field.lower()
        if field == "user-agent":
            if not previous_was_agent:
                groups.append(([], [], []))
            groups[-1][0].append(value.lower())
            previous_was_agent = True
            continue
        previous_was_agent = False
        if not groups:
            continue
        if field in {"allow", "disallow"} and value:
            groups[-1][1].append((field == "allow", value))
        elif field == "crawl-delay":
            with contextlib.suppress(ValueError):
                groups[-1][2].append(float(value))

    # Use the groups named for our agent; otherwise the groups for every agent.
    chosen = [group for group in groups if agent in group[0]]
    if not chosen:
        chosen = [group for group in groups if "*" in group[0]]
    rules = [rule for group in chosen for rule in group[1]]
    delays = [delay for group in chosen for delay in group[2]]
    return rules, max(delays, default=0.0)


def robots_allows(rules: list[tuple[bool, str]], path: str) -> bool:
    """Apply robots.txt rules: the longest matching rule wins, Allow wins a tie."""
    best_length, allowed = -1, True
    for allow, pattern in rules:
        if not robots_pattern(pattern).match(path):
            continue
        if len(pattern) > best_length or (len(pattern) == best_length and allow):
            best_length, allowed = len(pattern), allow
    return allowed


def robots_pattern(pattern: str) -> re.Pattern:
    """Turn a robots.txt path pattern with * and $ into a regular expression."""
    anchored = pattern.endswith("$")
    body = re.escape(pattern.rstrip("$")).replace(r"\*", ".*")
    return re.compile(body + ("$" if anchored else ""))
