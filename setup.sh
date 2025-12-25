#!/bin/bash
# ============================================
# MyDumper 備份排程安裝腳本
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP_SCRIPT="${SCRIPT_DIR}/dump.sh"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

echo "=========================================="
echo "MyDumper 每日備份排程設定"
echo "=========================================="
echo ""

# 檢查設定檔
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] 找不到設定檔: $CONFIG_FILE"
    exit 1
fi

# 設定執行權限
chmod +x "$DUMP_SCRIPT"
echo "[OK] 已設定腳本執行權限"

# 讀取現有設定
source "$CONFIG_FILE"

# 檢查必要設定
if [[ "$BACKUP_DIR" == "/path/to/backups" ]]; then
    echo ""
    echo "[注意] 請先編輯設定檔 backup.conf"
    echo "  - 設定 BACKUP_DIR (備份目錄)"
    echo ""
    echo "編輯完成後，再次執行此腳本。"
    exit 1
fi

# 建立備份目錄
mkdir -p "$BACKUP_DIR"
mkdir -p "${BACKUP_DIR}/logs"
echo "[OK] 已建立備份目錄: $BACKUP_DIR"

# 詢問排程時間
echo ""
echo "請選擇每日備份執行時間："
echo "  1) 凌晨 02:00 (建議)"
echo "  2) 凌晨 03:00"
echo "  3) 凌晨 04:00"
echo "  4) 自訂時間"
echo ""
read -p "請輸入選項 [1-4]: " CHOICE

case $CHOICE in
    1) CRON_HOUR=2; CRON_MIN=0 ;;
    2) CRON_HOUR=3; CRON_MIN=0 ;;
    3) CRON_HOUR=4; CRON_MIN=0 ;;
    4)
        read -p "請輸入小時 (0-23): " CRON_HOUR
        read -p "請輸入分鐘 (0-59): " CRON_MIN
        ;;
    *) CRON_HOUR=2; CRON_MIN=0 ;;
esac

# 日誌目錄
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

# 生成 crontab 項目
CRON_ENTRY="$CRON_MIN $CRON_HOUR * * * $DUMP_SCRIPT >> ${LOG_DIR}/cron.log 2>&1"

echo ""
echo "=========================================="
echo "排程設定資訊"
echo "=========================================="
echo "執行時間: 每天 ${CRON_HOUR}:$(printf '%02d' $CRON_MIN)"
echo "備份腳本: $DUMP_SCRIPT"
echo "備份目錄: $BACKUP_DIR"
echo ""
echo "Crontab 項目:"
echo "$CRON_ENTRY"
echo ""

# 顯示設定指引（不自動寫入，避免影響 Hestia/cPanel 等控制面板）
echo "=========================================="
echo "請依照您的環境選擇設定方式："
echo "=========================================="
echo ""
echo "【方式 A】Hestia Control Panel"
echo "  1. 登入 Hestia 後台"
echo "  2. 進入 Cron Jobs → Add Cron Job"
echo "  3. 填入以下設定："
echo "     分鐘: $CRON_MIN"
echo "     小時: $CRON_HOUR"
echo "     日: *"
echo "     月: *"
echo "     週: *"
echo "     命令: $DUMP_SCRIPT >> ${LOG_DIR}/cron.log 2>&1"
echo ""
echo "【方式 B】手動編輯 crontab"
echo "  執行: crontab -e"
echo "  加入: $CRON_ENTRY"
echo ""
echo "【方式 C】直接執行命令新增"
echo "  (crontab -l 2>/dev/null; echo '$CRON_ENTRY') | crontab -"

echo ""
echo "=========================================="
echo "使用說明"
echo "=========================================="
echo "1. 手動執行備份: $DUMP_SCRIPT"
echo "2. 查看排程: crontab -l"
echo "3. 查看日誌: cat ${LOG_DIR}/dump_\$(date +%Y%m%d).log"
echo "4. 移除排程: crontab -e (刪除對應行)"
echo ""
