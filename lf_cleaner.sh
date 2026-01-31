#!/bin/bash

# ============================================================================
# LF CLEANER v2.0 
# ============================================================================

# Строгий режим
set -o pipefail

# Конфигурация (можно вынести в отдельный файл)
readonly CONFIG_FILE="/etc/lf_cleaner.conf"
readonly LOG_FILE="/var/log/lf_cleaner.log"
readonly VERSION="2.0"

# Пороговые значения по умолчанию (в МБ)
SYSLOG_THRESHOLD=100
AUTH_THRESHOLD=50
BTMP_THRESHOLD=10
JOURNAL_SIZE="200M"
ARCHIVE_AGE_DAYS=30

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Флаги
DRY_RUN=false
VERBOSE=false

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

log_action() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    if [[ "$VERBOSE" == true ]]; then
        case "$level" in
            INFO)    echo -e "${GREEN}[INFO]${NC} $message" ;;
            WARN)    echo -e "${YELLOW}[WARN]${NC} $message" ;;
            ERROR)   echo -e "${RED}[ERROR]${NC} $message" ;;
            ACTION)  echo -e "${CYAN}[ACTION]${NC} $message" ;;
        esac
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ОШИБКА: Скрипт должен запускаться от root!    ║${NC}"
        echo -e "${RED}║  Используйте: sudo $0                      ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    local optional_missing=()
    
    # Обязательные
    for cmd in truncate find du df journalctl logrotate; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Опциональные
    for cmd in ncdu watch; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Отсутствуют обязательные утилиты: ${missing[*]}${NC}"
        exit 1
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Рекомендуется установить: ${optional_missing[*]}${NC}"
        echo -e "${YELLOW}Установка: sudo apt install ${optional_missing[*]}${NC}"
        sleep 2
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_action "INFO" "Загружена конфигурация из $CONFIG_FILE"
    fi
}

# Безопасное получение размера файла в МБ
get_file_size_mb() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size
        size=$(du -m "$file" 2>/dev/null | cut -f1)
        if [[ "$size" =~ ^[0-9]+$ ]]; then
            echo "$size"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Безопасная очистка файла
safe_truncate() {
    local file="$1"
    local description="$2"
    
    if [[ ! -f "$file" ]]; then
        log_action "WARN" "Файл не существует: $file"
        return 1
    fi
    
    local size_before=$(get_file_size_mb "$file")
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY-RUN]${NC} Будет очищен: $file (${size_before}MB)"
        return 0
    fi
    
    if truncate -s 0 "$file" 2>/dev/null; then
        log_action "ACTION" "Очищен $file (было ${size_before}MB) - $description"
        echo -e "${GREEN}✓${NC} Очищен: $file (${size_before}MB)"
        return 0
    else
        log_action "ERROR" "Не удалось очистить $file"
        echo -e "${RED}✗${NC} Ошибка очистки: $file"
        return 1
    fi
}

# Безопасное удаление файла
safe_remove() {
    local file="$1"
    local description="$2"
    
    if [[ ! -e "$file" ]]; then
        return 1
    fi
    
    local size_before=$(get_file_size_mb "$file")
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY-RUN]${NC} Будет удалён: $file (${size_before}MB)"
        return 0
    fi
    
    if rm -f "$file" 2>/dev/null; then
        log_action "ACTION" "Удалён $file (${size_before}MB) - $description"
        echo -e "${GREEN}✓${NC} Удалён: $file (${size_before}MB)"
        return 0
    else
        log_action "ERROR" "Не удалось удалить $file"
        return 1
    fi
}

# Форматированный вывод размера с цветом
format_size_colored() {
    local size_mb="$1"
    local warn_threshold="${2:-100}"
    local crit_threshold="${3:-500}"
    
    if [[ "$size_mb" -ge "$crit_threshold" ]]; then
        echo -e "${RED}${size_mb}MB${NC}"
    elif [[ "$size_mb" -ge "$warn_threshold" ]]; then
        echo -e "${YELLOW}${size_mb}MB${NC}"
    else
        echo -e "${GREEN}${size_mb}MB${NC}"
    fi
}

# Проверка, существует ли строка в файле
line_exists_in_file() {
    local line="$1"
    local file="$2"
    grep -qF "$line" "$file" 2>/dev/null
}

# ============================================================================
# ОСНОВНЫЕ ФУНКЦИИ
# ============================================================================

show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      ЛОГ МЕНЕДЖЕР v${VERSION} - Ubuntu Server 24.04 LTS      ║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  1. 📊 Выявить проблему (кто занимает место)           ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  2. 🔍 Детальный анализ логов                          ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  3. 🧹 Очистить систему от больших логов               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  4. ⚙️  Настроить защиту от переполнения                ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  5. 📈 Показать статистику использования               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  6. 🛡️  Быстрая полная очистка                         ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  7. 📋 Проверить настройки logrotate                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  8. 📝 Мониторинг в реальном времени                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  9. 🔧 Настройки скрипта                               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 10. ❓ Помощь и информация                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  0. 🔴 Выход                                           ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    
    # Быстрая статистика внизу
    local log_size=$(du -sh /var/log 2>/dev/null | cut -f1)
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    echo -e "\n${CYAN}Быстрая статистика:${NC} Логи: ${log_size} | Диск: ${disk_usage}"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[РЕЖИМ DRY-RUN АКТИВЕН]${NC}"
    fi
    
    echo ""
    read -p "Выберите пункт меню (0-10): " choice
}

analyze_problem() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               ВЫЯВЛЕНИЕ ПРОБЛЕМЫ                ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    log_action "INFO" "Запущен анализ проблем"
    
    echo -e "\n${GREEN}► Дисковое пространство:${NC}"
    df -h / /var 2>/dev/null | column -t
    
    # Проверка критического состояния
    local usage=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
    if [[ "$usage" -ge 90 ]]; then
        echo -e "${RED}⚠️  КРИТИЧНО: Диск заполнен на ${usage}%!${NC}"
    elif [[ "$usage" -ge 80 ]]; then
        echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Диск заполнен на ${usage}%${NC}"
    fi
    
    echo -e "\n${GREEN}► TOP 15 директорий по размеру:${NC}"
    du -hx --max-depth=1 / 2>/dev/null | sort -rh | head -16 | while read size dir; do
        printf "%-10s %s\n" "$size" "$dir"
    done
    
    echo -e "\n${GREEN}► Логи по размеру (с индикацией):${NC}"
    printf "%-12s %-50s %s\n" "РАЗМЕР" "ФАЙЛ" "СТАТУС"
    echo "────────────────────────────────────────────────────────────────────"
    
    while IFS=$'\t' read -r size path; do
        local size_mb=$(echo "$size" | sed 's/[^0-9]//g')
        local status=""
        
        # Определяем статус
        if [[ "$size" == *G* ]] || [[ "$size_mb" -ge 500 ]]; then
            status="${RED}[КРИТИЧНО]${NC}"
        elif [[ "$size_mb" -ge 100 ]]; then
            status="${YELLOW}[ВНИМАНИЕ]${NC}"
        else
            status="${GREEN}[OK]${NC}"
        fi
        
        printf "%-12s %-50s %b\n" "$size" "$path" "$status"
    done < <(du -sh /var/log/* 2>/dev/null | sort -rh | head -20)
    
    echo -e "\n${GREEN}► TOP 10 самых больших файлов:${NC}"
    find /var/log -type f -exec du -h {} + 2>/dev/null | sort -rh | head -10
    
    echo -e "\n${GREEN}► Файлы больше 100МБ:${NC}"
    local large_files=$(find /var/log -type f -size +100M 2>/dev/null)
    if [[ -n "$large_files" ]]; then
        find /var/log -type f -size +100M -exec ls -lh {} \; 2>/dev/null
    else
        echo "Файлов больше 100МБ не найдено"
    fi
    
    echo -e "\n${GREEN}► Размер журнала systemd:${NC}"
    journalctl --disk-usage
    
    echo -e "\n${GREEN}► Открытые удалённые файлы (занимают место):${NC}"
    local deleted=$(lsof 2>/dev/null | grep deleted | grep '/var/log' | head -5)
    if [[ -n "$deleted" ]]; then
        echo "$deleted"
        echo -e "${YELLOW}Совет: Перезапустите соответствующие сервисы для освобождения места${NC}"
    else
        echo "Открытых удалённых файлов не найдено"
    fi
    
    read -p "Нажмите Enter для продолжения..."
}

detailed_analysis() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               ДЕТАЛЬНЫЙ АНАЛИЗ                  ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    log_action "INFO" "Запущен детальный анализ"
    
    if command -v ncdu &>/dev/null; then
        echo -e "\n${GREEN}► Анализ /var/log с ncdu:${NC}"
        echo "Запуск ncdu (выход - клавиша q)..."
        ncdu /var/log --exclude /var/log/journal -q
    else
        echo -e "\n${YELLOW}ncdu не установлен. Альтернативный анализ:${NC}"
        du -ah /var/log 2>/dev/null | sort -rh | head -30
    fi
    
    echo -e "\n${GREEN}► Статус последней ротации:${NC}"
    if [[ -f /var/lib/logrotate/status ]]; then
        echo "Последние 20 записей:"
        tail -20 /var/lib/logrotate/status
    else
        echo "Файл статуса не найден"
    fi
    
    echo -e "\n${GREEN}► Текущие логи и их возраст:${NC}"
    printf "%-40s %-12s %-20s\n" "ФАЙЛ" "РАЗМЕР" "ПОСЛЕДНЕЕ ИЗМЕНЕНИЕ"
    echo "────────────────────────────────────────────────────────────────────────"
    
    for log in /var/log/*.log /var/log/syslog /var/log/auth.log; do
        if [[ -f "$log" ]]; then
            local size=$(du -h "$log" 2>/dev/null | cut -f1)
            local mtime=$(stat -c '%y' "$log" 2>/dev/null | cut -d'.' -f1)
            printf "%-40s %-12s %-20s\n" "$(basename "$log")" "$size" "$mtime"
        fi
    done
    
    echo -e "\n${GREEN}► Проверка прав доступа:${NC}"
    ls -la /var/log/ | grep -E "syslog|auth.log|btmp|kern.log"
    
    echo -e "\n${GREEN}► Сервисы, активно пишущие в логи:${NC}"
    lsof /var/log/* 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10
    
    read -p "Нажмите Enter для продолжения..."
}

clean_system() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               ОЧИСТКА СИСТЕМЫ                  ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    # Показываем что будет очищено
    echo -e "\n${GREEN}► Предварительный анализ:${NC}"
    
    local total_to_clean=0
    
    # Проверяем syslog
    local syslog_size=$(get_file_size_mb "/var/log/syslog")
    if [[ "$syslog_size" -gt "$SYSLOG_THRESHOLD" ]]; then
        echo -e "  syslog: ${RED}${syslog_size}MB${NC} (порог: ${SYSLOG_THRESHOLD}MB) - будет очищен"
        ((total_to_clean += syslog_size))
    else
        echo -e "  syslog: ${GREEN}${syslog_size}MB${NC} (в норме)"
    fi
    
    # Проверяем auth.log
    local auth_size=$(get_file_size_mb "/var/log/auth.log")
    if [[ "$auth_size" -gt "$AUTH_THRESHOLD" ]]; then
        echo -e "  auth.log: ${RED}${auth_size}MB${NC} (порог: ${AUTH_THRESHOLD}MB) - будет очищен"
        ((total_to_clean += auth_size))
    else
        echo -e "  auth.log: ${GREEN}${auth_size}MB${NC} (в норме)"
    fi
    
    # Проверяем .log.1 файлы
    echo -e "\n  Большие несжатые архивы (.log.1):"
    for log in /var/log/*.log.1; do
        if [[ -f "$log" ]]; then
            local size=$(get_file_size_mb "$log")
            if [[ "$size" -gt 10 ]]; then
                echo -e "    $(basename "$log"): ${YELLOW}${size}MB${NC} - будет удалён"
                ((total_to_clean += size))
            fi
        fi
    done
    
    # Старые архивы
    local old_archives=$(find /var/log -name "*.gz" -mtime +${ARCHIVE_AGE_DAYS} 2>/dev/null | wc -l)
    echo -e "\n  Старых архивов (>${ARCHIVE_AGE_DAYS} дней): $old_archives"
    
    # Journal
    echo -e "\n  Журнал systemd:"
    journalctl --disk-usage
    
    echo -e "\n${BOLD}Ожидаемое освобождение: ~${total_to_clean}MB${NC}"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\n${CYAN}[DRY-RUN] Реальная очистка не будет выполнена${NC}"
    fi
    
    echo -e "\n${RED}ВНИМАНИЕ! Эта операция очистит указанные логи.${NC}"
    read -p "Продолжить? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Отмена операции."
        log_action "INFO" "Очистка отменена пользователем"
        return
    fi
    
    log_action "INFO" "Начата очистка системы"
    
    echo -e "\n${GREEN}► Выполнение очистки:${NC}"
    
    # Очистка syslog
    if [[ "$syslog_size" -gt "$SYSLOG_THRESHOLD" ]]; then
        safe_truncate "/var/log/syslog" "превышен порог ${SYSLOG_THRESHOLD}MB"
    fi
    
    # Очистка auth.log
    if [[ "$auth_size" -gt "$AUTH_THRESHOLD" ]]; then
        safe_truncate "/var/log/auth.log" "превышен порог ${AUTH_THRESHOLD}MB"
    fi
    
    # Удаление больших .log.1 файлов
    for log in /var/log/*.log.1; do
        if [[ -f "$log" ]]; then
            local size=$(get_file_size_mb "$log")
            if [[ "$size" -gt 10 ]]; then
                safe_remove "$log" "большой несжатый архив"
            fi
        fi
    done
    
    # Очистка btmp
    local btmp_size=$(get_file_size_mb "/var/log/btmp")
    if [[ "$btmp_size" -gt "$BTMP_THRESHOLD" ]]; then
        safe_truncate "/var/log/btmp" "превышен порог ${BTMP_THRESHOLD}MB"
    fi
    
    # Очистка journal
    if [[ "$DRY_RUN" != true ]]; then
        echo -e "\n${GREEN}► Очистка journal (лимит: ${JOURNAL_SIZE}):${NC}"
        journalctl --vacuum-size=${JOURNAL_SIZE}
        log_action "ACTION" "Journal очищен до ${JOURNAL_SIZE}"
    fi
    
    # Удаление старых архивов
    if [[ "$DRY_RUN" != true ]]; then
        echo -e "\n${GREEN}► Удаление архивов старше ${ARCHIVE_AGE_DAYS} дней:${NC}"
        local deleted_count=$(find /var/log -name "*.gz" -mtime +${ARCHIVE_AGE_DAYS} -delete -print 2>/dev/null | wc -l)
        echo "Удалено архивов: $deleted_count"
        log_action "ACTION" "Удалено $deleted_count старых архивов"
    fi
    
    # Очистка apt кэша
    if [[ "$DRY_RUN" != true ]]; then
        echo -e "\n${GREEN}► Очистка apt кэша:${NC}"
        apt clean
    fi
    
    echo -e "\n${GREEN}► Итоговое состояние:${NC}"
    df -h /
    echo ""
    du -sh /var/log/
    
    log_action "INFO" "Очистка системы завершена"
    
    read -p "Нажмите Enter для продолжения..."
}

configure_protection() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}          НАСТРОЙКА ЗАЩИТЫ ОТ ПЕРЕПОЛНЕНИЯ       ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    log_action "INFO" "Запущена настройка защиты"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY-RUN] Конфигурации не будут изменены${NC}\n"
    fi
    
    # 1. Настройка logrotate для rsyslog
    echo -e "\n${GREEN}► Настройка logrotate для rsyslog:${NC}"
    
    local rsyslog_config="/etc/logrotate.d/rsyslog"
    local backup_file="${rsyslog_config}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f "$rsyslog_config" ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            cp "$rsyslog_config" "$backup_file"
            echo "Создана резервная копия: $backup_file"
            log_action "ACTION" "Создана резервная копия: $backup_file"
        else
            echo "[DRY-RUN] Будет создана резервная копия: $backup_file"
        fi
    fi
    
    # Создаём новый конфиг
    local new_rsyslog_config='/var/log/syslog
/var/log/mail.info
/var/log/mail.warn
/var/log/mail.err
/var/log/mail.log
/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/lpr.log
/var/log/cron.log
/var/log/debug
/var/log/messages
{
        su root syslog
        rotate 7
        daily
        missingok
        notifempty
        compress
        delaycompress
        sharedscripts
        maxsize 100M
        postrotate
                /usr/lib/rsyslog/rsyslog-rotate
        endscript
}'
    
    if [[ "$DRY_RUN" != true ]]; then
        echo "$new_rsyslog_config" > "$rsyslog_config"
        echo -e "${GREEN}✓${NC} Конфигурация rsyslog обновлена"
    else
        echo "[DRY-RUN] Будет обновлена конфигурация rsyslog"
    fi
    
    # 2. Настройка btmp
    echo -e "\n${GREEN}► Настройка logrotate для btmp:${NC}"
    
    local btmp_config='/var/log/btmp
{
    missingok
    monthly
    create 0600 root utmp
    rotate 1
    size 10M
}'
    
    if [[ "$DRY_RUN" != true ]]; then
        echo "$btmp_config" > /etc/logrotate.d/btmp
        echo -e "${GREEN}✓${NC} Конфигурация btmp создана"
    fi
    
    # 3. Настройка journald (с проверкой дубликатов)
    echo -e "\n${GREEN}► Настройка journald:${NC}"
    
    local journald_conf="/etc/systemd/journald.conf"
    local journald_changes_needed=false
    
    # Проверяем, нужны ли изменения
    if ! grep -q "^SystemMaxUse=" "$journald_conf" 2>/dev/null; then
        journald_changes_needed=true
    fi
    
    if [[ "$journald_changes_needed" == true ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            # Создаём резервную копию
            cp "$journald_conf" "${journald_conf}.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Добавляем настройки, если их нет
            {
                echo ""
                echo "# Added by log manager script $(date +%Y-%m-%d)"
                grep -q "^SystemMaxUse=" "$journald_conf" || echo "SystemMaxUse=100M"
                grep -q "^RuntimeMaxUse=" "$journald_conf" || echo "RuntimeMaxUse=50M"
                grep -q "^MaxRetentionSec=" "$journald_conf" || echo "MaxRetentionSec=7day"
                grep -q "^MaxFileSec=" "$journald_conf" || echo "MaxFileSec=1month"
            } >> "$journald_conf"
            
            echo -e "${GREEN}✓${NC} Настройки journald добавлены"
            log_action "ACTION" "Настройки journald обновлены"
        else
            echo "[DRY-RUN] Будут добавлены настройки journald"
        fi
    else
        echo "Настройки journald уже сконфигурированы"
    fi
    
    # 4. Создание общего правила для логов
    echo -e "\n${GREEN}► Создание общего правила для логов:${NC}"
    
    local custom_config='/var/log/*.log {
    missingok
    notifempty
    compress
    delaycompress
    rotate 5
    daily
    maxsize 50M
    su root syslog
    create 0640 root syslog
}'
    
    if [[ "$DRY_RUN" != true ]]; then
        echo "$custom_config" > /etc/logrotate.d/custom
        echo -e "${GREEN}✓${NC} Общее правило создано"
    fi
    
    # 5. Создание скрипта мониторинга
    echo -e "\n${GREEN}► Создание скрипта мониторинга:${NC}"
    
    local monitor_script='#!/bin/bash
LOG_DIR="/var/log"
THRESHOLD_MB=100
OUTPUT_FILE="/var/log/log_monitor.log"

echo "=== Log Monitor $(date) ===" >> "$OUTPUT_FILE"
echo "Total log size: $(du -sh $LOG_DIR | cut -f1)" >> "$OUTPUT_FILE"

for log in $(find $LOG_DIR -name "*.log" -type f 2>/dev/null); do
    size=$(du -m "$log" 2>/dev/null | cut -f1)
    if [[ "$size" =~ ^[0-9]+$ ]] && [[ "$size" -gt $THRESHOLD_MB ]]; then
        echo "WARNING: $log - ${size}MB" >> "$OUTPUT_FILE"
    fi
done

journalctl --disk-usage >> "$OUTPUT_FILE" 2>&1
echo "" >> "$OUTPUT_FILE"
'
    
    if [[ "$DRY_RUN" != true ]]; then
        echo "$monitor_script" > /usr/local/bin/log_monitor.sh
        chmod +x /usr/local/bin/log_monitor.sh
        echo -e "${GREEN}✓${NC} Скрипт мониторинга создан: /usr/local/bin/log_monitor.sh"
    fi
    
    # 6. Настройка cron (с проверкой дубликатов)
    echo -e "\n${GREEN}► Настройка cron задач:${NC}"
    
    local cron_logrotate="0 3 * * * /usr/sbin/logrotate -f /etc/logrotate.conf"
    local cron_monitor="0 4 * * 0 /usr/local/bin/log_monitor.sh"
    
    if [[ "$DRY_RUN" != true ]]; then
        local current_cron=$(crontab -l 2>/dev/null || echo "")
        local new_cron="$current_cron"
        local added=0
        
        if ! echo "$current_cron" | grep -qF "logrotate -f"; then
            new_cron="${new_cron}
${cron_logrotate}"
            ((added++))
        fi
        
        if ! echo "$current_cron" | grep -qF "log_monitor.sh"; then
            new_cron="${new_cron}
${cron_monitor}"
            ((added++))
        fi
        
        if [[ "$added" -gt 0 ]]; then
            echo "$new_cron" | crontab -
            echo -e "${GREEN}✓${NC} Добавлено $added cron задач"
            log_action "ACTION" "Добавлено $added cron задач"
        else
            echo "Cron задачи уже настроены"
        fi
    else
        echo "[DRY-RUN] Будут добавлены cron задачи"
    fi
    
    # 7. Применение настроек
    if [[ "$DRY_RUN" != true ]]; then
        echo -e "\n${GREEN}► Применение настроек:${NC}"
        systemctl restart systemd-journald 2>/dev/null && echo -e "${GREEN}✓${NC} journald перезапущен"
        
        echo "Тестирование logrotate..."
        if logrotate -d /etc/logrotate.d/rsyslog 2>&1 | grep -q "error"; then
            echo -e "${RED}✗${NC} Обнаружены ошибки в конфигурации logrotate"
        else
            echo -e "${GREEN}✓${NC} Конфигурация logrotate корректна"
        fi
    fi
    
    echo -e "\n${GREEN}✅ Защита настроена!${NC}"
    log_action "INFO" "Настройка защиты завершена"
    
    read -p "Нажмите Enter для продолжения..."
}

show_stats() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               СТАТИСТИКА ИСПОЛЬЗОВАНИЯ          ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}► Системная информация:${NC}"
    echo "Дата: $(date)"
    echo "Хост: $(hostname)"
    echo "Uptime: $(uptime -p)"
    
    echo -e "\n${GREEN}► Использование диска:${NC}"
    df -h --output=source,size,used,avail,pcent / /var 2>/dev/null | column -t
    
    # Визуальный индикатор
    local usage=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
    local bar_length=30
    local filled=$((usage * bar_length / 100))
    local empty=$((bar_length - filled))
    
    local color="$GREEN"
    [[ "$usage" -ge 80 ]] && color="$YELLOW"
    [[ "$usage" -ge 90 ]] && color="$RED"
    
    printf "\n[%s%s] %s%%\n" \
        "$(printf '%*s' "$filled" | tr ' ' '█')" \
        "$(printf '%*s' "$empty" | tr ' ' '░')" \
        "$usage"
    
    echo -e "\n${GREEN}► Размер директории логов:${NC}"
    du -sh /var/log/ 2>/dev/null
    
    echo -e "\n${GREEN}► TOP 5 логов по размеру:${NC}"
    du -sh /var/log/* 2>/dev/null | sort -rh | head -5
    
    echo -e "\n${GREEN}► Статус журнала systemd:${NC}"
    journalctl --disk-usage
    
    echo -e "\n${GREEN}► Ротированные файлы:${NC}"
    ls -la /var/log/syslog* /var/log/auth.log* 2>/dev/null | head -10
    
    echo -e "\n${GREEN}► Активные cron задачи для логов:${NC}"
    crontab -l 2>/dev/null | grep -E "logrotate|monitor" || echo "Нет настроенных задач"
    
    echo -e "\n${GREEN}► История действий скрипта (последние 10):${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -10 "$LOG_FILE"
    else
        echo "Файл журнала не найден"
    fi
    
    read -p "Нажмите Enter для продолжения..."
}

quick_clean() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               БЫСТРАЯ ПОЛНАЯ ОЧИСТКА            ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}► Текущее состояние:${NC}"
    df -h / | tail -1
    echo "Логи: $(du -sh /var/log 2>/dev/null | cut -f1)"
    
    echo -e "\n${RED}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  ВНИМАНИЕ! Будут очищены ВСЕ логи!          ║${NC}"
    echo -e "${RED}║  Это может затруднить диагностику проблем.     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\n${CYAN}[DRY-RUN] Реальная очистка не будет выполнена${NC}"
    fi
    
    read -p "Вы уверены? Введите 'YES' для подтверждения: " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        echo "Отмена операции."
        log_action "INFO" "Быстрая очистка отменена пользователем"
        return
    fi
    
    log_action "WARN" "Запущена быстрая полная очистка"
    
    echo -e "\n${GREEN}► Выполнение очистки...${NC}"
    
    local freed=0
    
    # 1. Очистка основных логов
    echo "1. Очистка основных логов..."
    for log in /var/log/syslog /var/log/auth.log /var/log/btmp /var/log/kern.log \
               /var/log/daemon.log /var/log/messages /var/log/debug; do
        if [[ -f "$log" ]]; then
            local size=$(get_file_size_mb "$log")
            safe_truncate "$log" "быстрая очистка"
            ((freed += size))
        fi
    done
    
    # 2. Удаление .log.1 файлов
    echo "2. Удаление несжатых архивов..."
    if [[ "$DRY_RUN" != true ]]; then
        find /var/log -name "*.log.1" -delete 2>/dev/null
    fi
    
    # 3. Очистка journal
    echo "3. Очистка journal..."
    if [[ "$DRY_RUN" != true ]]; then
        journalctl --vacuum-time=1d 2>/dev/null
    fi
    
    # 4. Удаление всех архивов
    echo "4. Удаление архивов..."
    if [[ "$DRY_RUN" != true ]]; then
        find /var/log -name "*.gz" -delete 2>/dev/null
        find /var/log -name "*.xz" -delete 2>/dev/null
        find /var/log -name "*.[0-9]" -delete 2>/dev/null
    fi
    
    # 5. Очистка временных файлов
    echo "5. Очистка временных файлов..."
    if [[ "$DRY_RUN" != true ]]; then
        rm -rf /tmp/* /var/tmp/* 2>/dev/null
    fi
    
    # 6. Очистка apt кэша
    echo "6. Очистка apt кэша..."
    if [[ "$DRY_RUN" != true ]]; then
        apt clean 2>/dev/null
        apt autoclean 2>/dev/null
    fi
    
    # 7. Запуск logrotate
    echo "7. Запуск logrotate..."
    if [[ "$DRY_RUN" != true ]]; then
        logrotate -f /etc/logrotate.conf 2>/dev/null
    fi
    
    echo -e "\n${GREEN}► Итоговый результат:${NC}"
    df -h / | tail -1
    echo "Логи: $(du -sh /var/log 2>/dev/null | cut -f1)"
    
    log_action "INFO" "Быстрая очистка завершена"
    
    echo -e "\n${GREEN}✅ Очистка завершена!${NC}"
    read -p "Нажмите Enter для продолжения..."
}

check_logrotate() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               ПРОВЕРКА LOGROTATE                ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}► Конфигурационные файлы:${NC}"
    ls -la /etc/logrotate.d/
    
    echo -e "\n${GREEN}► Содержимое rsyslog конфига:${NC}"
    if [[ -f /etc/logrotate.d/rsyslog ]]; then
        cat /etc/logrotate.d/rsyslog
    else
        echo -e "${RED}Файл не найден!${NC}"
    fi
    
    echo -e "\n${GREEN}► Статус последней ротации:${NC}"
    if [[ -f /var/lib/logrotate/status ]]; then
        head -30 /var/lib/logrotate/status
    else
        echo "Файл статуса не найден"
    fi
    
    echo -e "\n${GREEN}► Тестирование конфигурации (debug mode):${NC}"
    logrotate -d /etc/logrotate.d/rsyslog 2>&1 | tail -30
    
    echo -e "\n${GREEN}► Проверка синтаксиса всех конфигов:${NC}"
    local errors=0
    for conf in /etc/logrotate.d/*; do
        if logrotate -d "$conf" 2>&1 | grep -qi "error"; then
            echo -e "${RED}✗${NC} $conf - ошибки!"
            ((errors++))
        else
            echo -e "${GREEN}✓${NC} $conf - OK"
        fi
    done
    
    if [[ "$errors" -gt 0 ]]; then
        echo -e "\n${RED}Обнаружено ошибок: $errors${NC}"
    else
        echo -e "\n${GREEN}Все конфигурации корректны${NC}"
    fi
    
    echo -e "\n${GREEN}► Права на файлы логов:${NC}"
    ls -la /var/log/ | grep -E "\.log$|syslog|auth.log|btmp"
    
    read -p "Нажмите Enter для продолжения..."
}

realtime_monitor() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               МОНИТОРИНГ                        ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}Выберите тип мониторинга:${NC}"
    echo "1. Мониторинг syslog в реальном времени"
    echo "2. Мониторинг auth.log в реальном времени"
    echo "3. Мониторинг всех логов (journalctl)"
    echo "4. Мониторинг размера логов"
    echo "5. Просмотр последних ошибок"
    echo "6. Мониторинг SSH подключений"
    echo "0. Назад"
    
    read -p "Выберите (0-6): " monitor_choice
    
    case $monitor_choice in
        1)
            echo -e "\n${GREEN}► Мониторинг syslog (Ctrl+C для выхода):${NC}"
            tail -f /var/log/syslog
            ;;
        2)
            echo -e "\n${GREEN}► Мониторинг auth.log (Ctrl+C для выхода):${NC}"
            tail -f /var/log/auth.log
            ;;
        3)
            echo -e "\n${GREEN}► Мониторинг journalctl (Ctrl+C для выхода):${NC}"
            journalctl -f
            ;;
        4)
            if command -v watch &>/dev/null; then
                echo -e "\n${GREEN}► Мониторинг размера (Ctrl+C для выхода):${NC}"
                watch -n 5 "echo '=== Диск ===' && df -h / && echo '' && echo '=== TOP логи ===' && du -sh /var/log/* 2>/dev/null | sort -rh | head -10"
            else
                echo "Утилита watch не установлена"
                read -p "Нажмите Enter..."
            fi
            ;;
        5)
            echo -e "\n${GREEN}► Последние ошибки:${NC}"
            echo "--- syslog ---"
            grep -i "error\|fail\|critical" /var/log/syslog 2>/dev/null | tail -15
            echo ""
            echo "--- journalctl ---"
            journalctl -p err -n 15 --no-pager
            read -p "Нажмите Enter для продолжения..."
            ;;
        6)
            echo -e "\n${GREEN}► SSH подключения (Ctrl+C для выхода):${NC}"
            tail -f /var/log/auth.log | grep --line-buffered -E "sshd|ssh"
            ;;
    esac
}

script_settings() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               НАСТРОЙКИ СКРИПТА                 ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}Текущие настройки:${NC}"
    echo "  Порог syslog: ${SYSLOG_THRESHOLD}MB"
    echo "  Порог auth.log: ${AUTH_THRESHOLD}MB"
    echo "  Порог btmp: ${BTMP_THRESHOLD}MB"
    echo "  Лимит journal: ${JOURNAL_SIZE}"
    echo "  Возраст архивов: ${ARCHIVE_AGE_DAYS} дней"
    echo "  DRY-RUN режим: $DRY_RUN"
    echo "  Verbose режим: $VERBOSE"
    
    echo -e "\n${GREEN}Действия:${NC}"
    echo "1. Изменить пороговые значения"
    echo "2. Переключить DRY-RUN режим"
    echo "3. Переключить Verbose режим"
    echo "4. Сохранить настройки в файл"
    echo "5. Просмотреть лог действий"
    echo "0. Назад"
    
    read -p "Выберите (0-5): " settings_choice
    
    case $settings_choice in
        1)
            read -p "Порог syslog (MB) [$SYSLOG_THRESHOLD]: " new_val
            [[ -n "$new_val" ]] && SYSLOG_THRESHOLD=$new_val
            
            read -p "Порог auth.log (MB) [$AUTH_THRESHOLD]: " new_val
            [[ -n "$new_val" ]] && AUTH_THRESHOLD=$new_val
            
            read -p "Лимит journal [$JOURNAL_SIZE]: " new_val
            [[ -n "$new_val" ]] && JOURNAL_SIZE=$new_val
            
            echo -e "${GREEN}Настройки обновлены${NC}"
            ;;
        2)
            if [[ "$DRY_RUN" == true ]]; then
                DRY_RUN=false
                echo -e "${GREEN}DRY-RUN режим ВЫКЛЮЧЕН${NC}"
            else
                DRY_RUN=true
                echo -e "${YELLOW}DRY-RUN режим ВКЛЮЧЕН${NC}"
            fi
            ;;
        3)
            if [[ "$VERBOSE" == true ]]; then
                VERBOSE=false
                echo "Verbose режим ВЫКЛЮЧЕН"
            else
                VERBOSE=true
                echo "Verbose режим ВКЛЮЧЕН"
            fi
            ;;
        4)
            cat > "$CONFIG_FILE" << EOF
# Log Manager Configuration
SYSLOG_THRESHOLD=$SYSLOG_THRESHOLD
AUTH_THRESHOLD=$AUTH_THRESHOLD
BTMP_THRESHOLD=$BTMP_THRESHOLD
JOURNAL_SIZE=$JOURNAL_SIZE
ARCHIVE_AGE_DAYS=$ARCHIVE_AGE_DAYS
EOF
            echo -e "${GREEN}Настройки сохранены в $CONFIG_FILE${NC}"
            ;;
        5)
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                echo "Файл журнала не найден"
            fi
            ;;
    esac
    
    read -p "Нажмите Enter для продолжения..."
}

show_help() {
    echo -e "\n${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               ПОМОЩЬ И ИНФОРМАЦИЯ               ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}📌 Описание пунктов меню:${NC}"
    cat << 'EOF'
 1. Выявить проблему   - анализ диска и поиск больших логов
 2. Детальный анализ   - подробная информация с ncdu
 3. Очистить систему   - безопасная очистка больших логов
 4. Настроить защиту   - автоматизация через logrotate
 5. Статистика         - текущее состояние системы
 6. Быстрая очистка    - полная очистка всех логов (осторожно!)
 7. Проверить logrotate- просмотр и проверка настроек
 8. Мониторинг         - просмотр логов в реальном времени
 9. Настройки          - конфигурация скрипта
10. Помощь             - эта информация
EOF
    
    echo -e "\n${GREEN}🔧 Рекомендации:${NC}"
    echo "• Регулярно используйте пункт 1 для профилактики"
    echo "• Настройте защиту (пункт 4) один раз"
    echo "• Используйте DRY-RUN режим для предварительного просмотра"
    echo "• Быструю очистку - только в экстренных случаях"
    
    echo -e "\n${GREEN}📂 Важные файлы:${NC}"
    echo "/etc/logrotate.d/rsyslog     - настройки ротации"
    echo "/etc/systemd/journald.conf   - настройки journal"
    echo "/var/lib/logrotate/status    - статус ротации"
    echo "$LOG_FILE                    - журнал этого скрипта"
    echo "$CONFIG_FILE                 - конфигурация скрипта"
    
    echo -e "\n${GREEN}⚡ Быстрые команды:${NC}"
    echo "du -sh /var/log/*            - размер логов"
    echo "journalctl --disk-usage      - размер журнала"
    echo "tail -f /var/log/syslog      - мониторинг"
    echo "logrotate -vf /etc/logrotate.conf - принудительная ротация"
    
    echo -e "\n${GREEN}🚀 Параметры запуска:${NC}"
    echo "$0 --dry-run    - режим без реальных изменений"
    echo "$0 --verbose    - подробный вывод"
    echo "$0 --help       - эта справка"
    
    read -p "Нажмите Enter для продолжения..."
}

# ============================================================================
# ТОЧКА ВХОДА
# ============================================================================

# Обработка параметров командной строки
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

# Проверки
check_root
check_dependencies
load_config

# Создаём файл журнала если не существует
touch "$LOG_FILE" 2>/dev/null || true
log_action "INFO" "Скрипт запущен"

# Главный цикл
while true; do
    show_menu
    
    case $choice in
        1)  analyze_problem ;;
        2)  detailed_analysis ;;
        3)  clean_system ;;
        4)  configure_protection ;;
        5)  show_stats ;;
        6)  quick_clean ;;
        7)  check_logrotate ;;
        8)  realtime_monitor ;;
        9)  script_settings ;;
        10) show_help ;;
        0)
            echo -e "\n${GREEN}Выход из программы.${NC}"
            log_action "INFO" "Скрипт завершён"
            exit 0
            ;;
        *)
            echo -e "\n${RED}Неверный выбор!${NC}"
            sleep 1
            ;;
    esac
done
