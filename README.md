# nanobanana.sh

Shell script to call Google Gemini API (Generative Language API) for multimodal requests.

## Features
- Interactive prompts (text, optional reference image)
- Saves API response as JSON (stream aware)
- Extracts inlineData images and saves all of them (output_001.png, ...)
- Fallback: re-requests image-only if no images found
- Robust JSON parsing with `jq` (falls back to last image if jq is missing)
- macOS friendly base64 encode/decode
- Options for output filename, response path, timeouts, retries
- Structured logging (text/JSON), file logging, log rotation
- cURL traces for deep debugging

## Requirements
- macOS / zsh
- `curl`
- `python3` (used only for safe JSON string escaping of text prompt)
- Optional: `jq` (recommended)

Install `jq` (macOS / Homebrew):
```bash
brew install jq
```

## Usage
```bash
export GEMINI_API_KEY="YOUR_API_KEY"
bash nanobanana.sh [options]
```

Common options:
- `--out <filename>`: output image name (relative path is saved next to the script). If multiple images: `<base>_001.<ext>`, ...
- `--no-prompt-out`: skip output filename prompt; use `output.<ext>`
- `--save-response <path>`: save response JSON here (default: `./output.txt`)
- `--timeout <sec>` (default 60), `--retry <n>` (default 2), `--retry-delay <sec>` (default 1)
- `--log-level <error|info|debug>` (default info), `--log-json`, `--log-file <path>`
- `--log-rotate-size <bytes>`, `--log-rotate-keep <n>` (default 3)
- `--curl-trace-ascii <path>`, `--curl-trace <path>`, `--curl-trace-time`
- `--show-api-key-full`: print API key without masking (use with caution)

## Examples
```bash
# Basic
bash nanobanana.sh

# Specify output and response path
bash nanobanana.sh --out images/result.png --save-response logs/resp.txt

# JSON logs with rotation
bash nanobanana.sh --log-json --log-file logs/run.jsonl --log-rotate-size 102400 --log-rotate-keep 5

# Deep debugging
bash nanobanana.sh --log-level debug --curl-trace-ascii logs/trace-ascii.log
```

## Notes
- Response file is overwritten each run.
- If no inlineData is found, the script re-requests with IMAGE-only modalities.
- Without `jq`, the script saves only the last image and prints an installation hint.
