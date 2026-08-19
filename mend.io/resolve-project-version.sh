#!/usr/bin/env bash
# ==============================================================================
# Script Name: resolve-project-version.sh
# Version    : 1.5.0
# Description: Mend.io Automation - Project Version Resolver Module for macOS / Linux
# ==============================================================================

# 輔助函式：自文字檔或變數中提取版本
resolve_project_version() {
    local project_root="$1"
    local proj_name="$2"
    local explicit_version="$3"
    local rule="$4"
    local flavor="$5"
    local version_file="$6"
    local default_version_tag="$7"
    shift 7
    local paths=("$@")

    # 1. 優先使用手動指定的固定版本 (非 "auto" 且非空)
    if [[ -n "$explicit_version" && "$explicit_version" != "auto" && "$explicit_version" != "null" ]]; then
        echo "  [版本萃取] 專案 [$proj_name] 採用 JSON 手動指定版本: $explicit_version" >&2
        echo "$explicit_version"
        return 0
    fi

    # 2. 若未設定 versionRule
    if [[ -z "$rule" || "$rule" == "null" ]]; then
        if [[ -n "$version_file" && "$version_file" != "null" ]]; then
            rule="file"
        else
            if [[ -n "$default_version_tag" && "$default_version_tag" != "null" ]]; then
                echo "  [版本萃取] 專案 [$proj_name] 未設定規則，採用全域 VersionTag: $default_version_tag" >&2
                echo "$default_version_tag"
                return 0
            fi
            local fallback_date
            fallback_date=$(date +"%Y.%m.%d")
            echo "  [版本萃取] 專案 [$proj_name] 未設定規則且無全域標籤，保底採用當前日期: $fallback_date" >&2
            echo "$fallback_date"
            return 0
        fi
    fi

    local extracted_version=""
    local lower_rule
    lower_rule=$(echo "$rule" | tr '[:upper:]' '[:lower:]')

    # 3. 依據 rule 進行解析
    case "$lower_rule" in
        android)
            echo "  [版本探測] 專案 [$proj_name] 開始搜尋 Android 版本定義..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    if [[ "$p" == *build.gradle* ]]; then
                        candidates+=("${project_root}/${p}")
                    else
                        candidates+=("${project_root}/${p}/app/build.gradle.kts")
                        candidates+=("${project_root}/${p}/app/build.gradle")
                        candidates+=("${project_root}/${p}/application/build.gradle.kts")
                        candidates+=("${project_root}/${p}/application/build.gradle")
                        candidates+=("${project_root}/${p}/build.gradle.kts")
                        candidates+=("${project_root}/${p}/build.gradle")
                    fi
                done
                candidates+=("${project_root}/app/build.gradle.kts")
                candidates+=("${project_root}/app/build.gradle")
                candidates+=("${project_root}/build.gradle.kts")
                candidates+=("${project_root}/build.gradle")
            fi

            for file in "${candidates[@]}"; do
                if [[ -f "$file" ]]; then
                    echo "  [版本探測] 找到檔案: $file" >&2

                    # A. 若指定 Flavor，優先在 Flavor 區塊內搜尋
                    if [[ -n "$flavor" && "$flavor" != "null" ]]; then
                        local flavor_ver
                        flavor_ver=$(python3 -c "
import sys, re
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        c = f.read()
    flv = sys.argv[2]
    m = re.search(r'(?:create\s*\(\s*[\"|\']' + flv + r'[\"|\']\s*\)|' + flv + r'\s*\{)(.*?)\}', c, re.DOTALL)
    if m:
        vm = re.search(r'versionName\s*(?:=|\.set\s*\(|\s)\s*[\"|\']([^\"|\']+)[\"|\']', m.group(1))
        if vm:
            print(vm.group(1).strip())
except Exception:
    pass
" "$file" "$flavor" 2>/dev/null)
                        if [[ -n "$flavor_ver" ]]; then
                            extracted_version="$flavor_ver"
                            echo "  [版本萃取] 專案 [$proj_name] 依據 [android(flavor=$flavor)] 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                            break
                        fi
                    fi

                    # B. 退回 defaultConfig.versionName
                    local def_ver
                    def_ver=$(python3 -c "
import sys, re
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        c = f.read()
    m = re.search(r'defaultConfig\s*\{(.*?)\}', c, re.DOTALL)
    if m:
        vm = re.search(r'versionName\s*(?:=|\.set\s*\(|\s)\s*[\"|\']([^\"|\']+)[\"|\']', m.group(1))
        if vm:
            print(vm.group(1).strip())
except Exception:
    pass
" "$file" 2>/dev/null)
                    if [[ -n "$def_ver" ]]; then
                        extracted_version="$def_ver"
                        local notice=""
                        [[ -n "$flavor" && "$flavor" != "null" ]] && notice=" (Flavor '$flavor' 無專屬版本，自動退回 defaultConfig)"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [android] defaultConfig 從 [$(basename "$file")] 成功解析: ${extracted_version}${notice}" >&2
                        break
                    fi

                    # C. 全域 versionName
                    local gen_ver
                    gen_ver=$(python3 -c "
import sys, re
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        c = f.read()
    vm = re.search(r'versionName\s*(?:=|\.set\s*\(|\s)\s*[\"|\']([^\"|\']+)[\"|\']', c)
    if vm:
        print(vm.group(1).strip())
except Exception:
    pass
" "$file" 2>/dev/null)
                    if [[ -n "$gen_ver" ]]; then
                        extracted_version="$gen_ver"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [android] 全域 versionName 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                        break
                    fi
                fi
            done

            # D. 屬性檔 (gradle.properties, version.properties, libs.versions.toml)
            if [[ -z "$extracted_version" ]]; then
                local prop_candidates=()
                for p in "${paths[@]}"; do
                    prop_candidates+=("${project_root}/${p}/gradle.properties")
                    prop_candidates+=("${project_root}/${p}/version.properties")
                    prop_candidates+=("${project_root}/${p}/gradle/libs.versions.toml")
                done
                prop_candidates+=("${project_root}/gradle.properties")
                prop_candidates+=("${project_root}/version.properties")
                prop_candidates+=("${project_root}/gradle/libs.versions.toml")

                for pfile in "${prop_candidates[@]}"; do
                    if [[ -f "$pfile" ]]; then
                        echo "  [版本探測] 檢查屬性檔: $pfile" >&2
                        local p_ver
                        p_ver=$(grep -E '^[[:space:]]*(VERSION_NAME|versionName|VERSION|version|appVersion|app-version)[[:space:]]*[=:][[:space:]]*' "$pfile" | head -n 1 | sed -E 's/^[[:space:]]*(VERSION_NAME|versionName|VERSION|version|appVersion|app-version)[[:space:]]*[=:][[:space:]]*["'\'']?([^"'\'']+)["'\'']?/\2/' | tr -d '\r\n ')
                        if [[ -n "$p_ver" ]]; then
                            extracted_version="$p_ver"
                            echo "  [版本萃取] 專案 [$proj_name] 依據 [android] 規則從 [$(basename "$pfile")] 成功解析: $extracted_version" >&2
                            break
                        fi
                    fi
                done
            fi
            ;;

        buildspec|buildspec.json|obs-plugin)
            echo "  [版本探測] 專案 [$proj_name] 開始搜尋 buildspec.json 版本定義..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    if [[ "$p" == *.json ]]; then
                        candidates+=("${project_root}/${p}")
                    else
                        candidates+=("${project_root}/${p}/buildspec.json")
                    fi
                done
                candidates+=("${project_root}/buildspec.json")
            fi

            for file in "${candidates[@]}"; do
                if [[ -f "$file" ]]; then
                    echo "  [版本探測] 找到檔案: $file" >&2
                    local b_ver
                    b_ver=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        d = json.load(f)
        print(d.get('version', '').strip())
except Exception:
    pass
" "$file" 2>/dev/null)
                    if [[ -n "$b_ver" ]]; then
                        extracted_version="$b_ver"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [buildspec] 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                        break
                    fi
                fi
            done
            ;;

        qt-cmake|cmake)
            echo "  [版本探測] 專案 [$proj_name] 開始搜尋 CMakeLists.txt 版本定義..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    if [[ "$p" == *CMakeLists.txt ]]; then
                        candidates+=("${project_root}/${p}")
                    else
                        candidates+=("${project_root}/${p}/CMakeLists.txt")
                    fi
                done
                candidates+=("${project_root}/CMakeLists.txt")
            fi

            for file in "${candidates[@]}"; do
                if [[ -f "$file" ]]; then
                    echo "  [版本探測] 找到檔案: $file" >&2
                    local cm_ver
                    cm_ver=$(python3 -c "
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        c = f.read()

    # 1. set(APP_VERSION_MAJOR ...)
    major = re.search(r'set\s*\(\s*APP_VERSION_MAJOR\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    minor = re.search(r'set\s*\(\s*APP_VERSION_MINOR\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    build = re.search(r'set\s*\(\s*APP_VERSION_(?:BUILD|PATCH|MAINTENANCE)\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    if major and minor:
        parts = [major.group(1), minor.group(1)]
        if build: parts.append(build.group(1))
        print('.'.join(parts))
        exit(0)

    # 2. set(VERSION_MAJOR ...)
    major = re.search(r'set\s*\(\s*(?:PROJECT_)?VERSION_MAJOR\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    minor = re.search(r'set\s*\(\s*(?:PROJECT_)?VERSION_MINOR\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    build = re.search(r'set\s*\(\s*(?:PROJECT_)?VERSION_(?:BUILD|PATCH|MAINTENANCE)\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    if major and minor:
        parts = [major.group(1), minor.group(1)]
        if build: parts.append(build.group(1))
        print('.'.join(parts))
        exit(0)

    # 3. set(<PREFIX>_MAJOR ...) + set(<PREFIX>_MINOR ...) + set(<PREFIX>_PATCH ...)
    major_match = re.search(r'set\s*\(\s*([A-Za-z0-9_]+)_(?:MAJOR|VERSION_MAJOR)\s+([0-9]+)\s*\)', c, re.IGNORECASE)
    if major_match:
        prefix = major_match.group(1)
        c_maj = major_match.group(2)
        c_min_match = re.search(r'set\s*\(\s*' + prefix + r'_(?:MINOR|VERSION_MINOR)\s+([0-9]+)\s*\)', c, re.IGNORECASE)
        c_patch_match = re.search(r'set\s*\(\s*' + prefix + r'_(?:PATCH|BUILD|MAINTENANCE|VERSION_PATCH|VERSION_BUILD)\s+([0-9]+)\s*\)', c, re.IGNORECASE)
        if c_min_match:
            parts = [c_maj, c_min_match.group(1)]
            if c_patch_match:
                parts.append(c_patch_match.group(1))
            print('.'.join(parts))
            exit(0)

    # 4. project(... VERSION 4.0.9 ...)
    pm = re.search(r'project\s*\([^)]*VERSION\s+([0-9\.]+)', c, re.DOTALL | re.IGNORECASE)
    if pm:
        print(pm.group(1).strip())
        exit(0)

    # 5. set(PROJECT_VERSION ...)
    sm = re.search(r'set\s*\(\s*(?:PROJECT_VERSION|APP_VERSION|VERSION)\s+[\"|\']?([0-9\.]+)[\"|\']?\s*\)', c, re.IGNORECASE)
    if sm:
        print(sm.group(1).strip())
        exit(0)
except Exception:
    pass
" "$file" 2>/dev/null)
                    if [[ -n "$cm_ver" ]]; then
                        extracted_version="$cm_ver"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [qt-cmake] 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                        break
                    fi
                fi
            done
            ;;

        qt-qmake|qmake|pri)
            echo "  [版本探測] 專案 [$proj_name] 開始搜尋 qmake / pri 版本定義..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    if [[ "$p" == *.pri || "$p" == *.pro ]]; then
                        candidates+=("${project_root}/${p}")
                    else
                        candidates+=("${project_root}/${p}/versions.pri")
                        candidates+=("${project_root}/${p}/version.pri")
                    fi
                done
                candidates+=("${project_root}/versions.pri")
                candidates+=("${project_root}/version.pri")
            fi

            for file in "${candidates[@]}"; do
                if [[ -f "$file" ]]; then
                    echo "  [版本探測] 找到檔案: $file" >&2
                    local qm_ver
                    qm_ver=$(python3 -c "
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        c = f.read()

    # 1. APP_VERSION_MAJOR
    major = re.search(r'^\s*APP_VERSION_MAJOR\s*=\s*([0-9]+)', c, re.MULTILINE)
    minor = re.search(r'^\s*APP_VERSION_MINOR\s*=\s*([0-9]+)', c, re.MULTILINE)
    maint = re.search(r'^\s*APP_VERSION_(?:MAINTENANCE|PATCH)\s*=\s*([0-9]+)', c, re.MULTILINE)
    build = re.search(r'^\s*APP_VERSION_BUILD\s*=\s*([0-9]+)', c, re.MULTILINE)
    if major and minor:
        parts = [major.group(1), minor.group(1)]
        if maint: parts.append(maint.group(1))
        if build: parts.append(build.group(1))
        print('.'.join(parts))
        exit(0)

    # 2. VERSION_MAJOR
    major = re.search(r'^\s*VERSION_MAJOR\s*=\s*([0-9]+)', c, re.MULTILINE)
    minor = re.search(r'^\s*VERSION_MINOR\s*=\s*([0-9]+)', c, re.MULTILINE)
    maint = re.search(r'^\s*VERSION_(?:MAINTENANCE|PATCH)\s*=\s*([0-9]+)', c, re.MULTILINE)
    build = re.search(r'^\s*VERSION_BUILD\s*=\s*([0-9]+)', c, re.MULTILINE)
    if major and minor:
        parts = [major.group(1), minor.group(1)]
        if maint: parts.append(maint.group(1))
        if build: parts.append(build.group(1))
        print('.'.join(parts))
        exit(0)

    # 3. VERSION = x.y.z
    vm = re.search(r'^\s*(?:APP_VERSION|VERSION)\s*=\s*([0-9\.]+)', c, re.MULTILINE)
    if vm:
        print(vm.group(1).strip())
        exit(0)
except Exception:
    pass
" "$file" 2>/dev/null)
                    if [[ -n "$qm_ver" ]]; then
                        extracted_version="$qm_ver"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [qt-qmake] 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                        break
                    fi
                fi
            done
            ;;

        ios|xcode|apple|macos-app)
            echo "  [版本探測] 專案 [$proj_name] 開始搜尋 iOS / Xcode 版本定義..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    if [[ "$p" == *.pbxproj || "$p" == *.plist || "$p" == *.xcconfig || "$p" == *.podspec ]]; then
                        candidates+=("${project_root}/${p}")
                    elif [[ "$p" == *.xcodeproj ]]; then
                        candidates+=("${project_root}/${p}/project.pbxproj")
                    else
                        candidates+=("${project_root}/${p}/*.xcodeproj/project.pbxproj")
                        candidates+=("${project_root}/${p}/*/*.xcodeproj/project.pbxproj")
                        candidates+=("${project_root}/${p}/project.pbxproj")
                        candidates+=("${project_root}/${p}/Info.plist")
                        candidates+=("${project_root}/${p}/*/Info.plist")
                        candidates+=("${project_root}/${p}/*.xcconfig")
                        candidates+=("${project_root}/${p}/*.podspec")
                    fi
                done
                candidates+=("${project_root}/*.xcodeproj/project.pbxproj")
                candidates+=("${project_root}/*/*.xcodeproj/project.pbxproj")
                candidates+=("${project_root}/Info.plist")
                candidates+=("${project_root}/*/Info.plist")
                candidates+=("${project_root}/*.xcconfig")
                candidates+=("${project_root}/*.podspec")
            fi

            local real_candidates=()
            for cand_pattern in "${candidates[@]}"; do
                if [[ "$cand_pattern" == *"*"* ]]; then
                    shopt -s nullglob
                    for cf in $cand_pattern; do
                        [[ -f "$cf" ]] && real_candidates+=("$cf")
                    done
                    shopt -u nullglob
                else
                    [[ -f "$cand_pattern" ]] && real_candidates+=("$cand_pattern")
                fi
            done

            for file in "${real_candidates[@]}"; do
                echo "  [版本探測] 找到檔案: $file" >&2
                local ios_ver
                ios_ver=$(python3 -c "
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='ignore') as f:
        c = f.read()

    # 1. project.pbxproj 或 .xcconfig 中的 MARKETING_VERSION (優先)
    m = re.search(r'MARKETING_VERSION\s*=\s*[\"|\']?([0-9\.]+)[\"|\']?\s*;?', c)
    if m:
        print(m.group(1).strip())
        exit(0)

    # 2. project.pbxproj 中的 CURRENT_PROJECT_VERSION (退回)
    m = re.search(r'CURRENT_PROJECT_VERSION\s*=\s*[\"|\']?([0-9\.]+)[\"|\']?\s*;?', c)
    if m:
        print(m.group(1).strip())
        exit(0)

    # 3. Info.plist 中的 CFBundleShortVersionString
    m = re.search(r'<key>CFBundleShortVersionString</key>\s*<string>([0-9\.]+)</string>', c)
    if m:
        print(m.group(1).strip())
        exit(0)

    # 4. Info.plist 中的 CFBundleVersion (退回)
    m = re.search(r'<key>CFBundleVersion</key>\s*<string>([0-9\.]+)</string>', c)
    if m:
        print(m.group(1).strip())
        exit(0)

    # 5. CocoaPods podspec 中的 s.version
    m = re.search(r'(?:s|spec)\.version\s*=\s*[\"|\']([0-9\.]+)[\"|\']', c)
    if m:
        print(m.group(1).strip())
        exit(0)
except Exception:
    pass
" "$file" 2>/dev/null)
                if [[ -n "$ios_ver" ]]; then
                    extracted_version="$ios_ver"
                    echo "  [版本萃取] 專案 [$proj_name] 依據 [ios] 從 [$(basename "$file")] 成功解析: $extracted_version" >&2
                    break
                fi
            done
            ;;

        file|plain-file)
            echo "  [版本探測] 專案 [$proj_name] 開始讀取純文字版本檔案..." >&2
            local candidates=()
            if [[ -n "$version_file" && "$version_file" != "null" ]]; then
                candidates+=("${project_root}/${version_file}")
            else
                for p in "${paths[@]}"; do
                    candidates+=("${project_root}/${p}/VERSION")
                    candidates+=("${project_root}/${p}/version.txt")
                done
                candidates+=("${project_root}/VERSION")
                candidates+=("${project_root}/version.txt")
            fi

            for file in "${candidates[@]}"; do
                if [[ -f "$file" ]]; then
                    echo "  [版本探測] 找到檔案: $file" >&2
                    local first_line
                    first_line=$(head -n 1 "$file" | tr -d '\r\n ')
                    if [[ -n "$first_line" ]]; then
                        extracted_version="$first_line"
                        echo "  [版本萃取] 專案 [$proj_name] 依據 [file] 從 [$(basename "$file")] 成功讀取: $extracted_version" >&2
                        break
                    fi
                fi
            done
            ;;

        *)
            echo "  [版本萃取] 尚未支援的 versionRule: '$rule'，將採用預設版本。" >&2
            ;;
    esac

    # 4. Fallback 處理
    if [[ -z "$extracted_version" ]]; then
        if [[ -n "$default_version_tag" && "$default_version_tag" != "null" ]]; then
            echo "  [版本萃取] 專案 [$proj_name] 規則 [$rule] 未解析出版本，Fallback 採用全域 VersionTag: $default_version_tag" >&2
            echo "$default_version_tag"
            return 0
        fi
        local fallback_date
        fallback_date=$(date +"%Y.%m.%d")
        echo "  [版本萃取] 專案 [$proj_name] 規則 [$rule] 未解析出版本且無全域標籤，保底採用當前日期: $fallback_date" >&2
        echo "$fallback_date"
        return 0
    fi

    echo "$extracted_version"
    return 0
}
