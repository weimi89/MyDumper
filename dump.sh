#!/bin/bash
# ============================================
# MyDumper 資料庫備份腳本
# 用法: ./dump.sh [設定檔]
# 自動判斷：有 databases.ini 則批次備份，否則單一備份
# ============================================

# 不使用 set -e，改為手動處理錯誤

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/backup.conf}"
DATABASES_FILE="${SCRIPT_DIR}/databases.ini"

# 載入設定檔
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] 找不到設定檔: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# 時間變數
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DATE_TODAY=$(date +"%Y%m%d")

# 日誌目錄（預設為專案目錄下的 logs）
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"

# 建立目錄
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# 日誌檔案
LOG_FILE="${LOG_DIR}/dump_${DATE_TODAY}.log"

# 日誌函數
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# 進度顯示函數
progress() {
    echo -e "\033[1;36m>>>\033[0m $1"
}

# 檢查 mydumper 命令（優先使用設定檔中的路徑）
if [[ -n "$MYDUMPER_BIN" && -x "$MYDUMPER_BIN" ]]; then
    : # 使用設定檔中的路徑
elif command -v mydumper &>/dev/null; then
    MYDUMPER_BIN="mydumper"
elif [[ -x "/usr/local/bin/mydumper" ]]; then
    MYDUMPER_BIN="/usr/local/bin/mydumper"
elif [[ -x "/usr/bin/mydumper" ]]; then
    MYDUMPER_BIN="/usr/bin/mydumper"
else
    echo -e "\033[1;31m[ERROR] 找不到 mydumper 命令！\033[0m"
    echo ""
    echo "請執行以下命令尋找 mydumper 位置："
    echo "  find /usr -name 'mydumper' 2>/dev/null"
    echo ""
    echo "然後在 backup.conf 中設定："
    echo "  MYDUMPER_BIN=\"/path/to/mydumper\""
    exit 1
fi
echo "使用 mydumper: $MYDUMPER_BIN"

# ============================================
# 單一資料庫備份函數
# ============================================
dump_single() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local dbname="$5"

    # 決定備份子目錄名稱
    local db_dir_name="${dbname:-all_databases}"

    # 備份路徑：{BACKUP_DIR}/database/{DB_NAME}/{YYYYMMDD}
    local backup_path="${BACKUP_DIR}/database/${db_dir_name}/${DATE_TODAY}"
    mkdir -p "$backup_path"

    log "INFO" "備份路徑: $backup_path"
    progress "連線 $user@$host:$port ..."

    # 建構 mydumper 命令
    local cmd="$MYDUMPER_BIN -h $host -P $port -u $user"

    # 密碼
    [[ -n "$pass" ]] && cmd+=" -p '$pass'"

    # 指定資料庫
    if [[ -n "$dbname" ]]; then
        cmd+=" -B $dbname"
        log "INFO" "備份資料庫: $dbname"
    else
        log "INFO" "備份全部資料庫"
    fi

    # 輸出目錄
    cmd+=" -o $backup_path"

    # 執行緒數（自動偵測 CPU 核心數 - 2）
    local threads="$THREADS"
    if [[ "$threads" -eq 0 ]]; then
        local cpu_cores
        if [[ "$(uname)" == "Darwin" ]]; then
            cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
        else
            cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
        fi
        threads=$((cpu_cores > 2 ? cpu_cores - 2 : 1))
        log "INFO" "CPU 核心數: $cpu_cores，使用執行緒: $threads"
    fi
    cmd+=" -t $threads"

    # 分塊大小
    cmd+=" -r $CHUNK_SIZE"

    # 壓縮
    [[ "$COMPRESS" -eq 1 ]] && cmd+=" -c" && log "INFO" "啟用壓縮"

    # 詳細模式（預設啟用以顯示進度）
    cmd+=" -v 3"

    # 預存程序、觸發器
    [[ "${DUMP_ROUTINES:-1}" -eq 1 ]] && cmd+=" --routines"
    [[ "${DUMP_TRIGGERS:-1}" -eq 1 ]] && cmd+=" --triggers"

    # 執行備份（計時）
    log "INFO" "執行備份..."
    log "INFO" "命令: $MYDUMPER_BIN -h $host -P $port -u $user -B $dbname -o $backup_path ..."
    progress "正在備份 ${db_dir_name} (執行中，請稍候...)"
    local start_time=$(date +%s)
    local status="SUCCESS"

    # 執行並即時顯示輸出（同時寫入日誌）
    local cmd_exit
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    cmd_exit=${PIPESTATUS[0]}

    if [[ $cmd_exit -eq 0 ]]; then
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        local elapsed_min=$((elapsed / 60))
        local elapsed_sec=$((elapsed % 60))
        local backup_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "0")
        log "INFO" "備份完成! 耗時: ${elapsed_min}分${elapsed_sec}秒，大小: $backup_size"
        echo -e "\033[1;32m✓ ${db_dir_name} 完成\033[0m (${elapsed_min}分${elapsed_sec}秒, ${backup_size})"
    else
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log "ERROR" "備份失敗! 耗時: ${elapsed}秒 (exit code: $cmd_exit)"
        echo -e "\033[1;31m✗ ${db_dir_name} 失敗 (exit code: $cmd_exit)\033[0m"
        status="FAILED"
    fi

    # 清理舊備份
    local db_backup_dir="${BACKUP_DIR}/database/${db_dir_name}"
    if [[ "$RETENTION_DAYS" -gt 0 ]]; then
        log "INFO" "清理 ${db_dir_name} 目錄下 $RETENTION_DAYS 天前的舊備份..."
        local deleted=0
        while IFS= read -r old; do
            if [[ -d "$old" ]]; then
                rm -rf "$old" && log "INFO" "已刪除: $old"
                deleted=$((deleted + 1))
            fi
        done < <(find "$db_backup_dir" -maxdepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null || true)
        log "INFO" "共刪除 $deleted 個舊備份"
    fi

    # 統計
    local count
    count=$(find "$db_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ') || count=0
    log "INFO" "${db_dir_name} 目前備份數量: $count"

    [[ "$status" == "SUCCESS" ]] && return 0 || return 1
}

# ============================================
# 主程式
# ============================================
log "INFO" "========== 備份開始 =========="
log "INFO" "設定檔: $CONFIG_FILE"

# ============================================
# INI 格式解析函數
# ============================================
parse_ini_value() {
    local value="$1"
    # 移除前後空白
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    # 移除引號（如果有的話）
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    echo "$value"
}

# 檢查是否有 databases.ini 且有有效的 INI section
HAS_DB_LIST=0
if [[ -f "$DATABASES_FILE" ]]; then
    # 檢查是否有 [database_ 開頭的 section（排除註解行）
    if grep -qE '^\s*\[database_' "$DATABASES_FILE" 2>/dev/null; then
        HAS_DB_LIST=1
    fi
fi

if [[ "$HAS_DB_LIST" -eq 1 ]]; then
    # ===== 批次備份模式 (INI 格式) =====
    log "INFO" "模式: 批次備份 (databases.ini)"

    # 計算資料庫數量（計算 section 數量）
    DB_COUNT=$(grep -cE '^\s*\[database_' "$DATABASES_FILE" 2>/dev/null || echo 0)
    echo ""
    echo "=========================================="
    echo "  批次備份模式 - 共 $DB_COUNT 個資料庫"
    echo "=========================================="
    echo ""

    TOTAL=0
    SUCCESS=0
    FAILED=0
    FAILED_DBS=""

    # 解析 INI 格式
    current_section=""
    db_host="" db_port="" db_user="" db_pass="" db_name=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 移除前後空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 跳過空行和註解
        [[ -z "$line" || "$line" =~ ^[#\;] ]] && continue

        # 檢測 section 開頭 [database_xxx]
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            # 如果有前一個 section 的資料，先執行備份
            if [[ -n "$current_section" && -n "$db_host" && -n "$db_user" && -n "$db_name" ]]; then
                db_port="${db_port:-3306}"
                TOTAL=$((TOTAL + 1))

                echo ""
                echo "----------------------------------------"
                echo "[$TOTAL/$DB_COUNT] $db_name"
                echo "----------------------------------------"
                log "INFO" "[$TOTAL/$DB_COUNT] 開始備份: $db_name@$db_host:$db_port"

                if dump_single "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
                    SUCCESS=$((SUCCESS + 1))
                else
                    FAILED=$((FAILED + 1))
                    FAILED_DBS="${FAILED_DBS}${db_name}, "
                fi
            fi

            # 開始新 section，重置變數
            current_section="${BASH_REMATCH[1]}"
            db_host="" db_port="" db_user="" db_pass="" db_name=""
            continue
        fi

        # 解析 key = value（只在 database_ section 內）
        if [[ -n "$current_section" && "$current_section" =~ ^database_ ]]; then
            if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                # 移除 key 的前後空白
                key="${key#"${key%%[![:space:]]*}"}"
                key="${key%"${key##*[![:space:]]}"}"
                # 解析 value
                value=$(parse_ini_value "$value")

                case "$key" in
                    host) db_host="$value" ;;
                    port) db_port="$value" ;;
                    user) db_user="$value" ;;
                    pass|password) db_pass="$value" ;;
                    name|database|dbname) db_name="$value" ;;
                esac
            fi
        fi

    done < "$DATABASES_FILE"

    # 處理最後一個 section
    if [[ -n "$current_section" && -n "$db_host" && -n "$db_user" && -n "$db_name" ]]; then
        db_port="${db_port:-3306}"
        TOTAL=$((TOTAL + 1))

        echo ""
        echo "----------------------------------------"
        echo "[$TOTAL/$DB_COUNT] $db_name"
        echo "----------------------------------------"
        log "INFO" "[$TOTAL/$DB_COUNT] 開始備份: $db_name@$db_host:$db_port"

        if dump_single "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_DBS="${FAILED_DBS}${db_name}, "
        fi
    fi

    echo ""
    echo "=========================================="
    echo "  備份完成"
    echo "=========================================="
    echo "  總計: $TOTAL"
    echo -e "  成功: \033[1;32m$SUCCESS\033[0m"
    [[ $FAILED -gt 0 ]] && echo -e "  失敗: \033[1;31m$FAILED\033[0m (${FAILED_DBS%, })"
    echo "=========================================="
    echo ""

    log "INFO" "總計: $TOTAL，成功: $SUCCESS，失敗: $FAILED"
    [[ $FAILED -gt 0 ]] && log "WARN" "失敗的資料庫: ${FAILED_DBS%, }"

else
    # ===== 單一備份模式 =====
    log "INFO" "模式: 單一備份 (backup.conf)"
    echo ""
    echo "=========================================="
    echo "  單一備份模式"
    echo "=========================================="
    echo ""

    if dump_single "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
        echo ""
        echo "=========================================="
        echo -e "  \033[1;32m備份成功\033[0m"
        echo "=========================================="
    else
        echo ""
        echo "=========================================="
        echo -e "  \033[1;31m備份失敗\033[0m"
        echo "=========================================="
    fi
    echo ""
fi

# 清理舊日誌（保留 30 天）
find "$LOG_DIR" -name "dump_*.log" -mtime +30 -delete 2>/dev/null || true

log "INFO" "========== 備份結束 =========="
