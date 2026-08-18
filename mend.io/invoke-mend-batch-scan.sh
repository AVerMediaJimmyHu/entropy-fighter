#!/usr/bin/env bash
# ==============================================================================
# Script Name: invoke-mend-batch-scan.sh
# Version    : 1.1.0
# Description: Mend.io (WhiteSource) Offline Scan & Upload Automation Runner for macOS
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.1.0"

# 預設參數
CONFIG_FILE=""
VERSION_TAG=""
PROJECT_ROOT=""
MEND_DIR="${SCRIPT_DIR}/Mend_Mac_scan-OfflineScan"
API_KEY="${MEND_API_KEY:-}"
USER_KEY="${MEND_USER_KEY:-}"
DRY_RUN=false
PAUSE_BEFORE_SCAN=false

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 幫助訊息
usage() {
    cat <<EOF
Usage: $(basename "$0") --config-file <path> [options]

Options:
  -c, --config-file <path>      Path to mend-config.json (Required)
  -v, --version-tag <tag>       Global default version tag (Optional)
  -r, --project-root <path>     Project root directory (Auto-detected if omitted)
  -m, --mend-dir <path>         Mend offline toolpack directory (Default: ./Mend_Mac_scan-OfflineScan)
  -a, --api-key <key>           Mend Organization API Key (Fallback: \$MEND_API_KEY)
  -u, --user-key <key>          Mend User Key (Fallback: \$MEND_USER_KEY)
  -d, --dry-run                 Assemble symlinks and report only; skip Java scan & upload
  -p, --pause                   Pause before scanning to manually inspect staging folder
  -h, --help                    Show this help message
EOF
    exit 1
}

# 解析 CLI 參數
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config-file)   CONFIG_FILE="$2"; shift 2 ;;
        -v|--version-tag)    VERSION_TAG="$2"; shift 2 ;;
        -r|--project-root)   PROJECT_ROOT="$2"; shift 2 ;;
        -m|--mend-dir)       MEND_DIR="$2"; shift 2 ;;
        -a|--api-key)        API_KEY="$2"; shift 2 ;;
        -u|--user-key)       USER_KEY="$2"; shift 2 ;;
        -d|--dry-run)        DRY_RUN=true; shift ;;
        -p|--pause)          PAUSE_BEFORE_SCAN=true; shift ;;
        -h|--help)           usage ;;
        *) echo -e "${RED}錯誤: 未知參數 '$1'${NC}" >&2; usage ;;
    esac
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}錯誤: 必須提供 --config-file 參數！${NC}" >&2
    usage
fi

# 載入版本解析模組
RESOLVER_SCRIPT="${SCRIPT_DIR}/resolve-project-version.sh"
if [[ -f "$RESOLVER_SCRIPT" ]]; then
    source "$RESOLVER_SCRIPT"
else
    echo -e "${RED}錯誤: 找不到版本解析模組: $RESOLVER_SCRIPT${NC}" >&2
    exit 1
fi

echo -e "\n${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN} Mend.io Offline Batch Scan & Upload Runner for macOS (v${SCRIPT_VERSION})${NC}"
echo -e "${CYAN}========================================================================${NC}\n"

# 1. 驗證設定檔路徑
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}錯誤: 設定檔不存在: $CONFIG_FILE${NC}" >&2
    exit 1
fi
CONFIG_FILE_ABS="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
CONFIG_DIR="$(dirname "$CONFIG_FILE_ABS")"

# 2. 自動探測 Mend 工具目錄結構 (自適應 WS-OfflineScan)
if [[ -d "${MEND_DIR}/WS-OfflineScan" ]]; then
    MEND_DIR="${MEND_DIR}/WS-OfflineScan"
fi
MEND_DIR_ABS="$(cd "$MEND_DIR" 2>/dev/null && pwd || echo "$MEND_DIR")"

SCAN_DIR="${MEND_DIR_ABS}/Scan"
UPLOAD_DIR="${MEND_DIR_ABS}/Upload"
SOURCE_CODE_DIR="${SCAN_DIR}/SourceCode"

# 3. 探測 Java 執行環境
JAVA_BIN=""
if [[ -x "${MEND_DIR_ABS}/Config/zulu-JDK-11/bin/java" ]]; then
    JAVA_BIN="${MEND_DIR_ABS}/Config/zulu-JDK-11/bin/java"
elif [[ -x "${SCAN_DIR}/Config/zulu-JDK-11/bin/java" ]]; then
    JAVA_BIN="${SCAN_DIR}/Config/zulu-JDK-11/bin/java"
elif command -v java >/dev/null 2>&1; then
    JAVA_BIN="$(command -v java)"
fi

# 4. 探測 Unified Agent Jar
UA_JAR=""
for j in "${MEND_DIR_ABS}"/Config/UnifiedAgent/wss-unified-agent-*.jar \
         "${SCAN_DIR}"/Config/UnifiedAgent/wss-unified-agent-*.jar; do
    if [[ -f "$j" ]]; then
        UA_JAR="$j"
        break
    fi
done

# 5. 探測 Scan 與 Upload Config
SCAN_CONFIG=""
for c in "${SCAN_DIR}/Config/Scan-wss-unified-agent.config" \
         "${SCAN_DIR}/Config/wss-unified-agent.config" \
         "${MEND_DIR_ABS}/Config/wss-unified-agent.config"; do
    if [[ -f "$c" ]]; then
        SCAN_CONFIG="$c"
        break
    fi
done

UPLOAD_CONFIG=""
for c in "${UPLOAD_DIR}/Config/Upload-wss-unified-agent.config" \
         "${UPLOAD_DIR}/Config/wss-unified-agent.config" \
         "${MEND_DIR_ABS}/Config/wss-unified-agent.config"; do
    if [[ -f "$c" ]]; then
        UPLOAD_CONFIG="$c"
        break
    fi
done

# 安全清理暫存目錄函式
cleanup_staging() {
    if [[ -d "$SOURCE_CODE_DIR" ]]; then
        # 僅刪除 SourceCode 底下的 symlink 與暫存檔案，絕不遞迴刪除目標原始檔案
        rm -rf "${SOURCE_CODE_DIR:?}"/* 2>/dev/null || true
    fi
}
trap cleanup_staging EXIT INT TERM

# 安全讀取頂層 JSON 欄位函式 (完全無 eval)
get_config_field() {
    local field="$1"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        val = d.get(sys.argv[2], '')
        print('' if val is None else val)
except Exception:
    pass
" "$CONFIG_FILE_ABS" "$field"
}

# 安全讀取專案欄位函式
get_proj_field() {
    local index="$1"
    local field="$2"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        p = d['projects'][int(sys.argv[2])]
        val = p.get(sys.argv[3], '')
        print('' if val is None else val)
except Exception:
    pass
" "$CONFIG_FILE_ABS" "$index" "$field"
}

# 安全讀取專案 paths 清單函式
get_proj_paths() {
    local index="$1"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        p = d['projects'][int(sys.argv[2])]
        for item in p.get('paths', []):
            print(item)
except Exception:
    pass
" "$CONFIG_FILE_ABS" "$index"
}

# 6. 解析頂層設定
JSON_PRODUCT="$(get_config_field 'productName')"
JSON_PROJECT_ROOT="$(get_config_field 'projectRoot')"
JSON_API_KEY="$(get_config_field 'apiKey')"
JSON_USER_KEY="$(get_config_field 'userKey')"

# 階層式覆蓋憑證
RESOLVED_API_KEY="${API_KEY:-$JSON_API_KEY}"
RESOLVED_USER_KEY="${USER_KEY:-$JSON_USER_KEY}"

# 7. 自動邊界感知專案根目錄 (ProjectRoot)
RESOLVED_PROJECT_ROOT=""
if [[ -n "$PROJECT_ROOT" ]]; then
    RESOLVED_PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
elif [[ -n "$JSON_PROJECT_ROOT" ]]; then
    RESOLVED_PROJECT_ROOT="$(cd "${CONFIG_DIR}/${JSON_PROJECT_ROOT}" && pwd)"
else
    # 自動嗅探邊界目錄
    curr="$CONFIG_DIR"
    dir_name="$(basename "$curr")"
    if [[ "$dir_name" =~ ^(\.jenkins|\.ci|configs|config|\.config|\.github)$ ]]; then
        RESOLVED_PROJECT_ROOT="$(cd "${curr}/.." && pwd)"
    else
        RESOLVED_PROJECT_ROOT="$curr"
    fi
fi

echo -e "  [設定檔路徑] $CONFIG_FILE_ABS"
echo -e "  [專案根目錄] $RESOLVED_PROJECT_ROOT"
echo -e "  [Mend工具包] $MEND_DIR_ABS"
echo -e "  [Java執行檔] ${JAVA_BIN:-'未找到 (DryRun 可繼續)'}"
echo -e "  [UnifiedAgent] ${UA_JAR:-'未找到'}"
echo -e "  [產品名稱]   $JSON_PRODUCT\n"

# 8. 取得 projects 數量並逐一處理
PROJECT_COUNT=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        print(len(d.get('projects', [])))
except Exception:
    print(0)
" "$CONFIG_FILE_ABS")

if [[ "$PROJECT_COUNT" -eq 0 ]]; then
    echo -e "${YELLOW}警告: 設定檔內沒有定義任何 projects 項目！${NC}"
    exit 0
fi

# 宣告整體成功/失敗統計
SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for ((i=0; i<PROJECT_COUNT; i++)); do
    PROJ_NAME="$(get_proj_field "$i" 'name')"
    PROJ_PLATFORM="$(get_proj_field "$i" 'platform')"
    [[ -z "$PROJ_PLATFORM" ]] && PROJ_PLATFORM="all"
    PROJ_VER="$(get_proj_field "$i" 'version')"
    PROJ_RULE="$(get_proj_field "$i" 'versionRule')"
    PROJ_FLAVOR="$(get_proj_field "$i" 'flavor')"
    PROJ_VER_FILE="$(get_proj_field "$i" 'versionFile')"

    echo -e "${MAGENTA}------------------------------------------------------------------------${NC}"
    echo -e "${BOLD}${MAGENTA}>> 處理專案 [$((i+1))/$PROJECT_COUNT]: $PROJ_NAME${NC}"
    echo -e "${MAGENTA}------------------------------------------------------------------------${NC}"

    # A. 平台過濾 (macOS 執行環境下自動略過 windows 專案，相容 Bash 3.2)
    # A. 平台過濾 (macOS 執行環境下自動略過 windows 專案，相容 ios/macos/all)
    local_plat=$(echo "$PROJ_PLATFORM" | tr '[:upper:]' '[:lower:]')
    if [[ "$local_plat" == "windows" || "$local_plat" == "win" || "$local_plat" == "win32" || "$local_plat" == "win64" ]]; then
        echo -e "${YELLOW}  [平台略過] 專案 [$PROJ_NAME] 指定平台為 [$PROJ_PLATFORM]，在 macOS 環境下自動略過。${NC}"
        ((SKIP_COUNT++))
        continue
    fi

    # 組合 paths 陣列
    current_paths=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && current_paths+=("$line")
    done < <(get_proj_paths "$i")

    # B. 解析版本號
    PROJ_RESOLVED_VER=$(resolve_project_version \
        "$RESOLVED_PROJECT_ROOT" \
        "$PROJ_NAME" \
        "$PROJ_VER" \
        "$PROJ_RULE" \
        "$PROJ_FLAVOR" \
        "$PROJ_VER_FILE" \
        "$VERSION_TAG" \
        "${current_paths[@]}")

    # C. 組合 Mend Project 完整名稱
    PROJ_FULL_NAME="$PROJ_NAME"
    if [[ -n "$PROJ_PLATFORM" && "$local_plat" != "all" ]]; then
        PROJ_FULL_NAME="${PROJ_NAME}-${PROJ_PLATFORM}-${PROJ_RESOLVED_VER}"
    else
        PROJ_FULL_NAME="${PROJ_NAME}-${PROJ_RESOLVED_VER}"
    fi

    echo -e "  [版本解析結果] 標籤: ${GREEN}${PROJ_RESOLVED_VER}${NC} | Mend 專案名稱: ${GREEN}${PROJ_FULL_NAME}${NC}"

    # D. 建立暫存鏡像 (POSIX Symlink)
    cleanup_staging
    mkdir -p "$SOURCE_CODE_DIR"

    MOUNTED_COUNT=0
    for rel_path in "${current_paths[@]}"; do
        # 支援 Glob 萬用字元展開 (需在無引號狀態下由 Shell 展開)
        expanded_sources=()
        if [[ "$rel_path" == *"*"* || "$rel_path" == *"?"* ]]; then
            while IFS= read -r match_file; do
                [[ -n "$match_file" ]] && expanded_sources+=("${RESOLVED_PROJECT_ROOT}/${match_file}")
            done < <(
                cd "$RESOLVED_PROJECT_ROOT" 2>/dev/null
                shopt -s nullglob
                for m in $rel_path; do
                    echo "$m"
                done
                shopt -u nullglob
            )
        else
            expanded_sources+=("${RESOLVED_PROJECT_ROOT}/${rel_path}")
        fi

        for src_path in "${expanded_sources[@]}"; do
            if [[ ! -e "$src_path" ]]; then
                echo -e "  [掛載略過] 來源不存在: $src_path"
                continue
            fi

            # 計算鏡像目標相對路徑
            item_rel="${src_path#"${RESOLVED_PROJECT_ROOT}/"}"
            target_link="${SOURCE_CODE_DIR}/${item_rel}"

            mkdir -p "$(dirname "$target_link")"
            ln -sf "$src_path" "$target_link"
            echo -e "  [符號連結] ${item_rel} -> ${src_path}"
            ((MOUNTED_COUNT++))
        done
    done

    if [[ "$MOUNTED_COUNT" -eq 0 ]]; then
        echo -e "${RED}  [錯誤] 專案 [$PROJ_NAME] 未能成功掛載任何路徑！${NC}" >&2
        ((FAIL_COUNT++))
        continue
    fi

    # E. DryRun 模式
    if [[ "$DRY_RUN" = true ]]; then
        echo -e "${GREEN}  [DryRun] 目錄組裝完成 (共 $MOUNTED_COUNT 項)，略過離線掃描與上傳。${NC}"
        ((SUCCESS_COUNT++))
        continue
    fi

    # F. 人工檢視暫停模式
    if [[ "$PAUSE_BEFORE_SCAN" = true ]]; then
        echo -e "${YELLOW}\n  [Pause] 已暫停，請檢視暫存目錄: $SOURCE_CODE_DIR${NC}"
        read -p "  按 [Enter] 鍵繼續執行離線掃描..."
    fi

    # G. 執行 Java 離線掃描 (Offline Scan)
    echo -e "  [掃描開始] 呼叫 Unified Agent 執行離線掃描..."
    (
        cd "$SCAN_DIR"
        "$JAVA_BIN" -Dfile.encoding=UTF-8 \
            -jar "$UA_JAR" \
            -c "$SCAN_CONFIG" \
            -d "SourceCode" \
            -apiKey "$RESOLVED_API_KEY" \
            -userKey "$RESOLVED_USER_KEY" \
            -product "$JSON_PRODUCT" \
            -project "$PROJ_FULL_NAME"
    )

    SCAN_UPDATE_FILE="${SCAN_DIR}/whitesource/update-request.txt"
    if [[ ! -s "$SCAN_UPDATE_FILE" ]]; then
        echo -e "${RED}  [掃描失敗] 未產出 update-request.txt 或檔案為空: $SCAN_UPDATE_FILE${NC}" >&2
        ((FAIL_COUNT++))
        continue
    fi
    echo -e "${GREEN}  [掃描成功] 產出離線記錄檔: $SCAN_UPDATE_FILE${NC}"

    # H. 準備上傳
    UPLOAD_REQ_FILE="${UPLOAD_DIR}/UploadFile/update-request.txt"
    mkdir -p "$(dirname "$UPLOAD_REQ_FILE")"
    cp -f "$SCAN_UPDATE_FILE" "$UPLOAD_REQ_FILE"

    echo -e "  [上傳開始] 呼叫 Unified Agent 上傳中繼資料至 Mend.io..."
    (
        cd "$UPLOAD_DIR"
        "$JAVA_BIN" -Dfile.encoding=UTF-8 \
            -jar "$UA_JAR" \
            -apiKey "$RESOLVED_API_KEY" \
            -userKey "$RESOLVED_USER_KEY" \
            -requestFiles "UploadFile/update-request.txt"
    )
    echo -e "${GREEN}  [上傳成功] 專案 [$PROJ_FULL_NAME] 上傳完成！${NC}"
    ((SUCCESS_COUNT++))
done

# 清理最終暫存
cleanup_staging

echo -e "\n${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN} Mend.io 批次掃描作業總結 (macOS)${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo -e "  總專案數: $PROJECT_COUNT"
echo -e "  成功執行: ${GREEN}$SUCCESS_COUNT${NC}"
echo -e "  略過專案: ${YELLOW}$SKIP_COUNT${NC}"
echo -e "  失敗專案: ${RED}$FAIL_COUNT${NC}"
echo -e "${CYAN}========================================================================${NC}\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
