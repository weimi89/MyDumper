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

# 清空目標資料庫（如果選擇）
if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}>>> 清空目標資料庫...${NC}"
    log "INFO" "清空目標資料庫 $TARGET_DB"

    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS \`$TARGET_DB\`; CREATE DATABASE \`$TARGET_DB\`;" 2>&1 | tee -a "$LOG_FILE"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${RED}清空資料庫失敗！${NC}"
        log "ERROR" "清空資料庫失敗"
        exit 1
    fi
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

# 注意：myloader 會自行處理 SQL mode，使用 --ignore-errors 忽略資料截斷問題
log "INFO" "使用 myloader --ignore-errors 處理資料截斷問題"

# 建構 myloader 命令
CMD="$MYLOADER_BIN"
CMD+=" -h $DB_HOST"
CMD+=" -P $DB_PORT"
CMD+=" -u $DB_USER"
[[ -n "$DB_PASS" ]] && CMD+=" -p '$DB_PASS'"
CMD+=" -B $TARGET_DB"
CMD+=" -d $RESTORE_PATH"
CMD+=" -o"  # 覆蓋表
CMD+=" -v 3"  # 詳細輸出
CMD+=" --ignore-errors 1265,1406"  # 忽略資料截斷錯誤 (1265=Data truncated, 1406=Data too long)
CMD+=" --quote-character BACKTICK"  # 明確指定引號字元，避免依賴 metadata

# 執行緒數
THREADS="${THREADS:-0}"
if [[ "$THREADS" -eq 0 ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    else
        CPU_CORES=$(nproc 2>/dev/null || echo 4)
    fi
    THREADS=$((CPU_CORES > 2 ? CPU_CORES - 2 : 1))
fi
CMD+=" -t $THREADS"

log "INFO" "使用執行緒: $THREADS"
log "INFO" "執行還原..."

echo ""
echo -e "${CYAN}>>> 正在還原 (執行中，請稍候...)${NC}"
echo ""

# 執行還原（優化輸出顯示）
START_TIME=$(date +%s)

# 過濾函數：只顯示關鍵進度
filter_output() {
    local last_progress=""
    local last_percent=0
    while IFS= read -r line; do
        # 完整日誌寫入文件
        echo "$line" >> "$LOG_FILE"

        # 提取進度資訊
        if [[ "$line" =~ Progress\ ([0-9]+)\ of\ ([0-9]+).*Tables\ ([0-9]+)\ of\ ([0-9]+) ]]; then
            progress="${BASH_REMATCH[1]}"
            total="${BASH_REMATCH[2]}"
            tables="${BASH_REMATCH[3]}"
            total_tables="${BASH_REMATCH[4]}"
            percent=$((progress * 100 / total))

            # 每 5% 或完成時更新顯示
            if [[ $((percent - last_percent)) -ge 5 ]] || [[ "$progress" == "$total" ]]; then
                printf "\r${CYAN}  [%3d%%] 進度: %d/%d 檔案 | 表格: %d/%d 完成${NC}    " \
                    "$percent" "$progress" "$total" "$tables" "$total_tables"
                last_percent=$percent
            fi
        # 顯示錯誤和警告（過濾已知的無害警告）
        elif [[ "$line" =~ ERROR|CRITICAL ]]; then
            # 過濾已知的無害訊息
            if [[ "$line" =~ "group_replication_transaction_size_limit" ]]; then
                : # 忽略：目標 MySQL 不支援 Group Replication
            elif [[ "$line" =~ "g_key_file_get_groups" ]]; then
                : # 忽略：mydumper.cnf 配置文件不存在
            else
                echo ""
                echo -e "${RED}  $line${NC}"
            fi
        # 顯示重要訊息
        elif [[ "$line" =~ "restoring index:" ]]; then
            : # 跳過索引訊息
        elif [[ "$line" =~ "Table.*created" ]]; then
            : # 跳過表格建立訊息
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
    echo "  請檢查日誌: $LOG_FILE"
    echo "=========================================="
    exit 1
fi

echo ""
log "INFO" "========== 還原結束 =========="
