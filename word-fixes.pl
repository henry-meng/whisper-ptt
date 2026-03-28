#!/usr/bin/perl -p
use utf8;
BEGIN { binmode(STDIN, ":utf8"); binmode(STDOUT, ":utf8"); }
# PTT word fixes — applied to whisper.cpp transcription output.
# Each line is a perl substitution. Add entries as you discover misrecognitions.
# Usage: echo "transcribed text" | perl word-fixes.pl

# =========================================================================
# Project-specific terms (CUSTOMIZE THESE)
# Add your own domain terms that Whisper frequently misrecognizes.
# =========================================================================

# Example: project name corrections
# s/\bcow\b/Cal/gi;
# s/\bnight brain\b/Nightbrain/gi;

# Example: technical terms
# s/\bswift UI\b/SwiftUI/gi;
# s/\bhummingbird\b/Hummingbird/g;
# s/\bollama\b/Ollama/g;

# =========================================================================
# Voice commands for formatting and special characters
# Whisper auto-handles periods, commas, question marks, exclamation points.
# These cover what Whisper CANNOT do from prosody alone.
# =========================================================================

# Line breaks
s/\bnew line\b/\n/gi;
s/\bnew paragraph\b/\n\n/gi;

# Quotes — "quote" alone inserts a straight double quote
# Use "open quote" / "close quote" for explicit pairing
s/\bopen quote\b/\x{201C}/gi;
s/\bclose quote\b/\x{201D}/gi;
s/(?<!\w)quote(?!\w)/"/gi;

# Brackets and parentheses
s/\bopen paren\b/(/gi;
s/\bclose paren\b/)/gi;
s/\bopen bracket\b/[/gi;
s/\bclose bracket\b/]/gi;
s/\bopen brace\b/{/gi;
s/\bclose brace\b/}/gi;

# Punctuation that Whisper rarely inserts on its own
s/\bcolon\b/:/gi;
s/\bsemicolon\b/;/gi;
s/\bem dash\b/\x{2014}/gi;
s/\bellipsis\b/\x{2026}/gi;

# Formatting
s/\btab key\b/\t/gi;

# =========================================================================
# Spoken punctuation → symbol conversion
# These match punctuation words at the END of a chunk (after a pause)
# which is a strong signal the user meant the symbol, not the word.
# Mid-sentence uses (e.g., "the Victorian period") stay as words.
# =========================================================================

# End-of-chunk: "period" or "period." → "."
s/\s+period\.?\s*$/./i;

# End-of-chunk: "comma" → ","
s/\s+comma\s*$/,/i;

# End-of-chunk: "question mark" → "?"
s/\s+question mark\.?\s*$/?/i;

# End-of-chunk: "exclamation mark" or "exclamation point" → "!"
s/\s+exclamation (?:mark|point)\.?\s*$/!/i;

# Mid-sentence spoken punctuation (riskier, but useful for dictation)
# "I went to the store comma and then" → "I went to the store, and then"
s/\s+comma\s+/, /gi;
s/\s+period\s+(?=[A-Z])/. /g;
