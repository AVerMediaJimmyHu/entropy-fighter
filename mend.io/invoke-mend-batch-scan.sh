#!/usr/bin/env bash
# ==============================================================================
# Script Name: invoke-mend-batch-scan.sh
# Version    : 1.1.0
# Description: Mend.io (WhiteSource) Offline Scan & Upload Automation Runner for macOS
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.2.0"

# 預設參數
CONFIG_FILE=""
VERSION_TAG=""
PROJECT_ROOT=""
MEND_DIR="${SCRIPT_DIR}/Mend_Mac_scan-OfflineScan"
API_KEY="${MEND_API_KEY:-}"
USER_KEY="${MEND_USER_KEY:-}"
LOG_DIR=""
DRY_RUN=false
PAUSE_BEFORE_SCAN=false
SCAN_ONLY=false

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
  -l, --log-dir <path>          Central log archive directory (Default: \$WORKSPACE/mend-logs in CI)
  -s, --scan-only               Perform Java offline scan only; skip upload (Alias: --skip-upload)
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
        -l|--log-dir)        LOG_DIR="$2"; shift 2 ;;
        -s|--scan-only|--skip-upload) SCAN_ONLY=true; shift ;;
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

echo -e "\n${CYAN}[Mend Runner] macOS Batch Scan${NC}"

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

# 安全讀取專案 mendArgs 字典函式
get_proj_mend_args() {
    local index="$1"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        p = d['projects'][int(sys.argv[2])]
        mend_args = p.get('mendArgs', {})
        if isinstance(mend_args, dict):
            for k, v in mend_args.items():
                if isinstance(v, list):
                    print(f'{k}=' + ' '.join(str(x) for x in v))
                else:
                    print(f'{k}={v}')
except Exception:
    pass
" "$CONFIG_FILE_ABS" "$index"
}

# 判斷是否為 Gradle 專案
test_is_gradle_project() {
    local proj_root="$1"
    shift
    local target_paths=("$@")

    if [[ -f "${proj_root}/build.gradle" || -f "${proj_root}/build.gradle.kts" || -f "${proj_root}/gradle/wrapper/gradle-wrapper.properties" ]]; then
        return 0
    fi

    for p in "${target_paths[@]}"; do
        local full_p="${proj_root}/${p}"
        if [[ -f "${full_p}/build.gradle" || -f "${full_p}/build.gradle.kts" || -f "${full_p}/gradle/wrapper/gradle-wrapper.properties" || -f "${p}/build.gradle" || -f "${p}/build.gradle.kts" ]]; then
            return 0
        fi
    done

    return 1
}

# 智慧嗅探 Gradle Binary 路徑
resolve_gradle_bin_path() {
    local proj_root="$1"
    shift
    local target_paths=("$@")

    # 1. 系統 PATH 已有 gradle 則不需注入
    if command -v gradle >/dev/null 2>&1; then
        echo "  [Gradle 探測] 系統 PATH 已包含 gradle: $(command -v gradle)" >&2
        echo ""
        return 0
    fi

    echo "  [Gradle 探測] 偵測到 Gradle 依賴特徵，系統 PATH 未設定 gradle，啟動自動嗅探..." >&2

    # 2. 尋找 gradle-wrapper.properties
    local wrapper_candidates=(
        "${proj_root}/gradle/wrapper/gradle-wrapper.properties"
    )
    for p in "${target_paths[@]}"; do
        wrapper_candidates+=("${proj_root}/${p}/gradle/wrapper/gradle-wrapper.properties")
        wrapper_candidates+=("${proj_root}/${p}/wrapper/gradle-wrapper.properties")
        wrapper_candidates+=("${p}/gradle/wrapper/gradle-wrapper.properties")
    done

    local target_dist_name=""
    for cand in "${wrapper_candidates[@]}"; do
        if [[ -f "$cand" ]]; then
            echo "  [Gradle 探測] 讀取 Wrapper 設定: $cand" >&2
            local zip_name
            zip_name=$(grep -E 'distributionUrl\s*=' "$cand" | sed -E 's/.*(gradle-[0-9\.]+(-[a-zA-Z0-9]+)?(-bin|-all)?\.zip).*/\1/' || true)
            if [[ -n "$zip_name" ]]; then
                target_dist_name="${zip_name%.zip}"
                echo "  [Gradle 探測] 目標版本名稱: $target_dist_name" >&2
            fi
            break
        fi
    done

    # 3. 搜尋本機 Gradle 快取
    local gradle_dists_root=""
    if [[ -n "$GRADLE_USER_HOME" && -d "$GRADLE_USER_HOME" ]]; then
        gradle_dists_root="${GRADLE_USER_HOME}/wrapper/dists"
        echo "  [Gradle 探測] 依據環境變數 GRADLE_USER_HOME 搜尋快取: $gradle_dists_root" >&2
    elif [[ -d "$HOME/.gradle/wrapper/dists" ]]; then
        gradle_dists_root="$HOME/.gradle/wrapper/dists"
        echo "  [Gradle 探測] 搜尋本機預設快取目錄: $gradle_dists_root" >&2
    fi

    if [[ -d "$gradle_dists_root" ]]; then
        # A. 精確匹配目標版本
        if [[ -n "$target_dist_name" && -d "${gradle_dists_root}/${target_dist_name}" ]]; then
            local matched_bin
            matched_bin=$(find "${gradle_dists_root}/${target_dist_name}" -maxdepth 4 -type f -name "gradle" 2>/dev/null | head -n 1)
            if [[ -n "$matched_bin" && -f "$matched_bin" ]]; then
                chmod +x "$matched_bin" 2>/dev/null || true
                echo "  [Gradle 探測] 精確版本匹配成功: $matched_bin" >&2
                dirname "$matched_bin"
                return 0
            fi
        fi

        # B. Fallback: 尋找快取中任一可用的 gradle binary
        local fallback_bin
        fallback_bin=$(find "$gradle_dists_root" -maxdepth 5 -type f -name "gradle" 2>/dev/null | sort -V | tail -n 1)
        if [[ -n "$fallback_bin" && -f "$fallback_bin" ]]; then
            chmod +x "$fallback_bin" 2>/dev/null || true
            echo "  [Gradle 探測] (Fallback) 使用快取中最新 gradle: $fallback_bin" >&2
            dirname "$fallback_bin"
            return 0
        fi
    fi

    echo "  [Gradle 探測] 未能在本機 Gradle 快取中找到 gradle 執行檔。" >&2
    echo ""
    return 0
}

# 智慧嗅探與解析 Swift Package Manager (SPM) 依賴套件
resolve_spm_dependencies() {
    local proj_name="$1"
    local proj_plat="$2"
    local proj_rule="$3"
    local proj_root="$4"
    shift 4
    local target_paths=("$@")

    local plat_l
    plat_l=$(echo "$proj_plat" | tr '[:upper:]' '[:lower:]')
    local rule_l
    rule_l=$(echo "$proj_rule" | tr '[:upper:]' '[:lower:]')

    # 1. 判斷是否具備 Apple / iOS / Xcode 特徵
    local is_apple_target=false
    if [[ "$plat_l" == "ios" || "$plat_l" == "macos" || "$plat_l" == "mac" || "$rule_l" == "ios" || "$rule_l" == "xcode" || "$rule_l" == "apple" ]]; then
        is_apple_target=true
    fi

    # 2. 搜尋 Xcode 專案檔案 (*.xcworkspace, *.xcodeproj)
    local xcode_candidates=()
    for p in "${target_paths[@]}"; do
        local full_p="${proj_root}/${p}"
        if [[ "$p" == *.xcodeproj || "$p" == *.xcworkspace ]]; then
            xcode_candidates+=("$full_p")
        elif [[ -d "$full_p" ]]; then
            while IFS= read -r xf; do
                [[ -n "$xf" ]] && xcode_candidates+=("$xf")
            done < <(find "$full_p" -maxdepth 3 \( -name "*.xcworkspace" -o -name "*.xcodeproj" \) 2>/dev/null || true)
        fi
    done

    # 若 paths 沒找到，從專案根目錄搜尋
    if [[ ${#xcode_candidates[@]} -eq 0 ]]; then
        while IFS= read -r xf; do
            [[ -n "$xf" ]] && xcode_candidates+=("$xf")
        done < <(find "$proj_root" -maxdepth 4 \( -name "*.xcworkspace" -o -name "*.xcodeproj" \) 2>/dev/null || true)
    fi

    # 若非 Apple 目標且完全沒有 Xcode 專案，靜默略過
    if [[ "$is_apple_target" = false && ${#xcode_candidates[@]} -eq 0 ]]; then
        return 0
    fi

    echo "  [SPM 探測] 專案 [$proj_name] 開始搜尋 Xcode / SPM 依賴定義..." >&2

    # 3. 檢查系統是否具備 xcodebuild
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "  [SPM 略過] 系統未安裝 xcodebuild，略過 SPM 自動解析。" >&2
        return 0
    fi

    # 4. 對每個 Xcode 專案嘗試解析 SPM
    local spm_cache_dir="${proj_root}/.spm_cache"
    mkdir -p "$spm_cache_dir"

    for xtarget in "${xcode_candidates[@]}"; do
        [[ ! -e "$xtarget" ]] && continue
        echo "  [SPM 探測] 鎖定目標 Xcode 專案: $(basename "$xtarget")" >&2
        local target_dir
        target_dir="$(dirname "$xtarget")"
        local target_base
        target_base="$(basename "$xtarget")"

        echo "  [SPM 解析] 正在透過 xcodebuild 自動拉取第三方套件原始碼 (0% 編譯)..." >&2
        (
            cd "$target_dir" 2>/dev/null || true
            if [[ "$target_base" == *.xcworkspace ]]; then
                xcodebuild -resolvePackageDependencies \
                    -workspace "$target_base" \
                    -clonedSourcePackagesDirPath "$spm_cache_dir" -quiet >/dev/null 2>&1 || true
            else
                xcodebuild -resolvePackageDependencies \
                    -project "$target_base" \
                    -clonedSourcePackagesDirPath "$spm_cache_dir" -quiet >/dev/null 2>&1 || true
            fi
        )
        if [[ -d "${spm_cache_dir}/checkouts" ]]; then
            break
        fi
    done

    # 5. 自適應探測 checkouts 目錄位置 (Xcode 可能建立在 .spm_cache/checkouts 或 .spm_cache/SourcePackages/checkouts)
    local actual_checkouts=""
    if [[ -d "${spm_cache_dir}/checkouts" ]]; then
        actual_checkouts="${spm_cache_dir}/checkouts"
    elif [[ -d "${spm_cache_dir}/SourcePackages/checkouts" ]]; then
        actual_checkouts="${spm_cache_dir}/SourcePackages/checkouts"
    else
        local found_c
        found_c=$(find "$spm_cache_dir" -maxdepth 3 -type d -name "checkouts" 2>/dev/null | head -n 1 || true)
        if [[ -n "$found_c" && -d "$found_c" ]]; then
            actual_checkouts="$found_c"
        fi
    fi

    if [[ -n "$actual_checkouts" && -d "$actual_checkouts" ]]; then
        local pkg_count
        pkg_count=$(find "$actual_checkouts" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo "  [SPM 解析] 成功拉取 SPM 套件庫原始碼 (共 $pkg_count 個套件，路徑: $actual_checkouts)" >&2
        echo "$actual_checkouts"
        return 0
    else
        echo "  [SPM 探測] 專案 [$proj_name] 未發現需拉取的 SPM 套件依賴。" >&2
    fi

    return 0
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

# 決定日誌集中輸出目錄 (優先順序: 1. -l/--log-dir -> 2. $WORKSPACE/mend-logs)
EFFECTIVE_LOG_DIR=""
if [[ -n "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    EFFECTIVE_LOG_DIR="$(cd "$LOG_DIR" && pwd)"
elif [[ -n "${WORKSPACE:-}" ]]; then
    EFFECTIVE_LOG_DIR="${WORKSPACE}/mend-logs"
fi

echo -e "  [設定檔路徑] $CONFIG_FILE_ABS"
echo -e "  [專案根目錄] $RESOLVED_PROJECT_ROOT"
echo -e "  [Mend工具包] $MEND_DIR_ABS"
echo -e "  [Java執行檔] ${JAVA_BIN:-'未找到 (DryRun 可繼續)'}"
echo -e "  [UnifiedAgent] ${UA_JAR:-'未找到'}"
echo -e "  [產品名稱]   $JSON_PRODUCT"
if [[ -n "$EFFECTIVE_LOG_DIR" ]]; then
    echo -e "  [日誌歸檔]   $EFFECTIVE_LOG_DIR"
fi
echo ""

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
    PROJ_VER="$(get_proj_field "$i" 'version')"
    PROJ_RULE="$(get_proj_field "$i" 'versionRule')"
    PROJ_FLAVOR="$(get_proj_field "$i" 'flavor')"
    PROJ_VER_FILE="$(get_proj_field "$i" 'versionFile')"

    echo -e "${MAGENTA}------------------------------------------------------------------------${NC}"
    echo -e "${BOLD}${MAGENTA}>> 處理專案 [$((i+1))/$PROJECT_COUNT]: $PROJ_NAME${NC}"
    echo -e "${MAGENTA}------------------------------------------------------------------------${NC}"

    # A. 平台過濾 (macOS 執行環境下自動略過 windows 專案，相容 ios/macos/all)
    plat_lower=$(echo "${PROJ_PLATFORM:-all}" | tr '[:upper:]' '[:lower:]')
    if [[ "$plat_lower" == "windows" || "$plat_lower" == "win" || "$plat_lower" == "win32" || "$plat_lower" == "win64" ]]; then
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

    # C. 組合 Mend Project 完整名稱 (僅在明確指定非 all/any 的 platform 時才嵌入前綴)
    PROJ_FULL_NAME="$PROJ_NAME"
    if [[ -n "$PROJ_PLATFORM" && "$plat_lower" != "all" && "$plat_lower" != "any" ]]; then
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

    # 支援 Swift Package Manager (SPM) 依賴套件自動掛載
    SPM_CHECKOUTS_DIR=$(resolve_spm_dependencies "$PROJ_NAME" "$PROJ_PLATFORM" "$PROJ_RULE" "$RESOLVED_PROJECT_ROOT" "${current_paths[@]}" | tail -n 1)
    if [[ -n "$SPM_CHECKOUTS_DIR" && -d "$SPM_CHECKOUTS_DIR" ]]; then
        mkdir -p "${SOURCE_CODE_DIR}/spm_packages"
        for pkg_dir in "$SPM_CHECKOUTS_DIR"/*; do
            if [[ -d "$pkg_dir" ]]; then
                pkg_base="$(basename "$pkg_dir")"
                ln -sf "$pkg_dir" "${SOURCE_CODE_DIR}/spm_packages/${pkg_base}"
            fi
        done
        echo -e "${GREEN}  [SPM 掛載] 已將 SPM 依賴套件原始碼鏡像掛載至 SourceCode/spm_packages (共 $(find "$SPM_CHECKOUTS_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') 個套件)${NC}"
        ((MOUNTED_COUNT++))
    fi

    if [[ "$MOUNTED_COUNT" -eq 0 ]]; then
        echo -e "${RED}  [錯誤] 專案 [$PROJ_NAME] 未能成功掛載任何路徑！${NC}" >&2
        ((FAIL_COUNT++))
        continue
    fi

    # E. 專案技術棧感知：僅在 Gradle 專案時動態注入 Gradle PATH
    CURRENT_ENV_PATH="$PATH"
    if test_is_gradle_project "$RESOLVED_PROJECT_ROOT" "${current_paths[@]}"; then
        DETECTED_GRADLE_BIN=$(resolve_gradle_bin_path "$RESOLVED_PROJECT_ROOT" "${current_paths[@]}")
        if [[ -n "$DETECTED_GRADLE_BIN" && -d "$DETECTED_GRADLE_BIN" ]]; then
            export PATH="${DETECTED_GRADLE_BIN}:${PATH}"
            echo -e "${GREEN}  [Gradle 注入] 已動態將 Gradle bin 加入當前專案執行環境 PATH${NC}"
        fi
    fi

    # F. DryRun 模式
    if [[ "$DRY_RUN" = true ]]; then
        echo -e "${GREEN}  [DryRun] 目錄組裝完成 (共 $MOUNTED_COUNT 項)，略過離線掃描與上傳。${NC}"
        while IFS='=' read -r mkey mval; do
            [[ -n "$mkey" ]] && echo -e "  [DryRun 成果] 偵測到專案級 mendArgs: -${mkey} \"${mval}\""
        done < <(get_proj_mend_args "$i")
        ((SUCCESS_COUNT++))
        export PATH="$CURRENT_ENV_PATH"
        continue
    fi

    # G. 人工檢視暫停模式
    if [[ "$PAUSE_BEFORE_SCAN" = true ]]; then
        echo -e "${YELLOW}\n  [Pause] 已暫停，請檢視暫存目錄: $SOURCE_CODE_DIR${NC}"
        read -p "  按 [Enter] 鍵繼續執行離線掃描..."
    fi

    # 動態生成專案級 Runtime Config (支援增量 excludes 與 Properties 原生覆蓋，100% 規避 CLI 跳脫問題)
    EFFECTIVE_SCAN_CONFIG="$SCAN_CONFIG"
    RUNTIME_CONFIG_FILE=""

    MEND_ARGS_RAW=$(get_proj_mend_args "$i")
    if [[ -n "$MEND_ARGS_RAW" && -f "$SCAN_CONFIG" ]]; then
        RUNTIME_CONFIG_FILE="${SCAN_DIR}/Config/wss-runtime-${i}-$$.config"
        cp -f "$SCAN_CONFIG" "$RUNTIME_CONFIG_FILE"

        BASE_EXCLUDES=$(grep -E '^\s*excludes\s*=' "$SCAN_CONFIG" | head -n 1 | sed -E 's/^\s*excludes\s*=\s*//' | tr -d '\r' || true)

        echo "" >> "$RUNTIME_CONFIG_FILE"
        echo "# ===============================================================" >> "$RUNTIME_CONFIG_FILE"
        echo "# Project Dynamic Injected Configurations (mendArgs)" >> "$RUNTIME_CONFIG_FILE"
        echo "# ===============================================================" >> "$RUNTIME_CONFIG_FILE"

        while IFS='=' read -r mkey mval; do
            [[ -z "$mkey" ]] && continue
            local_key_l=$(echo "$mkey" | tr '[:upper:]' '[:lower:]')
            if [[ "$local_key_l" == "excludes" ]]; then
                effective_excl="$mval"
                if [[ -n "$BASE_EXCLUDES" ]]; then
                    effective_excl="${BASE_EXCLUDES} ${mval}"
                fi
                # 替換或追加 excludes
                if grep -q -E '^\s*excludes\s*=' "$RUNTIME_CONFIG_FILE"; then
                    # 避免 sed 遇到特殊字元報錯，直接透過 python 乾淨替換或追加
                    python3 -c "
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    lines = f.readlines()
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for line in lines:
        if line.strip().startswith('excludes='):
            f.write(f'excludes={sys.argv[2]}\n')
        else:
            f.write(line)
" "$RUNTIME_CONFIG_FILE" "$effective_excl"
                else
                    echo "excludes=${effective_excl}" >> "$RUNTIME_CONFIG_FILE"
                fi
                echo -e "  [mendArgs 注入] 增量排除清單 (excludes): $effective_excl"
            else
                echo "${mkey}=${mval}" >> "$RUNTIME_CONFIG_FILE"
                echo -e "  [mendArgs 注入] 寫入設定檔 ${mkey}=${mval}"
            fi
        done < <(get_proj_mend_args "$i")

        EFFECTIVE_SCAN_CONFIG="$RUNTIME_CONFIG_FILE"
        echo -e "  [mendArgs 產生] 已生成專案專屬 Runtime Config: $RUNTIME_CONFIG_FILE"
    fi

    # H. 執行 Java 離線掃描 (Offline Scan)
    echo -e "  [掃描開始] 呼叫 Unified Agent 執行離線掃描 (載入 Config: $EFFECTIVE_SCAN_CONFIG)..."
    (
        cd "$SCAN_DIR"
        "$JAVA_BIN" -Dfile.encoding=UTF-8 \
            -jar "$UA_JAR" \
            -c "$EFFECTIVE_SCAN_CONFIG" \
            -d "SourceCode" \
            -apiKey "$RESOLVED_API_KEY" \
            -userKey "$RESOLVED_USER_KEY" \
            -product "$JSON_PRODUCT" \
            -project "$PROJ_FULL_NAME"
    )

    # 清理暫存 runtime config
    if [[ -n "$RUNTIME_CONFIG_FILE" && -f "$RUNTIME_CONFIG_FILE" ]]; then
        rm -f "$RUNTIME_CONFIG_FILE" 2>/dev/null || true
    fi

    export PATH="$CURRENT_ENV_PATH"

    SCAN_UPDATE_FILE="${SCAN_DIR}/whitesource/update-request.txt"
    if [[ ! -s "$SCAN_UPDATE_FILE" ]]; then
        echo -e "${RED}  [掃描失敗] 未產出 update-request.txt 或檔案為空: $SCAN_UPDATE_FILE${NC}" >&2
        ((FAIL_COUNT++))
        continue
    fi
    echo -e "${GREEN}  [掃描成功] 產出離線記錄檔: $SCAN_UPDATE_FILE${NC}"

    # 若開啟 ScanOnly (或 SkipUpload)，產出記錄檔後略過上傳作業
    if [[ "$SCAN_ONLY" = true ]]; then
        echo -e "${CYAN}  [ScanOnly] 離線掃描完成，略過上傳步驟: $SCAN_UPDATE_FILE${NC}"
        echo -e "${GREEN}  [專案成功] 專案 [$PROJ_FULL_NAME] 離線掃描完成 (ScanOnly)。${NC}"
        ((SUCCESS_COUNT++))
        continue
    fi

    # H. 準備上傳
    UPLOAD_REQ_FILE="${UPLOAD_DIR}/UploadFile/update-request.txt"
    mkdir -p "$(dirname "$UPLOAD_REQ_FILE")"
    cp -f "$SCAN_UPDATE_FILE" "$UPLOAD_REQ_FILE"

    echo -e "  [上傳開始] 呼叫 Unified Agent 上傳中繼資料至 Mend.io..."
    upload_args=(
        "$JAVA_BIN" -Dfile.encoding=UTF-8
        -jar "$UA_JAR"
    )
    if [[ -n "$UPLOAD_CONFIG" && -f "$UPLOAD_CONFIG" ]]; then
        upload_args+=(-c "$UPLOAD_CONFIG")
    fi
    upload_args+=(
        -apiKey "$RESOLVED_API_KEY"
        -userKey "$RESOLVED_USER_KEY"
        -requestFiles "UploadFile/update-request.txt"
    )

    (
        cd "$UPLOAD_DIR"
        "${upload_args[@]}"
    )
    echo -e "${GREEN}  [上傳成功] 專案 [$PROJ_FULL_NAME] 上傳完成！${NC}"
    ((SUCCESS_COUNT++))

    # 集中歸檔 Mend 日誌 (Scan + Upload) 並清空工具包殘留 (防止 Build Server 磁碟爆滿)
    for stage_info in "Scan:${SCAN_DIR}/whitesource" "Upload:${UPLOAD_DIR}/whitesource"; do
        stage_name="${stage_info%%:*}"
        ws_dir="${stage_info#*:}"
        if [[ -d "$ws_dir" ]]; then
            if [[ -n "$EFFECTIVE_LOG_DIR" && -n "$PROJ_FULL_NAME" ]]; then
                proj_log_dest="${EFFECTIVE_LOG_DIR}/${PROJ_FULL_NAME}"
                mkdir -p "$proj_log_dest"
                for item in "$ws_dir"/*; do
                    [[ ! -e "$item" ]] && continue
                    item_base="$(basename "$item")"
                    [[ "$item_base" == "update-request.txt" ]] && continue
                    dest_item="${proj_log_dest}/${stage_name}_${item_base}"
                    cp -R "$item" "$dest_item" 2>/dev/null || true
                    rm -rf "$item" 2>/dev/null || true
                done
            else
                find "$ws_dir" -mindepth 1 -maxdepth 1 -type d ! -name "update-request.txt" -exec rm -rf {} + 2>/dev/null || true
            fi
        fi
    done
    if [[ -n "$EFFECTIVE_LOG_DIR" && -n "$PROJ_FULL_NAME" ]]; then
        echo -e "${CYAN}  [日誌歸檔] 已將 Scan/Upload 日誌加上前綴並安全移至: ${EFFECTIVE_LOG_DIR}/${PROJ_FULL_NAME}${NC}"
    fi
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
