# Dummy Text Generator

Generates lorem ipsum-style filler text using real words and coherent structure, while still being intentionally nonsensical enough for demos.

## Features

- Defaults to English and 1 paragraph.
- Supports English and Norwegian.
- Uses a curated sentence pool with balanced paragraph lengths and natural variation.
- Optional concise title.
- Optional basic markdown output.
- Template modes for common article-like outputs.
- Copies generated text to the clipboard by default while still writing it to the output stream.

## Templates

- `Custom` (default): Uses `-ParagraphCount`, optional `-IncludeTitle`.
- `Simple`: 1 title and 1 paragraph.
- `NewsArticle`: 1 title, bolded preface, and at least 3 paragraphs with subheadings.
- `Document`: 1 title and a multi-section body intended to fill about two pages.

## Usage

Basic default output:

```powershell
.\DummyTextGenerator.ps1
```

English with 4 paragraphs and title:

```powershell
.\DummyTextGenerator.ps1 -Template Custom -ParagraphCount 4 -IncludeTitle
```

Norwegian news article in markdown:

```powershell
.\DummyTextGenerator.ps1 -Template NewsArticle -Language Norwegian -Markdown
```

Document-style markdown output:

```powershell
.\DummyTextGenerator.ps1 -Template Document -Markdown
```

Skip copying to the clipboard:

```powershell
.\DummyTextGenerator.ps1 -NoClipboard
```

Clipboard support uses `Set-Clipboard` on Windows, `pbcopy` on macOS, or
`xclip`/`xsel` on Linux. If the required clipboard utility is unavailable or
copying fails, the script warns and still outputs the generated text.
