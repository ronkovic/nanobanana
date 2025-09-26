#!/bin/bash
# ============================================================
# 使い方: nanobanana.sh
# ------------------------------------------------------------
# 概要:
#   Google Generative Language API (Gemini) に画像/テキストのプロンプトを送り、
#   レスポンスを output.txt に保存します。レスポンス内の inlineData（画像）が
#   含まれていれば base64 を画像ファイルに復元して同階層に保存します。
#
# 前提:
#   - macOS / zsh を想定
#   - API キーは環境変数 GEMINI_API_KEY に設定済み、
#     もしくは実行時に入力（非表示入力）できます。
#
# 入力:
#   - 画像生成の説明文（ターミナルで対話入力）
#   - 参照画像のパス（任意・空なら画像なし。指定時は inlineData として送信）
#
# オプション:
#   --out <filename>     : 出力画像ファイル名を指定（相対名はスクリプトと同階層に保存）
#                           未指定時は output.{拡張子} で保存
#   --no-prompt-out      : --out 未指定時に出力名の対話をスキップし、常に output.{拡張子} を使用
#   --save-response <p>  : レスポンス(JSON)の保存先ファイルパスを指定（既定: ./output.txt）
#   --timeout <sec>        : API 呼び出しの最大秒数（既定: 60）
#   --retry <n>            : API 呼び出しのリトライ回数（既定: 2）
#   --retry-delay <sec>    : リトライ間隔秒（既定: 1）
#   --log-level <lvl>      : ログレベル（error|info|debug、既定: info）
#   --log-json             : ログをJSON形式で出力（ts, level, msg, pid, prog）
#   --log-file <path>      : ログを書き出すファイルパス（標準エラーと同時に出力）
#   --log-rotate-size <n>  : ログローテーション閾値（バイト、0で無効、既定: 0）
#   --log-rotate-keep <n>  : ローテーション後に保持するファイル数（既定: 3）
#   --curl-trace-ascii <p> : curl の --trace-ascii 出力先パス
#   --curl-trace <p>       : curl の --trace 出力先パス
#   --curl-trace-time      : curl の --trace-time を有効化（--log-level debug 時は自動）
#   --show-api-key-full    : 環境変数 GEMINI_API_KEY をマスクせずにフル表示（既定はマスク表示）
#
# 複数画像がレスポンスに含まれる場合:
#   すべて保存します。出力名が foo.png の場合は foo_001.png, foo_002.png ... として保存します。
#
# jq について（任意・推奨）:
#   - jq がインストールされている場合は、レスポンス JSON から全画像を厳密に抽出します。
#   - 未インストールの場合は、エラーにせず最後の1枚のみ保存します（jq のインストールを案内表示）。
#   - macOS(Homebrew):  brew install jq
#   - Linux(apt 例):    sudo apt-get install jq
#
# 動作:
#   1) 入力内容から request.json を生成
#   2) Gemini API にリクエストし、レスポンスを output.txt（または --save-response 指定先）に保存
#   3) output.txt から inlineData の mimeType/data を抽出
#   4) mimeType に応じて拡張子を決定し、base64 をデコードして画像を書き出し
#
# 出力:
#   - レスポンス本文: output.txt（同階層）
#   - 画像: --out で指定がなければ output.{拡張子}

# 機密値のマスク（先頭4桁 + ***** + 末尾4桁）
mask_secret() {
  local s="$1"; local n=${#s}
  if [ "$n" -le 8 ]; then printf '****'; return; fi
  local head=${s:0:4}
  local tail=${s: -4}
  local mid_len=$((n-8))
  printf '%s' "$head"
  printf '%*s' "$mid_len" '' | tr ' ' '*'
  printf '%s' "$tail"
}
#
# 例:
#   export GEMINI_API_KEY="YOUR_API_KEY"
#   bash nanobanana.sh
#   bash nanobanana.sh --out result.png
#   bash nanobanana.sh --out images/out.webp --save-response logs/resp.txt
#
# 注意:
#   - output.txt は実行毎に上書きされます
#   - inlineData が含まれない場合は画像ファイルは生成されません
#   - base64 のデコードは macOS(-D) / Linux(-d) を自動判定します
# ============================================================
set -e -E -o pipefail
export LC_ALL=C

GEMINI_API_KEY="$GEMINI_API_KEY"
# --- APIキー入力（任意: 環境変数が空なら対話で取得）---
if [ -z "$GEMINI_API_KEY" ]; then
  read -r -s -p "GEMINI_API_KEY を入力してください: " GEMINI_API_KEY
  echo
  if [ -z "$GEMINI_API_KEY" ]; then
    echo "エラー: GEMINI_API_KEY が指定されていません" >&2
    exit 1
  fi
fi
# 後続処理で参照できるよう export
export GEMINI_API_KEY
MODEL_ID="gemini-2.5-flash-image-preview"
GENERATE_CONTENT_API="streamGenerateContent"
# --- 共通関数群（リファクタリング） ---
# ログユーティリティ
LOG_LEVEL=info
LOG_JSON=false
LOG_FILE=""
LOG_ROTATE_SIZE=0
LOG_ROTATE_KEEP=3
PROG_NAME="$(basename "$0")"
_lvl_to_num() { case "$1" in error) echo 0;; info) echo 1;; debug) echo 2;; *) echo 1;; esac; }
_LOG_NUM=$(_lvl_to_num "$LOG_LEVEL")
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_filesize_bytes() {
  # $1: path -> echo size or 0 if missing
  [ -f "$1" ] || { echo 0; return; }
  # macOS: stat -f%z, Linux: stat -c%s
  local sz
  sz=$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0)
  echo "$sz"
}

_rotate_log_if_needed() {
  # ログファイルサイズが閾値を超えていればローテーション
  [ -n "$LOG_FILE" ] || return 0
  [ "$LOG_ROTATE_SIZE" -gt 0 ] || return 0
  local sz; sz=$(_filesize_bytes "$LOG_FILE")
  [ "$sz" -gt "$LOG_ROTATE_SIZE" ] || return 0
  local ts dst
  ts=$(date -u +%Y%m%d_%H%M%S)
  dst="${LOG_FILE}.${ts}"
  mv "$LOG_FILE" "$dst" 2>/dev/null || true
  : > "$LOG_FILE" 2>/dev/null || true
  # 保持数を超えた古いローテートファイルを削除
  # 並び替え: 新しい順に並べ、先頭LOG_ROTATE_KEEP件を除いた残りを削除
  ls -1t "${LOG_FILE}".* 2>/dev/null | awk 'NR>ENVIRON["KEEP"]' KEEP="$LOG_ROTATE_KEEP" | xargs -I{} -r rm -f -- {}
}
_emit_log() {
  # $1: level, $2...: msg
  local lvl msg ts
  lvl="$1"; shift
  msg="$*"
  ts="$(_ts)"
  if [ "$LOG_JSON" = true ]; then
    # JSON: {"ts":"...","level":"...","msg":"..."}
    # メッセージ中のダブルクォートは簡易エスケープ
    local esc
    esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local line
    line=$(printf '{"ts":"%s","level":"%s","pid":%d,"prog":"%s","msg":"%s"}\n' "$ts" "$lvl" $$ "$PROG_NAME" "$esc")
    printf '%s' "$line" >&2
    if [ -n "$LOG_FILE" ]; then ensure_dir "$LOG_FILE"; printf '%s' "$line" >> "$LOG_FILE"; _rotate_log_if_needed; fi
  else
    # テキスト: [ts] [LVL] msg
    case "$lvl" in
      error) line=$(printf '[%s] [ERR] %s\n' "$ts" "$msg") ;;
      info)  line=$(printf '[%s] [INF] %s\n' "$ts" "$msg") ;;
      debug) line=$(printf '[%s] [DBG] %s\n' "$ts" "$msg") ;;
      *)     line=$(printf '[%s] [%s] %s\n' "$ts" "$lvl" "$msg") ;;
    esac
    printf '%s' "$line" >&2
    if [ -n "$LOG_FILE" ]; then ensure_dir "$LOG_FILE"; printf '%s' "$line" >> "$LOG_FILE"; _rotate_log_if_needed; fi
  fi
}
log_err()  { _emit_log error "$*"; }
log_info() { [ "$(_lvl_to_num "$LOG_LEVEL")" -ge 1 ] && _emit_log info "$*" || true; }
log_dbg()  { [ "$(_lvl_to_num "$LOG_LEVEL")" -ge 2 ] && _emit_log debug "$*" || true; }
mime_to_ext() {
  case "$1" in
    image/png)   echo png ;;
    image/jpeg|image/jpg) echo jpg ;;
    image/webp)  echo webp ;;
    image/gif)   echo gif ;;
    image/svg+xml) echo svg ;;
    *)           echo bin ;;
  esac
}

ensure_dir() {
  # $1: path
  local d
  d="$(dirname "$1")" || return 0
  [ -d "$d" ] || mkdir -p "$d"
}

set_base64_decode_flag() {
  if [ "$(uname)" = "Darwin" ]; then BASE64_DECODE_OPT="-D"; else BASE64_DECODE_OPT="-d"; fi
}

have_jq() {
  command -v jq >/dev/null 2>&1
}

extract_pairs_with_jq() {
  # $1: response file
  jq -s -r '
    .. | objects
    | select(has("inlineData"))
    | .inlineData
    | select(has("mimeType") and has("data"))
    | "\(.mimeType)|\(.data)"' "$1"
}

extract_last_pair_fallback() {
  # $1: response file
  awk '
    /"inlineData"[[:space:]]*:[[:space:]]*\{/ {in=1; mime=""; data=""}
    in && /"mimeType"[[:space:]]*:/ { if (match($0, /"mimeType"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) mime=m[1] }
    in && /"data"[[:space:]]*:/ { if (match($0, /"data"[[:space:]]*:[[:space:]]*"([^"]*)"/, d)) data=d[1] }
    in && /}/ { if (mime!="" && data!="") last=mime "|" data; in=0; mime=""; data="" }
    END { if (last!="") print last }
  ' "$1"
}

decode_to_file() {
  # stdin: base64, $1: out path
  ensure_dir "$1"
  base64 "$BASE64_DECODE_OPT" > "$1"
}
# --- ヘルプ表示関数 ---
print_help() {
  cat <<'HELP'
nanobanana.sh - Google Generative Language API (Gemini) 画像/テキスト リクエストツール

[概要]
  入力した説明文（必要に応じて参照画像）を用いて Gemini にリクエストを送り、
  レスポンスを output.txt に保存。レスポンス内の inlineData（画像）があれば
  Base64 から画像ファイルを復元して同階層に保存します。

[前提]
  - macOS / zsh を想定
  - GEMINI_API_KEY が環境変数に設定済み、未設定なら実行時に非表示入力

[使い方]
  bash nanobanana.sh [--out <filename>] [--pick <first|last>]

[対話入力]
  - 画像生成の説明文（必須）
  - 参照画像のパス（任意・空なら画像なし）

[オプション]
  --out <filename>
      出力画像ファイル名を指定。
      - 絶対パス: 指定先に保存
      - 相対パス: スクリプトと同階層に保存
      指定がない場合は output.{拡張子} を使用

  --pick <first|last>
      output.txt 内で検出した inlineData のうち、最初か最後を使用（既定: last）

  --no-prompt-out
      --out 未指定時に、出力名の対話を行わず常に output.{拡張子} を使用

  -h, --help
      このヘルプを表示して終了

[出力]
  - レスポンス本文: output.txt（同階層）
  - 画像: output.{拡張子} または --out で指定したファイル名

[例]
  export GEMINI_API_KEY="YOUR_API_KEY"
  bash nanobanana.sh
  bash nanobanana.sh --out result.png
  bash nanobanana.sh --out images/out.webp --save-response logs/resp.txt

[注意]
  - output.txt は実行毎に上書き
  - inlineData がない場合、画像は生成されません
  - Base64 デコードは macOS(-D)/Linux(-d) を自動判定
  - jq がある場合: レスポンスから全画像を厳密に抽出して全件保存
  - jq がない場合: 最後の1枚のみ保存（macOS: brew install jq）
HELP
}
# --- オプション解析 (--out, --no-prompt-out, --save-response, ネットワーク/ログ関連) ---
OUT_IMAGE_ARG=""
NO_PROMPT_OUT=false
SAVE_RESPONSE_ARG=""
CURL_TRACE_ASCII=""
CURL_TRACE_RAW=""
CURL_TRACE_TIME=false
TIMEOUT_SEC=60
RETRY_COUNT=2
RETRY_DELAY=1
SHOW_API_KEY_FULL=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --out)
      if [ -n "${2-}" ]; then OUT_IMAGE_ARG="$2"; shift 2; else echo "エラー: --out の引数がありません" >&2; exit 1; fi
      ;;
    --save-response)
      if [ -n "${2-}" ]; then SAVE_RESPONSE_ARG="$2"; shift 2; else echo "エラー: --save-response の引数がありません" >&2; exit 1; fi
      ;;
    --no-prompt-out)
      NO_PROMPT_OUT=true; shift
      ;;
    --timeout)
      if [ -n "${2-}" ]; then TIMEOUT_SEC="$2"; shift 2; else echo "エラー: --timeout の引数がありません" >&2; exit 1; fi
      ;;
    --retry)
      if [ -n "${2-}" ]; then RETRY_COUNT="$2"; shift 2; else echo "エラー: --retry の引数がありません" >&2; exit 1; fi
      ;;
    --retry-delay)
      if [ -n "${2-}" ]; then RETRY_DELAY="$2"; shift 2; else echo "エラー: --retry-delay の引数がありません" >&2; exit 1; fi
      ;;
    --log-level)
      if [ -n "${2-}" ]; then LOG_LEVEL="$2"; shift 2; else echo "エラー: --log-level の引数がありません" >&2; exit 1; fi
      _LOG_NUM=$(_lvl_to_num "$LOG_LEVEL")
      ;;
    --log-json)
      LOG_JSON=true; shift
      ;;
    --log-file)
      if [ -n "${2-}" ]; then LOG_FILE="$2"; shift 2; else echo "エラー: --log-file の引数がありません" >&2; exit 1; fi
      ;;
    --log-rotate-size)
      if [ -n "${2-}" ]; then LOG_ROTATE_SIZE="$2"; shift 2; else echo "エラー: --log-rotate-size の引数がありません" >&2; exit 1; fi
      ;;
    --log-rotate-keep)
      if [ -n "${2-}" ]; then LOG_ROTATE_KEEP="$2"; shift 2; else echo "エラー: --log-rotate-keep の引数がありません" >&2; exit 1; fi
      ;;
    --curl-trace-ascii)
      if [ -n "${2-}" ]; then CURL_TRACE_ASCII="$2"; shift 2; else echo "エラー: --curl-trace-ascii の引数がありません" >&2; exit 1; fi
      ;;
    --curl-trace)
      if [ -n "${2-}" ]; then CURL_TRACE_RAW="$2"; shift 2; else echo "エラー: --curl-trace の引数がありません" >&2; exit 1; fi
      ;;
    --curl-trace-time)
      CURL_TRACE_TIME=true; shift
      ;;
    --show-api-key-full)
      SHOW_API_KEY_FULL=true; shift
      ;;
    *)
      # 無名引数は無視（必要なら拡張）
      shift
      ;;
  esac
done
# APIキーの表示（デフォルトはマスク、--show-api-key-full でフル表示）
if [ "$SHOW_API_KEY_FULL" = true ]; then
  log_info "GEMINI_API_KEY=${GEMINI_API_KEY}"
else
  log_info "GEMINI_API_KEY=$(mask_secret "$GEMINI_API_KEY") (masked)"
fi

# --- 入力取得セクション ---
# 見やすさのため、プロンプト前に空行を出力
echo
# ユーザーから画像生成の説明文を読み取る（ターミナル入力）
read -r -p "画像生成の説明文を入力してください: " USER_TEXT

# 画像ファイルのパスを取得（任意）
read -r -p "画像ファイルのパスを入力してください（任意・空で画像なし）: " IMAGE_PATH
HAS_IMAGE=false
if [ -n "$IMAGE_PATH" ]; then
  if [ ! -f "$IMAGE_PATH" ]; then
    echo "エラー: 画像ファイルが見つかりません: $IMAGE_PATH" >&2
    exit 1
  fi
  HAS_IMAGE=true
fi

# 画像がある場合のみ MIMEタイプ判定とBase64化を実施し、JSON断片を生成
INLINE_JSON=""
if [ "$HAS_IMAGE" = true ]; then
  # MIMEタイプの判定（macOSのfileコマンドを使用）
  MIME_TYPE=$(file -b --mime-type "$IMAGE_PATH" 2>/dev/null || echo "application/octet-stream")
  # 画像をBase64化（改行を除去）
  BASE64_IMAGE=$(base64 < "$IMAGE_PATH" | tr -d '\n')
  # JSONの inlineData ブロック（後続にテキストブロックが続くため末尾にカンマを含める）
  INLINE_JSON=$(cat <<EOF_INLINE
          {
            "inlineData": {
              "mimeType": "$MIME_TYPE",
              "data": "$BASE64_IMAGE"
            }
          },
EOF_INLINE
)
fi

# JSON文字列用にエスケープ（Pythonのjson.dumpsで安全に処理し、外側の引用符を除去）
# 注意: -c でスクリプトを渡し、ユーザー入力はパイプ経由でstdinから渡す
ESCAPED_TEXT=$(printf '%s' "$USER_TEXT" | python3 -c 'import sys,json; s=sys.stdin.read(); print(json.dumps(s)[1:-1])')

# リクエストボディを作成
cat << EOF > request.json
{
    "contents": [
      {
        "role": "user",
        "parts": [
          $INLINE_JSON
          {
            "text": "$ESCAPED_TEXT"
          }
        ]
      }
    ],
    "generationConfig": {
      "responseModalities": ["IMAGE", "TEXT"]
    }
}
EOF

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# レスポンス保存先（--save-response 指定があればそれを使用）
if [ -n "$SAVE_RESPONSE_ARG" ]; then
  case "$SAVE_RESPONSE_ARG" in
    /*) OUTPUT_FILE="$SAVE_RESPONSE_ARG" ;;
    *) OUTPUT_FILE="${SCRIPT_DIR}/$SAVE_RESPONSE_ARG" ;;
  esac
else
  OUTPUT_FILE="${SCRIPT_DIR}/output.txt"
fi
# 保存先ディレクトリ作成
RESP_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$RESP_DIR" 2>/dev/null || true

# HTTP ステータスコード取得しつつ保存
log_info "API 呼び出しを開始します（timeout=${TIMEOUT_SEC}s, retry=${RETRY_COUNT}, delay=${RETRY_DELAY}s）"
CURLOPT_VERBOSE=""
[ "$(_lvl_to_num "$LOG_LEVEL")" -ge 2 ] && CURLOPT_VERBOSE="-v"

# curl トレースオプションの組み立て
CURL_TRACE_ARGS=()
if [ -n "$CURL_TRACE_ASCII" ]; then ensure_dir "$CURL_TRACE_ASCII"; CURL_TRACE_ARGS+=( "--trace-ascii" "$CURL_TRACE_ASCII" ); fi
if [ -n "$CURL_TRACE_RAW" ]; then ensure_dir "$CURL_TRACE_RAW"; CURL_TRACE_ARGS+=( "--trace" "$CURL_TRACE_RAW" ); fi
if [ "$CURL_TRACE_TIME" = true ] || [ "$(_lvl_to_num "$LOG_LEVEL")" -ge 2 ]; then CURL_TRACE_ARGS+=( "--trace-time" ); fi

HTTP_CODE=$(curl -sS $CURLOPT_VERBOSE "${CURL_TRACE_ARGS[@]}" \
  -X POST \
  -H "Content-Type: application/json" \
  "https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}" \
  -d '@request.json' \
  --max-time "$TIMEOUT_SEC" \
  --retry "$RETRY_COUNT" \
  --retry-delay "$RETRY_DELAY" \
  --retry-connrefused \
  -o "$OUTPUT_FILE" \
  -w '%{http_code}')

# ステータス判定（2xx以外は詳細表示して終了）
if ! printf '%s' "$HTTP_CODE" | grep -qE '^2'; then
  log_err "API 呼び出しが失敗しました (HTTP $HTTP_CODE)"
  echo "--- レスポンス（先頭2KBを表示） ---" >&2
  head -c 2048 "$OUTPUT_FILE" >&2 || true
  echo >&2
  exit 1
fi

# --- レスポンス解析: inlineData 抽出と画像生成 ---
if [ ! -s "$OUTPUT_FILE" ]; then
  echo "エラー: レスポンスが空です（$OUTPUT_FILE）" >&2
  exit 1
fi

# inlineData が含まれていなければ、画像専用で再リクエスト
if ! grep -q '"inlineData"' "$OUTPUT_FILE"; then
  echo "情報: inlineData ブロックが見つかりませんでした。画像専用で再リクエストします..."
  # フォールバック: 画像専用のレスポンスを要求
  cat << EOF_IMG > request_image_only.json
{
    "contents": [
      {
        "role": "user",
        "parts": [
          $INLINE_JSON
          {
            "text": "$ESCAPED_TEXT"
          }
        ]
      }
    ],
    "generationConfig": {
      "responseModalities": ["IMAGE"]
    }
}
EOF_IMG

  OUTPUT_FILE_IMG_ONLY="${SCRIPT_DIR}/output_image_only.txt"
  curl -sS \
    -X POST \
    -H "Content-Type: application/json" \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}" \
    -d '@request_image_only.json' \
    -o "$OUTPUT_FILE_IMG_ONLY"

  if [ ! -s "$OUTPUT_FILE_IMG_ONLY" ]; then
    echo "エラー: 画像専用の再リクエストでもレスポンスが空でした" >&2
    exit 1
  fi

  # 再度 inlineData を検出
  if ! grep -q '"inlineData"' "$OUTPUT_FILE_IMG_ONLY"; then
    echo "エラー: 再リクエスト後も inlineData が見つかりませんでした" >&2
    exit 1
  fi

  # 後続の抽出対象ファイルを差し替え
  OUTPUT_FILE="${OUTPUT_FILE_IMG_ONLY}"
fi

# inlineData の (mimeType|data) を抽出（jq 優先、無ければ最後の1枚にフォールバック）
if command -v jq >/dev/null 2>&1; then
  PAIRS=$(jq -s -r '
    .. | objects
    | select(has("inlineData"))
    | .inlineData
    | select(has("mimeType") and has("data"))
    | "\(.mimeType)|\(.data)"' "$OUTPUT_FILE")
  MODE="jq"
else
  echo "情報: jq が見つかりません。最後の1枚のみ保存します。jq をインストールすると複数画像も全件保存できます（macOS: brew install jq）" >&2
  # 最後の1枚だけ抽出
  PAIRS=$(awk '
    /"inlineData"[[:space:]]*:[[:space:]]*\{/ {in=1; mime=""; data=""}
    in && /"mimeType"[[:space:]]*:/ { if (match($0, /"mimeType"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) mime=m[1] }
    in && /"data"[[:space:]]*:/ { if (match($0, /"data"[[:space:]]*:[[:space:]]*"([^"]*)"/, d)) data=d[1] }
    in && /}/ { if (mime!="" && data!="") last=mime "|" data; in=0; mime=""; data="" }
    END { if (last!="") print last }
  ' "$OUTPUT_FILE")
  MODE="fallback"
fi

COUNT=$(printf "%s\n" "$PAIRS" | grep -c . || true)
if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
  echo "エラー: inlineData の抽出に失敗しました" >&2
  exit 1
fi

# 出力名のベース（複数時は base_###.ext を使う）
# まず最初の画像の拡張子を仮に決定してプロンプト既定表示に利用
FIRST_MIME=$(printf "%s\n" "$PAIRS" | head -n1 | awk -F'|' '{print $1}')
case "$FIRST_MIME" in
  image/png) FIRST_EXT="png" ;;
  image/jpeg|image/jpg) FIRST_EXT="jpg" ;;
  image/webp) FIRST_EXT="webp" ;;
  image/gif) FIRST_EXT="gif" ;;
  image/svg+xml) FIRST_EXT="svg" ;;
  *) FIRST_EXT="bin" ;;
esac

if [ -n "$OUT_IMAGE_ARG" ]; then
  case "$OUT_IMAGE_ARG" in
    /*) OUT_IMAGE="$OUT_IMAGE_ARG" ;;
    *) OUT_IMAGE="${SCRIPT_DIR}/$OUT_IMAGE_ARG" ;;
  esac
else
  if [ "$NO_PROMPT_OUT" = true ]; then
    OUT_IMAGE="${SCRIPT_DIR}/output.${FIRST_EXT}"
  else
    read -r -p "出力画像のファイル名を入力してください（任意・空で output.${FIRST_EXT}）: " OUT_IMAGE_USER
    if [ -n "$OUT_IMAGE_USER" ]; then
      case "$OUT_IMAGE_USER" in
        /*) OUT_IMAGE="$OUT_IMAGE_USER" ;;
        *) OUT_IMAGE="${SCRIPT_DIR}/$OUT_IMAGE_USER" ;;
      esac
    else
      OUT_IMAGE="${SCRIPT_DIR}/output.${FIRST_EXT}"
    fi
  fi
fi

OUT_DIR="$(dirname "$OUT_IMAGE")"
mkdir -p "$OUT_DIR" 2>/dev/null || true

# macOS/Linux の base64 デコードフラグ
if [ "$(uname)" = "Darwin" ]; then BASE64_DECODE_OPT="-D"; else BASE64_DECODE_OPT="-d"; fi

# ベース名とディレクトリ・拡張子
OUT_FILE_NAME="$(basename "$OUT_IMAGE")"
BASE_NAME="${OUT_FILE_NAME%.*}"
OUT_DIR="$(dirname "$OUT_IMAGE")"

if [ "$COUNT" -eq 1 ]; then
  # 単一画像は指定名そのまま
  MIME_TYPE_RESP=$(printf "%s\n" "$PAIRS" | awk -F'|' 'NR==1{print $1}')
  DATA_B64_RESP=$(printf "%s\n" "$PAIRS" | awk -F'|' 'NR==1{print $2}')
  case "$MIME_TYPE_RESP" in
    image/png) EXT="png" ;;
    image/jpeg|image/jpg) EXT="jpg" ;;
    image/webp) EXT="webp" ;;
    image/gif) EXT="gif" ;;
    image/svg+xml) EXT="svg" ;;
    *) EXT="bin" ;;
  esac
  # 拡張子が異なる場合は置き換え
  OUT_PATH_SINGLE="${OUT_DIR}/${BASE_NAME}.${EXT}"
  printf "%s" "$DATA_B64_RESP" | base64 "$BASE64_DECODE_OPT" > "$OUT_PATH_SINGLE" || { echo "エラー: base64 デコードに失敗しました" >&2; exit 1; }
  [ -s "$OUT_PATH_SINGLE" ] || { echo "エラー: 出力画像の作成に失敗しました: $OUT_PATH_SINGLE" >&2; exit 1; }
  echo "画像を書き出しました: $OUT_PATH_SINGLE (mimeType: $MIME_TYPE_RESP)"
else
  idx=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=$((idx+1))
    MIME=$(printf "%s" "$line" | awk -F'|' '{print $1}')
    DATA=$(printf "%s" "$line" | awk -F'|' '{print $2}')
    case "$MIME" in
      image/png) EXT="png" ;;
      image/jpeg|image/jpg) EXT="jpg" ;;
      image/webp) EXT="webp" ;;
      image/gif) EXT="gif" ;;
      image/svg+xml) EXT="svg" ;;
      *) EXT="bin" ;;
    esac
    OUT_PATH_MULTI=$(printf "%s/%s_%03d.%s" "$OUT_DIR" "$BASE_NAME" "$idx" "$EXT")
    printf "%s" "$DATA" | base64 "$BASE64_DECODE_OPT" > "$OUT_PATH_MULTI" || { echo "エラー: base64 デコードに失敗しました" >&2; exit 1; }
    [ -s "$OUT_PATH_MULTI" ] || { echo "エラー: 出力画像の作成に失敗しました: $OUT_PATH_MULTI" >&2; exit 1; }
    echo "画像を書き出しました: $OUT_PATH_MULTI (mimeType: $MIME)"
  done <<EOF_PAIRS
$(printf "%s\n" "$PAIRS")
EOF_PAIRS
fi
