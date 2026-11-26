"""Tests for the YouTube Lounge long-poll chunk parser in lib/lounge.uc.

The Lounge /bc/bind long-poll response is a stream of length-prefixed JSON
chunks. Each chunk is a decimal length line followed by that many bytes of
JSON (the length counts the trailing newline). uclient delivers the stream in
arbitrary chunks, so the parser must reassemble complete events across reads.

These tests model the parser as a stateful incremental decoder and verify that
every complete event is delivered exactly once, regardless of how the byte
stream is split across reads. They run on plain host Python (no ucode
interpreter needed) and mirror the algorithm implemented in
`_process_subscribe_buffer()`.
"""

from __future__ import annotations

import unittest


def _encode_event(event_id: int, event_type: str, *args) -> str:
    """Encode a single Lounge event as a length-prefixed chunk."""
    payload = [event_id, event_type, *args]
    body = __import__("json").dumps(payload, separators=(",", ":"))
    # The length line counts the JSON bytes plus the trailing newline.
    return f"{len(body) + 1}\n{body}\n"


def _encode_batch(events) -> str:
    return "".join(_encode_event(*e) for e in events)


class _StatefulDecoder:
    """Reference implementation of the fixed chunk parser.

    Mirrors the corrected `_process_subscribe_buffer()`: the in-progress chunk
    length and accumulated JSON are kept as state across reads, and the buffer
    is reset when a new subscription starts. The parser is byte-oriented: it
    reads a length line up to the newline, then consumes exactly that many
    bytes of content, so a chunk is never mis-parsed when the stream is split
    at an arbitrary point.
    """

    def __init__(self):
        self.buffer = ""
        self.chunk_remaining = -1  # -1 = waiting for a length line
        self.current_chunk = ""
        self.delivered = []

    def reset(self):
        """Called when a new subscription starts (drops stale partial data)."""
        self.buffer = ""
        self.chunk_remaining = -1
        self.current_chunk = ""

    def feed(self, data: str) -> list:
        """Feed a network read; returns the events completed by this read."""
        self.buffer += data
        return self._process()

    def _process(self) -> list:
        delivered = []
        while True:
            if self.chunk_remaining < 0:
                # Waiting for a length line (terminated by newline).
                nl = self.buffer.find("\n")
                if nl < 0:
                    break  # need more data
                line = self.buffer[:nl]
                self.buffer = self.buffer[nl + 1:]
                try:
                    self.chunk_remaining = int(line)
                except ValueError:
                    self.chunk_remaining = 0
                self.current_chunk = ""
                if self.chunk_remaining == 0:
                    # Invalid zero-length chunk; skip it.
                    self.chunk_remaining = -1
            else:
                # Reading content: consume up to chunk_remaining bytes.
                if len(self.buffer) == 0:
                    break  # need more data
                take = min(self.chunk_remaining, len(self.buffer))
                self.current_chunk += self.buffer[:take]
                self.buffer = self.buffer[take:]
                self.chunk_remaining -= take
                if self.chunk_remaining == 0:
                    # The length counts the trailing newline; strip it.
                    delivered.append(self.current_chunk.rstrip("\n"))
                    self.current_chunk = ""
                    self.chunk_remaining = -1
        self.delivered.extend(delivered)
        return delivered


class _BuggyDecoder:
    """The original buggy parser: chunk state is local to each call.

    This reproduces the pre-fix `_process_subscribe_buffer()`, where
    `chunk_remaining`/`current_chunk` are recomputed from scratch on every read
    and the partial buffer is not reset between subscriptions.
    """

    def __init__(self):
        self.buffer = ""
        self.delivered = []

    def reset(self):
        self.buffer = ""

    def feed(self, data: str) -> list:
        self.buffer += data
        return self._process()

    def _process(self) -> list:
        delivered = []
        buf = self.buffer
        lines = buf.split("\n")
        complete = "\n".join(lines[:-1]) + ("\n" if len(lines) > 1 else "")
        self.buffer = lines[-1]

        chunk_remaining = 0
        current_chunk = ""
        clines = complete.split("\n") if complete else []
        for line in clines:
            if chunk_remaining <= 0:
                try:
                    chunk_remaining = int(line)
                except ValueError:
                    chunk_remaining = 0
                current_chunk = ""
            else:
                current_chunk += line
                chunk_remaining -= len(line) + 1
                if chunk_remaining == 0:
                    delivered.append(current_chunk)
                    current_chunk = ""
        return delivered


class LoungeChunkParserTests(unittest.TestCase):
    """Verify the fixed parser delivers each event exactly once."""

    def _make(self):
        return _StatefulDecoder()

    def test_single_event_in_one_read(self):
        dec = self._make()
        out = dec.feed(_encode_event(1, "onStateChange", {"state": "1"}))
        self.assertEqual(len(out), 1)
        self.assertEqual(dec.delivered, out)

    def test_length_line_then_content_in_separate_reads(self):
        # The length line arrives in the first read, the JSON in the second.
        stream = _encode_event(1, "nowPlaying", {"videoId": "abc", "state": "1"})
        dec = self._make()
        split_at = stream.index("\n") + 1  # after the length line
        self.assertEqual(dec.feed(stream[:split_at]), [])
        out = dec.feed(stream[split_at:])
        self.assertEqual(len(out), 1)

    def test_content_split_across_many_reads(self):
        stream = _encode_event(1, "onAdStateChange", {"adState": "0", "isSkipEnabled": "true"})
        dec = self._make()
        # Feed one byte at a time; the event must still be delivered once.
        for i in range(len(stream) - 1):
            self.assertEqual(dec.feed(stream[i]), [])
        out = dec.feed(stream[-1])
        self.assertEqual(len(out), 1)

    def test_multiple_events_in_one_read(self):
        events = [
            (1, "onStateChange", {"state": "1"}),
            (2, "nowPlaying", {"videoId": "x", "state": "2"}),
            (3, "onAdStateChange", {"adState": "1082", "currentTime": "0"}),
        ]
        dec = self._make()
        out = dec.feed(_encode_batch(events))
        self.assertEqual(len(out), 3)

    def test_multiple_events_split_between_reads(self):
        events = [
            (1, "onStateChange", {"state": "1"}),
            (2, "nowPlaying", {"videoId": "x", "state": "2"}),
        ]
        stream = _encode_batch(events)
        dec = self._make()
        # Split exactly between the two events (after the first event's newline).
        boundary = stream.index("\n", stream.index("\n") + 1) + 1
        first = dec.feed(stream[:boundary])
        self.assertEqual(len(first), 1)  # first event completes in this read
        out = dec.feed(stream[boundary:])
        self.assertEqual(len(out), 1)  # second event completes in this read
        self.assertEqual(len(dec.delivered), 2)

    def test_stale_partial_data_dropped_on_reset(self):
        # A connection closes mid-event; the next subscription must not inherit
        # the partial chunk.
        stream = _encode_event(1, "nowPlaying", {"videoId": "abc", "state": "1"})
        dec = self._make()
        split_at = stream.index("\n") + 1
        dec.feed(stream[:split_at])  # only the length line, no content yet
        dec.reset()  # new subscription
        out = dec.feed(stream[split_at:])
        # After reset, the leftover length line is gone; the JSON alone is not
        # a valid chunk, so nothing is delivered.
        self.assertEqual(out, [])

    def test_each_event_delivered_exactly_once(self):
        events = [
            (1, "onStateChange", {"state": "1"}),
            (2, "nowPlaying", {"videoId": "x", "state": "2"}),
            (3, "onAdStateChange", {"adState": "0", "isSkipEnabled": "true"}),
        ]
        stream = _encode_batch(events)
        dec = self._make()
        # Feed in random-ish splits.
        splits = [0, 5, 9, 17, 30, 41, 55, len(stream)]
        total = []
        for i in range(len(splits) - 1):
            total.extend(dec.feed(stream[splits[i]:splits[i + 1]]))
        self.assertEqual(len(total), 3)


class BuggyParserRegressionTests(unittest.TestCase):
    """Demonstrate the pre-fix parser loses events (regression guard)."""

    def test_buggy_parser_loses_event_when_length_and_content_split(self):
        # This is the exact failure the fix addresses: the length line arrives
        # in one read and the content in the next. The buggy parser treats the
        # content line as a new length line and drops the event.
        stream = _encode_event(1, "nowPlaying", {"videoId": "abc", "state": "1"})
        dec = _BuggyDecoder()
        split_at = stream.index("\n") + 1
        dec.feed(stream[:split_at])
        out = dec.feed(stream[split_at:])
        self.assertEqual(out, [])  # event lost

    def test_buggy_parser_loses_event_when_content_split(self):
        stream = _encode_event(1, "onAdStateChange", {"adState": "0", "isSkipEnabled": "true"})
        dec = _BuggyDecoder()
        for i in range(len(stream) - 1):
            dec.feed(stream[i])
        out = dec.feed(stream[-1])
        self.assertEqual(out, [])  # event lost


if __name__ == "__main__":
    unittest.main()
