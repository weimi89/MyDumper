#!/bin/bash
# ============================================
# MyLoader 資料庫還原腳本
# 用法: ./restore.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# 載入設定
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# 日誌目錄
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
mkdir -p "$LOG_DIR"
DATE_TODAY=$(date +"%Y%m%d")
LOG_FILE="${LOG_DIR}/restore_${DATE_TODAY}.log"

# 顏色
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# 日誌函數
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE"
}

# 檢查 myloader
MYLOADER_BIN=""
if [[ -n "$MYLOADER_BIN" && -x "$MYLOADER_BIN" ]]; then
    :
elif command -v myloader &>/dev/null; then
    MYLOADER_BIN="myloader"
elif [[ -x "/usr/local/bin/myloader" ]]; then
    MYLOADER_BIN="/usr/local/bin/myloader"
elif [[ -x "/usr/bin/myloader" ]]; then
    MYLOADER_BIN="/usr/bin/myloader"
else
    echo -e "${RED}[ERROR] 找不到 myloader 命令！${NC}"
    exit 1
fi

# 備份根目錄
BACKUP_BASE="${BACKUP_DIR}/database"

if [[ ! -d "$BACKUP_BASE" ]]; then
    echo -e "${RED}[ERROR] 備份目錄不存在: $BACKUP_BASE${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo "  MyLoader 資料庫還原工具"
echo "=========================================="
echo ""

# 列出可用的資料庫備份
echo -e "${CYAN}可用的資料庫備份：${NC}"
echo ""

DB_DIRS=($(ls -d "$BACKUP_BASE"/*/ 2>/dev/null | xargs -n1 basename))

if [[ ${#DB_DIRS[@]} -eq 0 ]]; then
    echo -e "${RED}找不到任何備份！${NC}"
    exit 1
fi

idx=1
for db in "${DB_DIRS[@]}"; do
    # 計算該資料庫的備份數量
    backup_count=$(ls -d "$BACKUP_BASE/$db"/*/ 2>/dev/null | wc -l | tr -d ' ')
    latest=$(ls -d "$BACKUP_BASE/$db"/*/ 2>/dev/null | sort -r | head -1 | xargs basename 2>/dev/null || echo "無")
    echo "  $idx) $db (${backup_count} 個備份, 最新: $latest)"
    ((idx++))
done
echo ""

# 選擇資料庫
read -p "請選擇要還原的資料庫 [1-${#DB_DIRS[@]}]: " DB_CHOICE

if [[ ! "$DB_CHOICE" =~ ^[0-9]+$ ]] || [[ "$DB_CHOICE" -lt 1 ]] || [[ "$DB_CHOICE" -gt ${#DB_DIRS[@]} ]]; then
    echo -e "${RED}無效的選擇！${NC}"
    exit 1
fi

SELECTED_DB="${DB_DIRS[$((DB_CHOICE-1))]}"
DB_BACKUP_DIR="$BACKUP_BASE/$SELECTED_DB"

echo ""
echo -e "${CYAN}資料庫 [$SELECTED_DB] 的可用備份：${NC}"
echo ""

# 列出該資料庫的備份日期
BACKUP_DATES=($(ls -d "$DB_BACKUP_DIR"/*/ 2>/dev/null | xargs -n1 basename | sort -r))

if [[ ${#BACKUP_DATES[@]} -eq 0 ]]; then
    echo -e "${RED}該資料庫沒有可用的備份！${NC}"
    exit 1
fi

idx=1
for date_dir in "${BACKUP_DATES[@]}"; do
    backup_path="$DB_BACKUP_DIR/$date_dir"
    backup_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
    file_count=$(ls "$backup_path"/*.sql* 2>/dev/null | wc -l | tr -d ' ')
    echo "  $idx) $date_dir (大小: $backup_size, 檔案: $file_count)"
    ((idx++))
done
echo ""

# 選擇備份日期
read -p "請選擇要還原的備份 [1-${#BACKUP_DATES[@]}]: " DATE_CHOICE

if [[ ! "$DATE_CHOICE" =~ ^[0-9]+$ ]] || [[ "$DATE_CHOICE" -lt 1 ]] || [[ "$DATE_CHOICE" -gt ${#BACKUP_DATES[@]} ]]; then
    echo -e "${RED}無效的選擇！${NC}"
    exit 1
fi

SELECTED_DATE="${BACKUP_DATES[$((DATE_CHOICE-1))]}"
RESTORE_PATH="$DB_BACKUP_DIR/$SELECTED_DATE"

echo ""
echo "----------------------------------------"
echo -e "${CYAN}還原設定${NC}"
echo "----------------------------------------"
echo ""

# 輸入連線資訊
read -p "MySQL 主機 [localhost]: " INPUT_HOST
DB_HOST="${INPUT_HOST:-localhost}"

read -p "MySQL 端口 [3306]: " INPUT_PORT
DB_PORT="${INPUT_PORT:-3306}"

read -p "MySQL 用戶 [root]: " INPUT_USER
DB_USER="${INPUT_USER:-root}"

read -s -p "MySQL 密碼: " INPUT_PASS
DB_PASS="$INPUT_PASS"
echo ""

# 目標資料庫名稱
read -p "還原到資料庫名稱 [$SELECTED_DB]: " INPUT_TARGET
TARGET_DB="${INPUT_TARGET:-$SELECTED_DB}"

# 是否覆蓋現有資料
echo ""
echo -e "${YELLOW}警告：還原將覆蓋目標資料庫中的現有資料！${NC}"
read -p "是否要先清空目標資料庫？ [y/N]: " OVERWRITE

echo ""
echo "=========================================="
echo -e "${YELLOW}請確認還原資訊${NC}"
echo "=========================================="
echo ""
echo "  來源備份: $RESTORE_PATH"
echo "  目標主機: $DB_HOST:$DB_PORT"
echo "  目標用戶: $DB_USER"
echo "  目標資料庫: $TARGET_DB"
echo "  清空資料庫: $([ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ] && echo "是" || echo "否")"
echo ""

read -p "確定要執行還原嗎？ [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo "已取消還原。"
    exit 0
fi

echo ""
log "INFO" "========== 開始還原 =========="
log "INFO" "來源: $RESTORE_PATH"
log "INFO" "目標: $TARGET_DB@$DB_HOST:$DB_PORT"

# 判斷還原目標是不是這台機器
is_local_target() {
    local h="$1"
    case "$h" in
        localhost|127.0.0.1|::1|"") return 0 ;;
    esac
    [[ "$h" == "$(hostname 2>/dev/null)" || "$h" == "$(hostname -s 2>/dev/null)" ]]
}

# 取得目標主機上某路徑的可用空間 (MB)
# 還原寫入的是「目標主機」的磁碟，所以目標在遠端時一定要連過去問那台。
# 在本機對遠端的路徑跑 df，量到的是本機的空間；兩台若剛好路徑相同（例如都用 homebrew）
# 還會回傳一個看起來很正常的數字，完全看不出量錯對象，比查不到還危險。
get_available_space_mb() {
    local path="$1"
    if is_local_target "$DB_HOST"; then
        df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}'
        return
    fi
    local ssh_target="${RESTORE_SSH_HOST:-$DB_HOST}"
    local ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$ssh_target")
    command -v timeout >/dev/null 2>&1 && ssh_cmd=(timeout 20 "${ssh_cmd[@]}")
    "${ssh_cmd[@]}" "df -m '$path' 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null
}

# 取得備份大小 (MB)
get_backup_size_mb() {
    local path="$1"
    du -sm "$path" 2>/dev/null | cut -f1
}

# MySQL 連線共用參數
MYSQL_CONN=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")
[[ -n "$DB_PASS" ]] && MYSQL_CONN+=(-p"$DB_PASS")

# 指定連接埠會讓用戶端改走 TCP，而本機若是以作業系統帳號認證（homebrew 裝的資料庫預設如此），
# 走 TCP 一定會被擋（ERROR 1698）。這種情況改用 socket 連線，否則後面的空間檢查與清空資料庫都會失敗。
USE_LOCAL_SOCKET=0
if ! mysql "${MYSQL_CONN[@]}" -N -e "SELECT 1" >/dev/null 2>&1; then
    if is_local_target "$DB_HOST"; then
        MYSQL_CONN_SOCKET=(-u "$DB_USER")
        [[ -n "$DB_PASS" ]] && MYSQL_CONN_SOCKET+=(-p"$DB_PASS")
        if mysql "${MYSQL_CONN_SOCKET[@]}" -N -e "SELECT 1" >/dev/null 2>&1; then
            MYSQL_CONN=("${MYSQL_CONN_SOCKET[@]}")
            USE_LOCAL_SOCKET=1
            log "INFO" "本機連線改用 socket（該帳號以作業系統帳號認證，不接受 TCP）"
        fi
    fi
fi

# 取得 MySQL datadir
# 取不到就讓它留空，不要用猜的路徑代替：猜錯會讓後面的空間檢查量到不存在或不相干的位置
MYSQL_DATADIR=$(mysql "${MYSQL_CONN[@]}" -N -e "SELECT @@datadir;" 2>/dev/null)

# 還原前磁碟空間檢查
BACKUP_SIZE_MB=$(get_backup_size_mb "$RESTORE_PATH")
# 還原後實際佔用約為備份大小的 2~3 倍（解壓縮 + 索引建立）
ESTIMATED_NEED_MB=$((BACKUP_SIZE_MB * 3))
AVAILABLE_MB=""
[[ -n "$MYSQL_DATADIR" ]] && AVAILABLE_MB=$(get_available_space_mb "$MYSQL_DATADIR")

if is_local_target "$DB_HOST"; then
    SPACE_TARGET_DESC="本機"
else
    SPACE_TARGET_DESC="${RESTORE_SSH_HOST:-$DB_HOST}"
fi

echo ""
echo -e "${CYAN}磁碟空間檢查：${NC}"
echo "  備份大小: ${BACKUP_SIZE_MB} MB"
echo "  預估需要: ${ESTIMATED_NEED_MB} MB (含解壓縮與索引)"
if [[ -n "$AVAILABLE_MB" ]]; then
    echo "  目前可用: ${AVAILABLE_MB} MB (${SPACE_TARGET_DESC}:${MYSQL_DATADIR})"
else
    echo -e "  ${YELLOW}目前可用: 查不到${NC}"
    if [[ -z "$MYSQL_DATADIR" ]]; then
        echo -e "  ${YELLOW}原因：連不上目標資料庫，或該帳號讀不到 datadir 設定${NC}"
    else
        echo -e "  ${YELLOW}原因：無法以 SSH 連上 ${SPACE_TARGET_DESC} 查詢該主機的磁碟${NC}"
        echo -e "  ${YELLOW}若 SSH 帳號與資料庫主機位址不同，請在 backup.conf 設定 RESTORE_SSH_HOST${NC}"
    fi
    log "WARN" "無法取得目標主機可用空間 (${SPACE_TARGET_DESC}:${MYSQL_DATADIR:-datadir未知})"
fi

# 清空目標資料庫（如果選擇）
if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${CYAN}>>> 清空目標資料庫 (逐表刪除以釋放磁碟空間)...${NC}"
    log "INFO" "清空目標資料庫 $TARGET_DB (逐表刪除模式)"

    # 檢查資料庫是否存在
    DB_EXISTS=$(mysql "${MYSQL_CONN[@]}" -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$TARGET_DB';" 2>/dev/null)

    if [[ -n "$DB_EXISTS" ]]; then
        # 取得所有表格清單（按大小由大到小排序，優先釋放大表空間）
        TABLES=$(mysql "${MYSQL_CONN[@]}" -N -e "
            SELECT TABLE_NAME FROM information_schema.TABLES
            WHERE TABLE_SCHEMA='$TARGET_DB' AND TABLE_TYPE='BASE TABLE'
            ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;" 2>/dev/null)

        TABLE_COUNT=$(echo "$TABLES" | grep -c . 2>/dev/null || echo 0)

        if [[ "$TABLE_COUNT" -gt 0 ]]; then
            echo -e "  找到 ${TABLE_COUNT} 個表格，開始逐表刪除..."
            log "INFO" "找到 $TABLE_COUNT 個表格需要刪除"

            # 先停用外鍵檢查
            mysql "${MYSQL_CONN[@]}" -e "SET GLOBAL foreign_key_checks = 0;" 2>/dev/null

            DROPPED=0
            while IFS= read -r TABLE_NAME; do
                [[ -z "$TABLE_NAME" ]] && continue
                DROPPED=$((DROPPED + 1))
                printf "\r  刪除中: [%d/%d] %s ...          " "$DROPPED" "$TABLE_COUNT" "$TABLE_NAME"

                mysql "${MYSQL_CONN[@]}" "$TARGET_DB" \
                    -e "SET foreign_key_checks = 0; DROP TABLE IF EXISTS \`$TABLE_NAME\`;" 2>>"$LOG_FILE"

                if [[ $? -ne 0 ]]; then
                    echo ""
                    echo -e "${RED}  刪除表格 $TABLE_NAME 失敗！${NC}"
                    log "ERROR" "刪除表格 $TABLE_NAME 失敗"
                fi
            done <<< "$TABLES"

            # 恢復外鍵檢查
            mysql "${MYSQL_CONN[@]}" -e "SET GLOBAL foreign_key_checks = 1;" 2>/dev/null

            echo ""
            log "INFO" "已刪除 $DROPPED 個表格"
        fi

        # 刪除剩餘的 views、routines 等，然後重建資料庫
        mysql "${MYSQL_CONN[@]}" -e "DROP DATABASE IF EXISTS \`$TARGET_DB\`;" 2>>"$LOG_FILE"
    fi

    # 強制檔案系統同步，確保空間已釋放
    sync 2>/dev/null
    sleep 1

    # 重新檢查可用空間
    AVAILABLE_AFTER_DROP_MB=$(get_available_space_mb "$MYSQL_DATADIR")
    FREED_MB=$((AVAILABLE_AFTER_DROP_MB - AVAILABLE_MB))
    echo -e "  ${GREEN}刪除表格釋放: +${FREED_MB} MB (目前可用: ${AVAILABLE_AFTER_DROP_MB} MB)${NC}"
    log "INFO" "刪除表格後可用空間: ${AVAILABLE_AFTER_DROP_MB} MB (釋放: ${FREED_MB} MB)"
    AVAILABLE_MB=$AVAILABLE_AFTER_DROP_MB

    # === 額外空間回收：清除 Binary Logs ===
    echo ""
    echo -e "${CYAN}>>> 檢查可回收的額外空間...${NC}"

    # 檢查 binary log 狀態
    BINLOG_ENABLED=$(mysql "${MYSQL_CONN[@]}" -N -e "SELECT @@log_bin;" 2>/dev/null)
    if [[ "$BINLOG_ENABLED" == "1" ]]; then
        BINLOG_SIZE=$(mysql "${MYSQL_CONN[@]}" -N -e "
            SELECT ROUND(SUM(FILE_SIZE)/1024/1024)
            FROM information_schema.FILES
            WHERE FILE_TYPE='BINARY LOG';" 2>/dev/null 2>&1 || echo "")

        # 如果 information_schema.FILES 不支援，改用 SHOW BINARY LOGS
        if [[ -z "$BINLOG_SIZE" || "$BINLOG_SIZE" == "NULL" ]]; then
            BINLOG_SIZE=$(mysql "${MYSQL_CONN[@]}" -N -e "
                SHOW BINARY LOGS;" 2>/dev/null | awk '{s+=$2} END {printf "%.0f", s/1024/1024}')
        fi

        if [[ -n "$BINLOG_SIZE" && "$BINLOG_SIZE" -gt 0 ]] 2>/dev/null; then
            echo -e "  Binary Logs 佔用: ${YELLOW}${BINLOG_SIZE} MB${NC}"

            if [[ "$AVAILABLE_MB" -lt "$ESTIMATED_NEED_MB" ]]; then
                echo -e "  ${YELLOW}磁碟空間不足，建議清除 Binary Logs 以釋放空間${NC}"
                read -p "  是否清除所有 Binary Logs？ [y/N]: " PURGE_BINLOG
                if [[ "$PURGE_BINLOG" =~ ^[Yy]$ ]]; then
                    mysql "${MYSQL_CONN[@]}" -e "PURGE BINARY LOGS BEFORE NOW();" 2>>"$LOG_FILE"
                    # 有時 RESET MASTER 才能徹底清除
                    mysql "${MYSQL_CONN[@]}" -e "RESET MASTER;" 2>>"$LOG_FILE"
                    sync 2>/dev/null
                    sleep 1
                    AVAILABLE_AFTER_PURGE_MB=$(get_available_space_mb "$MYSQL_DATADIR")
                    PURGE_FREED=$((AVAILABLE_AFTER_PURGE_MB - AVAILABLE_MB))
                    echo -e "  ${GREEN}Binary Logs 清除完成: +${PURGE_FREED} MB (目前可用: ${AVAILABLE_AFTER_PURGE_MB} MB)${NC}"
                    log "INFO" "清除 Binary Logs 釋放: ${PURGE_FREED} MB"
                    AVAILABLE_MB=$AVAILABLE_AFTER_PURGE_MB
                fi
            else
                echo -e "  (空間足夠，跳過清除)"
            fi
        else
            echo "  Binary Logs: 未啟用或無資料"
        fi
    fi

    # 檢查 InnoDB 暫存表空間
    IBTMP_SIZE=$(mysql "${MYSQL_CONN[@]}" -N -e "
        SELECT ROUND(SUM(FILE_SIZE)/1024/1024)
        FROM information_schema.FILES
        WHERE FILE_NAME LIKE '%ibtmp%';" 2>/dev/null || echo "")

    if [[ -n "$IBTMP_SIZE" && "$IBTMP_SIZE" != "NULL" && "$IBTMP_SIZE" -gt 100 ]] 2>/dev/null; then
        echo -e "  InnoDB 暫存表空間: ${YELLOW}${IBTMP_SIZE} MB${NC}"
        echo -e "  ${YELLOW}提示：重啟 MySQL 可重置 ibtmp1 釋放空間${NC}"
        log "INFO" "InnoDB 暫存表空間: ${IBTMP_SIZE} MB"
    fi

    # 檢查 innodb_file_per_table 設定
    FILE_PER_TABLE=$(mysql "${MYSQL_CONN[@]}" -N -e "SELECT @@innodb_file_per_table;" 2>/dev/null)
    if [[ "$FILE_PER_TABLE" == "0" ]]; then
        echo ""
        echo -e "${RED}  警告：innodb_file_per_table = OFF${NC}"
        echo -e "${RED}  共用表空間 (ibdata1) 不會因 DROP TABLE 而縮小！${NC}"
        echo -e "${YELLOW}  解決方案：${NC}"
        echo -e "${YELLOW}    1. 設定 innodb_file_per_table = ON${NC}"
        echo -e "${YELLOW}    2. 重啟 MySQL${NC}"
        echo -e "${YELLOW}    3. 或需要完整匯出 → 停止 MySQL → 刪除 ibdata1 → 重啟 → 匯入${NC}"
        log "WARN" "innodb_file_per_table=OFF，DROP TABLE 不會釋放 ibdata1 空間"
    fi

    # 嘗試清除其他可釋放項目
    # 清除 InnoDB undo logs（MySQL 8.0+）
    mysql "${MYSQL_CONN[@]}" -e "
        SET GLOBAL innodb_undo_log_truncate = ON;
        SET GLOBAL innodb_max_undo_log_size = 10485760;" 2>/dev/null

    # 清除 performance_schema / 暫存表
    mysql "${MYSQL_CONN[@]}" -e "
        RESET QUERY CACHE;
        FLUSH TABLES;
        FLUSH BINARY LOGS;" 2>/dev/null

    sync 2>/dev/null
    sleep 1

    # 最終空間報告
    AVAILABLE_FINAL_MB=$(get_available_space_mb "$MYSQL_DATADIR")
    TOTAL_FREED=$((AVAILABLE_FINAL_MB - ${AVAILABLE_MB:-0}))
    if [[ "$TOTAL_FREED" -gt 0 ]]; then
        echo -e "  ${GREEN}額外清理釋放: +${TOTAL_FREED} MB${NC}"
    fi
    AVAILABLE_MB=$AVAILABLE_FINAL_MB

    echo ""
    if [[ -n "$AVAILABLE_MB" ]]; then
        echo -e "${CYAN}空間回收完成，目前可用: ${GREEN}${AVAILABLE_MB} MB${NC}"
        log "INFO" "空間回收完成，最終可用空間: ${AVAILABLE_MB} MB"
    else
        echo -e "${CYAN}空間回收完成${NC}（${YELLOW}目標主機可用空間仍查不到${NC}）"
        log "INFO" "空間回收完成，但無法取得目標主機可用空間"
    fi

    # 建立新的空資料庫
    mysql "${MYSQL_CONN[@]}" -e "CREATE DATABASE \`$TARGET_DB\`;" 2>&1 | tee -a "$LOG_FILE"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${RED}建立資料庫失敗！${NC}"
        log "ERROR" "建立資料庫 $TARGET_DB 失敗"
        exit 1
    fi

    log "INFO" "資料庫 $TARGET_DB 已重建"
fi

# 最終空間檢查
# 查不到空間時不能當作沒事就放行——先前多次還原跑到一半才因目標主機磁碟滿而失敗，
# 就是因為這個檢查沒量到正確的機器卻照樣往下走
if [[ -z "$AVAILABLE_MB" ]]; then
    echo ""
    echo -e "${YELLOW}無法確認目標主機的可用空間，還原可能中途因磁碟滿而失敗。${NC}"
    echo -e "${YELLOW}此備份還原後預估需要約 ${ESTIMATED_NEED_MB} MB。${NC}"
    read -p "仍然要繼續還原嗎？ [y/N]: " UNKNOWN_SPACE_CONTINUE
    if [[ ! "$UNKNOWN_SPACE_CONTINUE" =~ ^[Yy]$ ]]; then
        echo "已取消還原。"
        log "WARN" "因無法確認目標主機可用空間，使用者取消還原"
        exit 1
    fi
    log "WARN" "無法確認可用空間，使用者選擇繼續"
fi

if [[ -n "$AVAILABLE_MB" && -n "$ESTIMATED_NEED_MB" && "$AVAILABLE_MB" -lt "$ESTIMATED_NEED_MB" ]]; then
    echo ""
    echo -e "${YELLOW}=========================================="
    echo -e "  ⚠ 磁碟空間可能不足！"
    echo -e "  需要: ~${ESTIMATED_NEED_MB} MB / 可用: ${AVAILABLE_MB} MB"
    echo -e "==========================================${NC}"
    echo ""
    echo -e "${YELLOW}建議的額外處理方式：${NC}"
    echo -e "${YELLOW}  1. 刪除不需要的其他資料庫${NC}"
    echo -e "${YELLOW}  2. 清理系統暫存檔 (如 /tmp)${NC}"
    echo -e "${YELLOW}  3. 如 ibdata1 過大：停止 MySQL → 備份 → 刪除 ibdata1 → 重啟${NC}"
    echo -e "${YELLOW}  4. 重啟 MySQL 可重置 ibtmp1 暫存表空間${NC}"
    echo ""
    read -p "仍然要繼續還原嗎？ [y/N]: " FORCE_CONTINUE
    if [[ ! "$FORCE_CONTINUE" =~ ^[Yy]$ ]]; then
        echo "已取消還原。"
        log "WARN" "因磁碟空間不足取消還原 (需要: ${ESTIMATED_NEED_MB} MB, 可用: ${AVAILABLE_MB} MB)"
        exit 1
    fi
    log "WARN" "磁碟空間可能不足，用戶選擇強制繼續 (需要: ${ESTIMATED_NEED_MB} MB, 可用: ${AVAILABLE_MB} MB)"
fi

# 檢查 metadata 檔案格式 (MyLoader 0.21+ 需要 [config] section)
# 注意：新版 mydumper 0.21+ 會自動產生正確格式，無需修復
METADATA_FILE="$RESTORE_PATH/metadata"
if [[ -f "$METADATA_FILE" ]]; then
    if ! grep -q '^\[config\]' "$METADATA_FILE" 2>/dev/null; then
        echo -e "${RED}[警告] metadata 檔案缺少 [config] section${NC}"
        echo -e "${YELLOW}請確認備份端的 mydumper 版本 >= 0.12${NC}"
        echo -e "${YELLOW}建議升級後重新備份：https://github.com/mydumper/mydumper/releases${NC}"
        log "WARN" "metadata 檔案格式不正確，可能導致還原失敗"
    fi
fi

# ============================================
# 續傳狀態檔檢查
# ============================================
# myloader 中途中止（語法錯誤、Ctrl+C、連線斷線）會在備份目錄留下 resume.partial。
# 這個檔案存在時，下一次還原若沒帶 --resume 會被直接拒絕啟動，
# 且錯誤訊息夾在大量 Skipping table 之中很容易被忽略，看起來像「還原秒退但沒說原因」。
RESUME_FILE="$RESTORE_PATH/resume.partial"
if [[ -f "$RESUME_FILE" ]]; then
    echo ""
    echo -e "${YELLOW}偵測到上次還原中斷留下的續傳檔：${NC}"
    echo "  $RESUME_FILE"
    echo -e "${YELLOW}未清除前 myloader 會拒絕啟動。${NC}"
    read -p "  清除續傳檔並重新完整還原? (y/N): " CLEAR_RESUME
    if [[ "$CLEAR_RESUME" =~ ^[Yy]$ ]]; then
        RESUME_BACKUP="${LOG_DIR}/resume.partial.$(date +%Y%m%d%H%M%S)"
        mv "$RESUME_FILE" "$RESUME_BACKUP"
        echo -e "${GREEN}  已清除（原檔移至 $RESUME_BACKUP）${NC}"
        log "INFO" "清除續傳檔: $RESUME_FILE → $RESUME_BACKUP"
    else
        echo -e "${RED}  保留續傳檔，無法繼續還原${NC}"
        log "WARN" "使用者選擇保留續傳檔，取消還原"
        exit 1
    fi
fi

# ============================================
# 索引與約束拆解方式檢查
# ============================================
# myloader 預設會把 CREATE TABLE 裡的索引與約束抽出來，等資料匯入後再用 ALTER TABLE 補上
# （--optimize-keys），大表可省下可觀時間。抽出時它需要把最後一項定義結尾的逗號改成分號，
# 但它是抓整串的最後一個逗號，只要那個逗號離結尾夠近就當成分隔逗號替換掉。
# 當最後一項定義本身以很短的內容收尾，例如 CHECK (`is_active` in (0,1))，
# 被替換掉的會是括號內的逗號，產生 in (0;1)) 這種壞語法，整個還原會以 ERROR 1064 中止。
# 此判斷在 mydumper 上游最新版仍是如此，升級無法迴避，只能改走 SKIP 這條不拆解的路徑。
#
# OPTIMIZE_KEYS 可在 backup.conf 設定：
#   auto（預設）= 掃描備份，只有真的踩到才降級為 SKIP，其餘維持加速
#   SKIP / AFTER_IMPORT_PER_TABLE / AFTER_IMPORT_ALL_TABLES = 直接指定，不做掃描

# 讀取 schema 檔內容（依副檔名選解壓方式）
read_schema_file() {
    case "$1" in
        *.zst) zstd -dc "$1" 2>/dev/null ;;
        *.gz)  gzip -dc "$1" 2>/dev/null ;;
        *)     cat "$1" 2>/dev/null ;;
    esac
}

# 判斷抽出的索引段或約束段，其最後一行會不會被 myloader 改壞
# 以逗號結尾者代表後面還有別的定義，該逗號本來就該被替換掉，不會出事；
# 不以逗號結尾者是 CREATE TABLE 的最後一項，myloader 會誤抓行內最後一個逗號。
# 門檻 4 來自上游的判斷式 (逗號位置 > 字串長度 - 5)，換算後即「逗號之後不足 4 個字元」，
# 例如 in (0,1)) 逗號後只剩 1)) 三個字元會出事，而 (`a`,`b`) 逗號後有四個字元則安全。
segment_hits_bug() {
    local last="$1"
    [[ -z "$last" ]] && return 1
    [[ "$last" == *, ]] && return 1
    [[ "$last" != *,* ]] && return 1
    local after="${last##*,}"
    [[ ${#after} -lt 4 ]]
}

OPTIMIZE_KEYS="${OPTIMIZE_KEYS:-auto}"
OPTIMIZE_KEYS_MODE=""
RISKY_TABLES=()

if [[ "$OPTIMIZE_KEYS" == "auto" ]]; then
    echo ""
    echo -e "${CYAN}>>> 檢查備份中的索引與約束定義...${NC}"
    shopt -s nullglob
    for SCHEMA_FILE in "$RESTORE_PATH"/*-schema.sql*; do
        SCHEMA_CONTENT=$(read_schema_file "$SCHEMA_FILE")
        [[ -z "$SCHEMA_CONTENT" ]] && continue
        IDX_LAST=$(printf '%s\n' "$SCHEMA_CONTENT" | grep -E "^  (KEY|UNIQUE|SPATIAL|FULLTEXT|INDEX)" | tail -1)
        CON_LAST=$(printf '%s\n' "$SCHEMA_CONTENT" | grep -E "^  CONSTRAINT" | tail -1)
        if segment_hits_bug "$IDX_LAST" || segment_hits_bug "$CON_LAST"; then
            RISKY_TABLE=$(basename "$SCHEMA_FILE")
            RISKY_TABLES+=("${RISKY_TABLE%%-schema*}")
        fi
    done
    shopt -u nullglob

    if [[ ${#RISKY_TABLES[@]} -gt 0 ]]; then
        OPTIMIZE_KEYS_MODE="SKIP"
        echo -e "${YELLOW}  發現 ${#RISKY_TABLES[@]} 個資料表的定義會讓 myloader 拆解出錯：${NC}"
        for RISKY_TABLE in "${RISKY_TABLES[@]}"; do
            echo "    - $RISKY_TABLE"
        done
        echo -e "${YELLOW}  已自動關閉索引後建優化（--optimize-keys SKIP）以避開此問題。${NC}"
        echo -e "${YELLOW}  代價：大表還原會變慢（實測約多 4 成時間），但資料與索引結果完全相同。${NC}"
        log "WARN" "偵測到 ${#RISKY_TABLES[@]} 個表會觸發 myloader 拆解錯誤，改用 --optimize-keys SKIP: ${RISKY_TABLES[*]}"
    else
        echo -e "${GREEN}  未發現問題，維持索引後建優化${NC}"
        log "INFO" "索引與約束定義檢查通過，維持預設 --optimize-keys"
    fi
else
    OPTIMIZE_KEYS_MODE="$OPTIMIZE_KEYS"
    log "INFO" "依設定使用 --optimize-keys $OPTIMIZE_KEYS_MODE"
fi

# 注意：myloader 會自行處理 SQL mode，使用 --ignore-errors 忽略資料截斷問題
log "INFO" "使用 myloader --ignore-errors 處理資料截斷問題"

# 建構 myloader 命令
CMD="$MYLOADER_BIN"
if [[ "$USE_LOCAL_SOCKET" -eq 1 ]]; then
    # 與上面同一個原因：本機帳號以作業系統帳號認證時只能走 socket
    MYSQL_SOCKET_PATH=$(mysql "${MYSQL_CONN[@]}" -N -e "SELECT @@socket" 2>/dev/null)
    CMD+=" --socket $MYSQL_SOCKET_PATH"
else
    CMD+=" -h $DB_HOST"
    CMD+=" -P $DB_PORT"
fi
CMD+=" -u $DB_USER"
[[ -n "$DB_PASS" ]] && CMD+=" -p '$DB_PASS'"
CMD+=" -B $TARGET_DB"
CMD+=" -d $RESTORE_PATH"
CMD+=" -o"  # 覆蓋表
CMD+=" -v 3"  # 詳細輸出
CMD+=" --ignore-errors 1265,1406"  # 忽略資料截斷錯誤 (1265=Data truncated, 1406=Data too long)
CMD+=" --quote-character BACKTICK"  # 明確指定引號字元，避免依賴 metadata
[[ -n "$OPTIMIZE_KEYS_MODE" ]] && CMD+=" --optimize-keys $OPTIMIZE_KEYS_MODE"

# 執行緒數（磁碟空間不足時自動降低，減少暫存檔使用）
THREADS="${THREADS:-0}"
if [[ "$THREADS" -eq 0 ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    else
        CPU_CORES=$(nproc 2>/dev/null || echo 4)
    fi
    THREADS=$((CPU_CORES > 2 ? CPU_CORES - 2 : 1))
fi

# 磁碟空間吃緊時自動降低執行緒數
LOW_DISK_MODE=0
if [[ -n "$AVAILABLE_MB" && -n "$ESTIMATED_NEED_MB" ]]; then
    # 可用空間不到預估需求的 1.5 倍，視為吃緊
    THRESHOLD=$((ESTIMATED_NEED_MB * 3 / 2))
    if [[ "$AVAILABLE_MB" -lt "$THRESHOLD" ]]; then
        LOW_DISK_MODE=1
        OLD_THREADS=$THREADS
        # 空間越緊，執行緒越少（最低 2）
        if [[ "$AVAILABLE_MB" -lt "$ESTIMATED_NEED_MB" ]]; then
            THREADS=2
        elif [[ "$THREADS" -gt 4 ]]; then
            THREADS=4
        fi
        if [[ "$THREADS" -ne "$OLD_THREADS" ]]; then
            echo -e "${YELLOW}磁碟空間吃緊，自動降低執行緒: $OLD_THREADS → $THREADS (減少暫存檔使用)${NC}"
            log "WARN" "磁碟空間吃緊，降低執行緒數: $OLD_THREADS → $THREADS"
        fi
    fi
fi

CMD+=" -t $THREADS"

log "INFO" "使用執行緒: $THREADS"
log "INFO" "執行還原..."

echo ""
echo -e "${CYAN}>>> 正在還原...${NC}"
echo ""

# 執行還原（優化輸出顯示）
START_TIME=$(date +%s)

# 過濾函數：顯示各階段進度
filter_output() {
    local last_percent=0
    local phase="init"        # init → schema → data → index
    local tables_created=0
    local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spinner_idx=0
    local line_count=0

    while IFS= read -r line; do
        # 完整日誌寫入文件
        echo "$line" >> "$LOG_FILE"
        line_count=$((line_count + 1))

        # 旋轉指示器字元
        local spin_char="${spinner_chars:$((spinner_idx % ${#spinner_chars})):1}"
        spinner_idx=$((spinner_idx + 1))

        # 階段：建立表格結構
        if [[ "$line" =~ "Creating table" ]] || [[ "$line" =~ "Table.*created" ]]; then
            tables_created=$((tables_created + 1))
            phase="schema"
            printf "\r  ${CYAN}${spin_char} 建立表格結構: %d 個表格已建立${NC}          " "$tables_created"
            continue
        fi

        # 階段：還原資料（進度百分比）
        if [[ "$line" =~ Progress\ ([0-9]+)\ of\ ([0-9]+).*Tables\ ([0-9]+)\ of\ ([0-9]+) ]]; then
            phase="data"
            progress="${BASH_REMATCH[1]}"
            total="${BASH_REMATCH[2]}"
            tables="${BASH_REMATCH[3]}"
            total_tables="${BASH_REMATCH[4]}"
            percent=$((progress * 100 / total))

            # 每 2% 或完成時更新顯示
            if [[ $((percent - last_percent)) -ge 2 ]] || [[ "$progress" == "$total" ]]; then
                # 進度條
                local bar_width=30
                local filled=$((percent * bar_width / 100))
                local empty=$((bar_width - filled))
                local bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
                local bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '░')

                local elapsed=$(( $(date +%s) - START_TIME ))
                local elapsed_str="${elapsed}s"
                if [[ $elapsed -ge 60 ]]; then
                    elapsed_str="$((elapsed/60))m$((elapsed%60))s"
                fi

                printf "\r  ${CYAN}${bar}${bar_empty} %3d%% | %d/%d 檔案 | 表格: %d/%d | %s${NC}  " \
                    "$percent" "$progress" "$total" "$tables" "$total_tables" "$elapsed_str"
                last_percent=$percent
            fi
            continue
        fi

        # 階段：建立索引
        if [[ "$line" =~ "restoring index:" ]] || [[ "$line" =~ "Creating index" ]]; then
            if [[ "$phase" != "index" ]]; then
                phase="index"
                echo ""
            fi
            printf "\r  ${CYAN}${spin_char} 建立索引中...${NC}          "
            continue
        fi

        # 顯示錯誤和警告（過濾已知的無害警告）
        if [[ "$line" =~ ERROR|CRITICAL ]]; then
            # 過濾已知的無害訊息
            if [[ "$line" =~ "group_replication_transaction_size_limit" ]]; then
                continue
            elif [[ "$line" =~ "g_key_file_get_groups" ]]; then
                continue
            fi
            echo ""
            echo -e "${RED}  $line${NC}"
            continue
        fi

        # 初始階段：顯示活動指示器（讓用戶知道沒有卡住）
        if [[ "$phase" == "init" ]]; then
            printf "\r  ${CYAN}${spin_char} 初始化中... (已處理 %d 行輸出)${NC}          " "$line_count"
        fi
    done
    echo ""  # 換行
}

eval "$CMD" 2>&1 | filter_output
EXIT_CODE=${PIPESTATUS[0]}
END_TIME=$(date +%s)

ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    log "INFO" "還原完成! 耗時: ${ELAPSED_MIN}分${ELAPSED_SEC}秒"
    echo "=========================================="
    echo -e "  ${GREEN}還原成功！${NC}"
    echo "=========================================="
    echo "  耗時: ${ELAPSED_MIN}分${ELAPSED_SEC}秒"
    echo "  目標: $TARGET_DB@$DB_HOST:$DB_PORT"
    echo "=========================================="
else
    log "ERROR" "還原失敗! (exit code: $EXIT_CODE)"
    echo "=========================================="
    echo -e "  ${RED}還原失敗！${NC}"
    echo "=========================================="

    # 檢查是否為磁碟空間問題
    FINAL_AVAILABLE_MB=$(get_available_space_mb "$MYSQL_DATADIR")
    if [[ -n "$FINAL_AVAILABLE_MB" && "$FINAL_AVAILABLE_MB" -lt 100 ]]; then
        echo ""
        echo -e "${RED}  原因：磁碟空間不足 (剩餘: ${FINAL_AVAILABLE_MB} MB)${NC}"
        echo ""
        echo -e "${YELLOW}  建議處理步驟：${NC}"
        echo -e "${YELLOW}  1. 檢查磁碟使用: df -h${NC}"
        echo -e "${YELLOW}  2. 檢查 MySQL 資料目錄: du -sh ${MYSQL_DATADIR}*${NC}"
        echo -e "${YELLOW}  3. 檢查 ibdata1 大小: ls -lh ${MYSQL_DATADIR}ibdata1${NC}"
        echo -e "${YELLOW}  4. 清除 Binary Logs: mysql -e 'RESET MASTER;'${NC}"
        echo -e "${YELLOW}  5. 重啟 MySQL 可重置 ibtmp1 暫存表空間${NC}"
        echo -e "${YELLOW}  6. 如 innodb_file_per_table=OFF 需完整重建 InnoDB${NC}"
        log "ERROR" "磁碟空間不足導致還原失敗 (剩餘: ${FINAL_AVAILABLE_MB} MB)"
    fi

    echo ""
    echo "  請檢查日誌: $LOG_FILE"
    echo "=========================================="
    exit 1
fi

echo ""
log "INFO" "========== 還原結束 =========="
