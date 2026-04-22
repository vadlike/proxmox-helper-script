#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="0.1.0"
LOG_FILE="/var/log/proxmox-disk-mount-helper.log"
STATE_DIR="/var/lib/proxmox-disk-mount-helper"
HOST_STATE_FILE="${STATE_DIR}/host-mounts.state"
LXC_STATE_FILE="${STATE_DIR}/lxc-binds.state"
DISK_EDITOR_STATE_FILE="${STATE_DIR}/disk-editor.state"
AUTHOR_REFERENCE_URL="https://github.com/vadlike/proxmox-intel-vgpu-installer"
AUTHOR_NAME="vadlike"

DRY_RUN=0
FORCE_YES=0
PERSIST_MODE=""
COMMAND=""
HOST_FS_TYPE=""

DEVICE=""
UUID_VALUE=""
MOUNT_PATH=""
CTID=""
HOST_PATH=""
CONTAINER_PATH=""
MP_SLOT=""
CHMOD_VALUE="777"
CHOWN_VALUE=""
REMOVE_EMPTY_DIR=0
MENU_BACK_TOKEN="__back__"
DISK_EDITOR_SELECTED_TARGET=""

readonly EXIT_USAGE=2
readonly EXIT_NOT_ROOT=10
readonly EXIT_NOT_PROXMOX=11
readonly EXIT_DEPENDENCY=12
readonly EXIT_VALIDATION=13
readonly EXIT_CANCELLED=14

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  menu            Interactive wizard menu (default when no command is provided)
  host-mount      Mount an existing disk on the Proxmox host
  lxc-attach      Bind a host path into an LXC container with pct set
  disk-editor     CLI GParted-style disk editor using native Proxmox tools
  mirror-folder   Built-in mirror folder helper (single-file mode)
  status          Show current managed mounts and LXC bind mappings
  remove-mount    Remove a managed or other non-system host mount
  remove-lxc      Remove a managed LXC bind mount (user-friendly alias)
  rollback-host   Unmount and remove a managed host mount
  rollback-lxc    Remove a managed LXC bind mount
  help            Show this help

Options:
  --dry-run             Print actions without changing the system
  --yes                 Skip interactive confirmation where possible
  --device <PATH>       Source block device, e.g. /dev/sdb1
  --uuid <UUID>         Source disk UUID (used internally for persistent host mounts)
  --mount-path <PATH>   Host mountpoint path
  --persist             Persist host mount into /etc/fstab
  --ctid <ID>           LXC container ID
  --host-path <PATH>    Existing or new host path for LXC bind mount
  --container-path <P>  Target path inside container
  --mp-slot <mpX>       LXC bind slot, e.g. mp0 or mp1
  --chmod <MODE>        Chmod to apply to a newly created host path (default: 777)
  --chown <USER:GROUP>  Optional ownership to apply to a newly created host path
  --remove-empty-dir    Remove empty host directory during rollback-lxc
  -h, --help            Show this help

Disk editor note:
  This helper provides a CLI GParted-style workflow using native Proxmox/Linux
  tools. It does not launch the real GUI gparted application.

Credits:
  Author: ${AUTHOR_NAME}
  Repository: ${AUTHOR_REFERENCE_URL}
EOF
}

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_raw() {
  local level="$1"
  shift
  local msg="$*"
  local line

  line="[$(timestamp)] [$level] $msg"
  echo "$line"
  if [[ $DRY_RUN -eq 1 ]]; then
    return
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$line" >>"$LOG_FILE"
}

info() { log_raw "INFO" "$*"; }
warn() { log_raw "WARN" "$*"; }
error() { log_raw "ERROR" "$*"; }

is_menu_back() {
  [[ "${1:-}" == "$MENU_BACK_TOKEN" ]]
}

die() {
  local code="$1"
  shift
  error "$*"
  exit "$code"
}

run_cmd() {
  local cmd="$*"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: $cmd"
    return 0
  fi
  info "RUN: $cmd"
  eval "$cmd"
}

trim_spaces() {
  printf '%s' "$1" | awk '{$1=$1; print}'
}

normalize_path() {
  local raw="$1"
  raw="$(trim_spaces "$raw")"
  [[ -n "$raw" ]] || die "$EXIT_USAGE" "Path value cannot be empty."
  if [[ "$raw" != "/" ]]; then
    raw="${raw%/}"
  fi
  printf '%s' "$raw"
}

normalize_mp_slot() {
  local raw="$1"
  if [[ "$raw" =~ ^mp[0-9]+$ ]]; then
    printf '%s' "$raw"
    return
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf 'mp%s' "$raw"
    return
  fi
  die "$EXIT_USAGE" "Invalid mp slot: '$raw' (expected mp0, mp1, or a bare number)."
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "$EXIT_NOT_ROOT" "This command must run as root."
  fi
}

is_proxmox() {
  [[ -f /etc/pve/.version ]] || command -v pveversion >/dev/null 2>&1
}

require_proxmox() {
  if ! is_proxmox; then
    die "$EXIT_NOT_PROXMOX" "This helper only supports Proxmox VE hosts."
  fi
}

require_commands() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Missing required command: $cmd"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit "$EXIT_DEPENDENCY"
}

ensure_state_dir() {
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: mkdir -p '$STATE_DIR'"
    return
  fi
  mkdir -p "$STATE_DIR"
  touch "$HOST_STATE_FILE" "$LXC_STATE_FILE" "$DISK_EDITOR_STATE_FILE"
}

backup_file() {
  local target="$1"
  local stamp backup

  [[ -f "$target" ]] || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${target}.bak-${stamp}"
  run_cmd "cp -a '$target' '$backup'"
}

state_append_unique() {
  local file="$1"
  local line="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: append state '$line' -> $file"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -Fqx "$line" "$file" 2>/dev/null; then
    echo "$line" >>"$file"
  fi
}

state_remove_line() {
  local file="$1"
  local line="$2"
  local tmp

  if [[ ! -f "$file" ]]; then
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: remove state '$line' from $file"
    return 0
  fi

  tmp="$(mktemp)"
  grep -Fvx "$line" "$file" >"$tmp" || true
  mv "$tmp" "$file"
}

use_whiptail_ui() {
  [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1
}

whiptail_input() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local value=""

  value="$(whiptail --title "$title" --inputbox "$prompt" 12 80 "$default_value" 3>&1 1>&2 2>&3)" || die "$EXIT_CANCELLED" "Operation cancelled."
  printf '%s' "$value"
}

whiptail_yes_no() {
  local title="$1"
  local prompt="$2"
  local default_answer="${3:-y}"
  local rc

  if [[ "$default_answer" == "n" ]]; then
    whiptail --title "$title" --defaultno --yesno "$prompt" 10 80
  else
    whiptail --title "$title" --yesno "$prompt" 10 80
  fi
  rc=$?

  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
  esac
}

whiptail_menu_select() {
  local title="$1"
  local prompt="$2"
  local value=""
  local rc=0
  shift 2

  value="$(whiptail --title "$title" --menu "$prompt" 22 100 12 "$@" 3>&1 1>&2 2>&3)" || rc=$?
  case "$rc" in
    0) printf '%s' "$value" ;;
    1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
    *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
  esac
}

whiptail_show_text() {
  local title="$1"
  local content="$2"
  local tmp

  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"
  whiptail --title "$title" --scrolltext --textbox "$tmp" 28 110 || true
  rm -f "$tmp"
}

list_directories_raw() {
  local root="$1"
  local maxdepth="${2:-1}"

  if [[ ! -d "$root" ]]; then
    return 0
  fi

  find "$root" -mindepth 1 -maxdepth "$maxdepth" -type d 2>/dev/null | sort || true
}

list_pve_host_directories_raw() {
  local maxdepth="${1:-1}"
  list_directories_raw "/mnt" "$maxdepth"
}

list_pve_host_directories() {
  local maxdepth="${1:-1}"
  local dirs=""

  dirs="$(list_pve_host_directories_raw "$maxdepth")"
  if [[ ! -d "/mnt" ]]; then
    printf 'Current folders under /mnt:\n/mnt is not available on this host.\n'
    return 0
  fi

  if [[ -z "$dirs" ]]; then
    printf 'Current folders under /mnt:\n(no directories found)\n'
    return 0
  fi

  printf 'Current folders under /mnt:\n%s\n' "$dirs"
}

show_pve_host_directories_hint() {
  local maxdepth="${1:-1}"
  local content=""

  content="$(list_pve_host_directories "$maxdepth")"
  if use_whiptail_ui; then
    whiptail_show_text "Host folders under /mnt" "$content"
  else
    printf '\n%s\n\n' "$content" >&2
  fi
}

prompt_pve_host_directory_selection() {
  local maxdepth="${1:-1}"
  local options=()
  local path desc

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    desc="Use this existing host directory"
    options+=("$path" "$desc")
  done < <(list_pve_host_directories_raw "$maxdepth")

  options+=("manual-entry" "Type a full host path manually")
  whiptail_menu_select "LXC Attach" "Select full host path from /mnt (-maxdepth ${maxdepth}) or choose manual-entry" "${options[@]}"
}

prompt_host_path_mode_selection() {
  if use_whiptail_ui; then
    whiptail_menu_select "LXC Attach" "Choose host path selection mode" \
      "browse" "Browse folders like a file manager (recommended)" \
      "manual-entry" "Type a full host path manually"
    return 0
  fi

  prompt_text "Choose host path mode (browse/manual-entry)" "browse"
}

prompt_browse_host_directory_selection() {
  local current="/mnt"
  local options=()
  local child=""
  local child_name=""
  local choice=""

  if [[ ! -d "$current" ]]; then
    current="/"
  fi

  while true; do
    options=("__select__" "Select this folder: $current")
    if [[ "$current" != "/" ]]; then
      options+=("__up__" "Go up one directory")
    fi
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      child_name="$(basename "$child")"
      options+=("$child" "Open folder: $child_name")
    done < <(find "$current" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true)
    options+=("manual-entry" "Type a full host path manually")

    choice="$(whiptail_menu_select "LXC Attach" "Browse host folders\nCurrent: $current" "${options[@]}")"
    case "$choice" in
      "$MENU_BACK_TOKEN")
        printf '%s' "$MENU_BACK_TOKEN"
        return 0
        ;;
      "__select__")
        printf '%s' "$current"
        return 0
        ;;
      "__up__")
        current="$(dirname "$current")"
        [[ -n "$current" ]] || current="/"
        ;;
      "manual-entry")
        printf '%s' "manual-entry"
        return 0
        ;;
      *)
        current="$choice"
        ;;
    esac
  done
}

device_parent_disk() {
  local path="$1"
  local type="$2"
  local pkname="$3"

  if [[ "$type" == "disk" ]]; then
    printf '%s' "$path"
    return
  fi
  if [[ -n "$pkname" && "$pkname" != "-" ]]; then
    printf '/dev/%s' "$pkname"
    return
  fi
  lsblk -ndo PKNAME "$path" 2>/dev/null | head -n1 | awk '{ if ($1 != "") print "/dev/" $1 }'
}

device_type_label() {
  local path="$1"
  local type="$2"
  local parent_disk="$3"
  local tran rota

  if [[ "$type" == "part" ]]; then
    printf '%s' "partition"
    return
  fi

  tran="$(lsblk -ndo TRAN "$path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  rota="$(lsblk -ndo ROTA "$path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  case "$tran" in
    nvme) printf '%s' "nvme" ;;
    usb) printf '%s' "USB" ;;
    sata|ata)
      if [[ "$rota" == "0" ]]; then
        printf '%s' "SSD"
      else
        printf '%s' "HDD"
      fi
      ;;
    *)
      if [[ "$rota" == "0" ]]; then
        printf '%s' "SSD"
      elif [[ "$rota" == "1" ]]; then
        printf '%s' "HDD"
      elif [[ "$type" == "disk" ]]; then
        printf '%s' "disk"
      else
        printf '%s' "${type:-unknown}"
      fi
      ;;
  esac
}

device_usage_label() {
  local type="$1"
  local fstype="$2"
  local mountpoint="$3"
  local parttype="$4"

  if [[ "$type" == "disk" ]]; then
    printf '%s' "partitions"
    return
  fi
  if [[ "$mountpoint" == "[SWAP]" || "$fstype" == "swap" ]]; then
    printf '%s' "swap"
    return
  fi

  case "${parttype,,}" in
    c12a7328-f81f-11d2-ba4b-00a0c93ec93b) printf '%s' "EFI" ; return ;;
    21686148-6449-6e6f-744e-656564454649) printf '%s' "BIOS boot" ; return ;;
    e6d6d379-f507-44c2-a23c-238f2a3df928) printf '%s' "LVM" ; return ;;
  esac

  case "$fstype" in
    LVM2_member) printf '%s' "LVM" ;;
    vfat) printf '%s' "EFI" ;;
    ""|-) printf '%s' "No" ;;
    *) printf '%s' "$fstype" ;;
  esac
}

device_gpt_label() {
  local disk="$1"
  local pttype=""

  pttype="$(lsblk -ndo PTTYPE "$disk" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  if [[ "${pttype,,}" == "gpt" ]]; then
    printf '%s' "Yes"
  else
    printf '%s' "No"
  fi
}

device_model_label() {
  local disk="$1"
  local model=""

  model="$(lsblk -ndo MODEL "$disk" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  [[ -n "$model" ]] || model="--"
  printf '%s' "$model"
}

device_model_for_path() {
  local path="$1"
  local type pkname parent_disk model

  type="$(lsblk -ndo TYPE "$path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  pkname="$(lsblk -ndo PKNAME "$path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  parent_disk="$(device_parent_disk "$path" "$type" "$pkname")"
  [[ -n "$parent_disk" ]] || parent_disk="$path"
  model="$(device_model_label "$parent_disk")"
  printf '%s' "$model"
}

truncate_field() {
  local value="$1"
  local max_len="$2"
  local len=0
  local keep=0

  [[ -n "$value" ]] || { printf '%s' ""; return; }
  len="${#value}"
  if (( len <= max_len )); then
    printf '%s' "$value"
    return
  fi
  if (( max_len <= 3 )); then
    printf '%s' "${value:0:max_len}"
    return
  fi
  keep=$((max_len - 3))
  printf '%s...' "${value:0:keep}"
}

lsblk_pair_value() {
  local line="$1"
  local key="$2"
  local value

  value="$(printf '%s\n' "$line" | sed -n "s/.*${key}=\"\\([^\"]*\\)\".*/\\1/p")"
  printf '%s' "$value"
}

prompt_device_selection() {
  local options=()
  local selected_paths=()
  local disk_path part_path
  local parttype fstype mountpoint size
  local type_label usage_label gpt_label model_label
  local desc display_path idx tag
  local part_count part_idx branch
  local -a disk_paths=()
  local -a part_paths=()
  local prompt_text value="" rc=0
  local menu_h=24 menu_w=180 list_h=14 term_cols term_lines

  mapfile -t disk_paths < <(lsblk -dnpo PATH,TYPE -e 7,11 2>/dev/null | awk '$2=="disk" {print $1}')
  [[ "${#disk_paths[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No block devices available for mounting."

  for disk_path in "${disk_paths[@]}"; do
    size="$(lsblk -ndo SIZE "$disk_path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
    [[ -n "$size" ]] || size="--"
    type_label="$(device_type_label "$disk_path" "disk" "$disk_path")"
    usage_label="partitions"
    gpt_label="$(device_gpt_label "$disk_path")"
    model_label="$(device_model_label "$disk_path")"
    display_path="$disk_path"
    display_path="$(truncate_field "$display_path" 24)"
    model_label="$(truncate_field "$model_label" 30)"
    desc="$(printf '%-24s %-10s %-12s %-8s %-3s %s' "$display_path" "$type_label" "$usage_label" "$size" "$gpt_label" "$model_label")"
    idx="${#selected_paths[@]}"
    tag="$((idx + 1))"
    options+=("$tag" "$desc")
    selected_paths+=("$disk_path")

    mapfile -t part_paths < <(lsblk -nrpo PATH,TYPE "$disk_path" 2>/dev/null | awk '$2=="part" {print $1}')
    part_count="${#part_paths[@]}"
    if (( part_count == 0 )); then
      continue
    fi

    for ((part_idx=0; part_idx<part_count; part_idx++)); do
      part_path="${part_paths[$part_idx]}"
      if (( part_idx == part_count - 1 )); then
        branch="└─"
      else
        branch="├─"
      fi

      size="$(lsblk -ndo SIZE "$part_path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      [[ -n "$size" ]] || size="--"
      fstype="$(lsblk -ndo FSTYPE "$part_path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      parttype="$(lsblk -ndo PARTTYPE "$part_path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      mountpoint="$(lsblk -ndo MOUNTPOINT "$part_path" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      mountpoint="${mountpoint:--}"

      type_label="partition"
      usage_label="$(device_usage_label "part" "$fstype" "$mountpoint" "$parttype")"
      gpt_label="$(device_gpt_label "$disk_path")"
      model_label="$(device_model_label "$disk_path")"
      display_path="  ${branch}${part_path}"
      display_path="$(truncate_field "$display_path" 24)"
      model_label="$(truncate_field "$model_label" 30)"
      desc="$(printf '%-24s %-10s %-12s %-8s %-3s %s' "$display_path" "$type_label" "$usage_label" "$size" "$gpt_label" "$model_label")"
      idx="${#selected_paths[@]}"
      tag="$((idx + 1))"
      options+=("$tag" "$desc")
      selected_paths+=("$part_path")
    done
  done

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No block devices available for mounting."

  prompt_text="Select source block device\nDevice                    Type       Usage        Size     GPT Model"
  term_cols="$(tput cols 2>/dev/null || echo 120)"
  term_lines="$(tput lines 2>/dev/null || echo 30)"
  if (( menu_w > term_cols - 4 )); then menu_w=$((term_cols - 4)); fi
  if (( menu_w < 120 )); then menu_w=120; fi
  if (( menu_h > term_lines - 2 )); then menu_h=$((term_lines - 2)); fi
  if (( menu_h < 20 )); then menu_h=20; fi

  if (( list_h > ${#selected_paths[@]} )); then
    list_h="${#selected_paths[@]}"
  fi
  if (( list_h < 8 )); then list_h=8; fi

  value="$(whiptail --title "Host Mount" --menu "$prompt_text" "$menu_h" "$menu_w" "$list_h" "${options[@]}" 3>&1 1>&2 2>&3)" || rc=$?
  case "$rc" in
    0)
      if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "$EXIT_VALIDATION" "Invalid selection value: $value"
      fi
      idx="$((value - 1))"
      if (( idx < 0 || idx >= ${#selected_paths[@]} )); then
        die "$EXIT_VALIDATION" "Selection out of range: $value"
      fi
      printf '%s' "${selected_paths[$idx]}"
      ;;
    1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
    *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
  esac
}

prompt_ctid_selection() {
  local options=()
  local ctid status lock name desc
  local short_name=""
  local lock_label=""

  while read -r ctid status lock name; do
    [[ -n "$ctid" ]] || continue
    short_name="${lock:--}"
    [[ "$short_name" == "--" ]] && short_name="${name:--}"
    lock_label=""
    if [[ -n "${lock:-}" && "$lock" != "--" ]]; then
      lock_label=" | locked"
    fi
    desc="status=${status} | ${short_name}${lock_label}"
    options+=("$ctid" "$desc")
  done < <(pct list 2>/dev/null | awk 'NR > 1 { print $1, $2, $3, $4 }')

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No LXC containers found."
  whiptail_menu_select "LXC Attach" "Select container ID" "${options[@]}"
}

prompt_host_rollback_record() {
  local options=()
  local idx=1 uuid device mount_path persist fs_type desc model
  local value="" rc=0 menu_h=22 menu_w=170 list_h=12

  while IFS='|' read -r uuid device mount_path persist fs_type; do
    [[ -n "$uuid" ]] || continue
    model="$(device_model_for_path "${device:---}")"
    desc="$(printf '%-17s %-18s %-30s %-6s %-8s %s' "$(truncate_field "${device:---}" 17)" "$(truncate_field "${model:---}" 18)" "$(truncate_field "${mount_path:---}" 30)" "${fs_type:---}" "${persist:---}" "$(truncate_field "${uuid:---}" 12)")"
    options+=("$idx" "$desc")
    idx=$((idx + 1))
  done <"$HOST_STATE_FILE"

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No managed host mounts found in state."
  if use_whiptail_ui; then
    value="$(whiptail --title "Rollback Host" --menu "Select host mount to remove\nDevice            Model              Mount path                     FS     Persist  UUID" "$menu_h" "$menu_w" "$list_h" "${options[@]}" 3>&1 1>&2 2>&3)" || rc=$?
    case "$rc" in
      0) printf '%s' "$value" ;;
      1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
      *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
    esac
    return 0
  fi
  printf '%s' "$(whiptail_menu_select "Rollback Host" "Select host mount to remove" "${options[@]}")"
}

prompt_host_remove_mode() {
  if use_whiptail_ui; then
    whiptail_menu_select "Remove Host Mount" "Choose source list" \
      "managed" "Show managed mounts only" \
      "all" "Show other mounted data disks"
    return 0
  fi

  prompt_text "Choose source list (managed/all)" "managed"
}

list_non_system_host_mounts() {
  local device uuid mountpoint fstype

  while read -r device uuid mountpoint fstype; do
    [[ -n "$mountpoint" ]] || continue
    case "$mountpoint" in
      /|/boot|/boot/efi|[[]SWAP[]]) continue ;;
    esac
    printf '%s|%s|%s|%s\n' "$uuid" "$device" "$mountpoint" "$fstype"
  done < <(lsblk -nrpo PATH,UUID,MOUNTPOINT,FSTYPE -e 7,11)
}

prompt_any_host_mount_record() {
  local options=()
  local idx=1 uuid device mount_path fs_type desc model
  local value="" rc=0 menu_h=22 menu_w=170 list_h=12

  while IFS='|' read -r uuid device mount_path fs_type; do
    [[ -n "$mount_path" ]] || continue
    model="$(device_model_for_path "${device:---}")"
    desc="$(printf '%-17s %-18s %-30s %-6s %s' "$(truncate_field "${device:---}" 17)" "$(truncate_field "${model:---}" 18)" "$(truncate_field "${mount_path:---}" 30)" "${fs_type:---}" "$(truncate_field "${uuid:---}" 12)")"
    options+=("$idx" "$desc")
    idx=$((idx + 1))
  done < <(list_non_system_host_mounts)

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No removable non-system mounted disks found."
  if use_whiptail_ui; then
    value="$(whiptail --title "Remove Host Mount" --menu "Select mounted disk to remove\nDevice            Model              Mount path                     FS     UUID" "$menu_h" "$menu_w" "$list_h" "${options[@]}" 3>&1 1>&2 2>&3)" || rc=$?
    case "$rc" in
      0) printf '%s' "$value" ;;
      1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
      *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
    esac
    return 0
  fi
  printf '%s' "$(whiptail_menu_select "Remove Host Mount" "Select mounted disk to remove" "${options[@]}")"
}

prompt_lxc_rollback_record() {
  local options=()
  local idx=1 line ctid slot host container

  while IFS='|' read -r ctid slot host container; do
    [[ -n "$ctid" ]] || continue
    options+=("$idx" "ct=${ctid} slot=${slot} host=${host} -> ${container}")
    idx=$((idx + 1))
  done <"$LXC_STATE_FILE"

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No managed LXC bind mounts found in state."
  printf '%s' "$(whiptail_menu_select "Rollback LXC" "Select LXC bind mount to remove" "${options[@]}")"
}

status_report_content() {
  cat <<EOF
Proxmox Disk Mount + LXC Helper Status

Block devices:
$(lsblk -o NAME,PATH,SIZE,FSTYPE,UUID,MOUNTPOINT -e 7,11 2>/dev/null)

Managed host mounts:
$(if [[ -f "$HOST_STATE_FILE" ]] && [[ -s "$HOST_STATE_FILE" ]]; then
    awk -F'|' '{ printf "UUID=%s device=%s mount=%s persist=%s fs=%s\n", $1, $2, $3, $4, $5 }' "$HOST_STATE_FILE"
  else
    echo "(none)"
  fi)

Managed LXC binds:
$(if [[ -f "$LXC_STATE_FILE" ]] && [[ -s "$LXC_STATE_FILE" ]]; then
    awk -F'|' '{ printf "CT=%s slot=%s host=%s container=%s\n", $1, $2, $3, $4 }' "$LXC_STATE_FILE"
  else
    echo "(none)"
  fi)

Disk editor history:
$(if [[ -f "$DISK_EDITOR_STATE_FILE" ]] && [[ -s "$DISK_EDITOR_STATE_FILE" ]]; then
    tail -n 20 "$DISK_EDITOR_STATE_FILE"
  else
    echo "(none)"
  fi)

Current LXC bind mounts:
$(awk 'BEGIN { any = 0 }
  { print }' <<<"$(while read -r ctid; do
    [[ -n "$ctid" ]] || continue
    entries="$(pct_bind_entries "$ctid")"
    if [[ -n "$entries" ]]; then
      echo "CT $ctid:"
      awk -F'|' '{ printf "  %s -> %s => %s\n", $1, $2, $3 }' <<<"$entries"
    fi
  done < <(pct list 2>/dev/null | awk 'NR > 1 { print $1 }'))")
EOF
}

prompt_text() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  if use_whiptail_ui; then
    value="$(whiptail_input "$SCRIPT_NAME" "$prompt" "$default_value")"
    printf '%s' "$value"
    return 0
  fi

  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Interactive prompt requires a TTY."

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$prompt: " value
  fi
  printf '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local value=""

  if use_whiptail_ui; then
    whiptail_yes_no "$SCRIPT_NAME" "$prompt" "$default_answer"
    return $?
  fi

  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Interactive prompt requires a TTY."

  while true; do
    if [[ "$default_answer" == "y" ]]; then
      read -r -p "$prompt [Y/n]: " value
      value="${value:-y}"
    else
      read -r -p "$prompt [y/N]: " value
      value="${value:-n}"
    fi

    case "${value,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

record_disk_editor_action() {
  local action="$1"
  local target="$2"
  local detail="$3"
  local line

  line="$(timestamp)|${action}|${target}|${detail}"
  state_append_unique "$DISK_EDITOR_STATE_FILE" "$line"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

refresh_block_device_data() {
  local target="${1:-}"

  if [[ -n "$target" ]]; then
    run_cmd "partprobe '$target'"
  fi
  if command_exists udevadm; then
    run_cmd "udevadm settle"
  fi
}

base_disk_for_path() {
  local target="$1"
  lsblk -ndo PKNAME "$target" 2>/dev/null | head -n1 | awk '{ if ($1 != "") print "/dev/" $1 }'
}

root_source_device() {
  findmnt -rn -o SOURCE / 2>/dev/null || true
}

device_has_mounted_children() {
  local device="$1"
  local source=""

  while read -r source; do
    [[ -n "$source" ]] || continue
    if [[ "$source" == "$device" || "$source" == ${device}* ]]; then
      return 0
    fi
  done < <(findmnt -rn -o SOURCE 2>/dev/null || true)
  return 1
}

device_has_swap_usage() {
  local device="$1"

  awk -v device="$device" '
    NR > 1 {
      if ($1 == device || index($1, device) == 1) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' /proc/swaps 2>/dev/null
}

device_has_lvm_signature() {
  local device="$1"
  local candidate=""

  command_exists pvs || return 1

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$candidate" == "$device" || "$candidate" == ${device}* ]]; then
      return 0
    fi
  done < <(pvs --noheadings -o pv_name 2>/dev/null | awk '{$1=$1; print}' || true)
  return 1
}

device_has_zfs_signature() {
  local device="$1"
  local candidate=""

  command_exists zpool || return 1

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$candidate" == "$device" || "$candidate" == ${device}* ]]; then
      return 0
    fi
  done < <(zpool status -P 2>/dev/null | awk '/\/dev\// { print $1 }' || true)
  return 1
}

device_is_root_related() {
  local device="$1"
  local root_src=""
  local root_disk=""

  root_src="$(root_source_device)"
  [[ -n "$root_src" ]] || return 1
  if [[ "$root_src" == "$device" || "$root_src" == ${device}* ]]; then
    return 0
  fi

  if [[ -b "$root_src" ]]; then
    root_disk="$(base_disk_for_path "$root_src")"
    [[ -n "$root_disk" && "$root_disk" == "$device" ]] && return 0
  fi

  if [[ "$root_src" == /dev/mapper/* ]]; then
    while read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if [[ "$candidate" == "$device" || "$candidate" == ${device}* ]]; then
        return 0
      fi
    done < <(lsblk -nrpo PATH "$root_src" 2>/dev/null | tail -n +2 || true)
  fi

  return 1
}

device_is_risky_target() {
  local device="$1"

  device_is_root_related "$device" && return 0
  device_has_mounted_children "$device" && return 0
  device_has_swap_usage "$device" && return 0
  device_has_lvm_signature "$device" && return 0
  device_has_zfs_signature "$device" && return 0
  return 1
}

device_risk_flags() {
  local device="$1"
  local flags=()

  device_is_root_related "$device" && flags+=("root")
  device_has_mounted_children "$device" && flags+=("mounted")
  device_has_swap_usage "$device" && flags+=("swap")
  device_has_lvm_signature "$device" && flags+=("lvm")
  device_has_zfs_signature "$device" && flags+=("zfs")

  if [[ "${#flags[@]}" -eq 0 ]]; then
    printf 'safe'
  else
    local joined
    joined="$(IFS=,; printf '%s' "${flags[*]}")"
    printf '%s' "$joined"
  fi
}

list_disk_devices() {
  lsblk -dnpo PATH,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'
}

disk_model() {
  lsblk -dnpo MODEL "$1" 2>/dev/null | awk '{$1=$1; print}'
}

disk_size() {
  lsblk -dnpo SIZE "$1" 2>/dev/null | awk '{$1=$1; print}'
}

disk_table_type() {
  parted -sm "$1" print 2>/dev/null | awk -F: 'NR == 2 { print $6 }' | head -n1
}

disk_partitions_list() {
  lsblk -nrpo PATH,TYPE "$1" 2>/dev/null | awk '$2 == "part" { print $1 }'
}

partition_table_summary() {
  local target="$1"
  parted -sm "$target" unit MiB print 2>/dev/null || true
}

disk_inspection_report() {
  local disk="$1"
  local report=""
  local model size pttype risk labels partitions partition=""

  model="$(disk_model "$disk")"
  size="$(disk_size "$disk")"
  pttype="$(disk_table_type "$disk")"
  risk="$(device_risk_flags "$disk")"
  labels="$(blkid -o export "$disk" 2>/dev/null | awk -F= '/^(LABEL|UUID|TYPE|PARTLABEL)=/ { print $1 "=" $2 }' || true)"

  report+="Disk: ${disk}\n"
  report+="Size: ${size:--}\n"
  report+="Model: ${model:--}\n"
  report+="Table: ${pttype:--}\n"
  report+="Risk flags: ${risk}\n"
  report+="\nPartition table summary:\n$(partition_table_summary "$disk")\n"
  report+="\nChildren:\n$(lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS -e 7,11 "$disk" 2>/dev/null)\n"
  report+="\nSignatures:\n${labels:-"(none on disk node)"}\n"

  partitions="$(disk_partitions_list "$disk")"
  if [[ -n "$partitions" ]]; then
    report+="\nPartition signatures:\n"
    while read -r partition; do
      [[ -n "$partition" ]] || continue
      report+="${partition}\n$(blkid -o export "$partition" 2>/dev/null | sed 's/^/  /' || echo '  (no blkid data)')\n"
    done <<<"$partitions"
  fi

  printf '%b' "$report"
}

prompt_disk_editor_disk_selection() {
  local options=()
  local selected_paths=()
  local disks=()
  local parts=()
  local disk part size model risk desc type_label usage_label gpt_label display_path
  local fstype parttype mountpoint
  local choice selected idx tag rc=0 value=""
  local menu_h=24 menu_w=180 list_h=14 term_cols term_lines
  local part_count part_idx branch part_disk

  mapfile -t disks < <(list_disk_devices)
  for disk in "${disks[@]}"; do
    [[ -n "$disk" ]] || continue
    size="$(disk_size "$disk")"
    model="$(disk_model "$disk")"
    [[ -n "$size" ]] || size="--"
    [[ -n "$model" ]] || model="--"
    risk="$(device_risk_flags "$disk")"
    type_label="$(device_type_label "$disk" "disk" "$disk")"
    usage_label="partitions"
    gpt_label="$(device_gpt_label "$disk")"
    display_path="$(truncate_field "$disk" 24)"
    model="$(truncate_field "$model" 26)"
    desc="$(printf '%-24s %-10s %-12s %-8s %-3s %-26s %s' "$display_path" "$type_label" "$usage_label" "$size" "$gpt_label" "$model" "$risk")"
    idx="${#selected_paths[@]}"
    tag="$((idx + 1))"
    options+=("$tag" "$desc")
    selected_paths+=("$disk")

    mapfile -t parts < <(disk_partitions_list "$disk")
    part_count="${#parts[@]}"
    for ((part_idx=0; part_idx<part_count; part_idx++)); do
      part="${parts[$part_idx]}"
      [[ -n "$part" ]] || continue
      if (( part_idx == part_count - 1 )); then
        branch="└─"
      else
        branch="├─"
      fi
      size="$(lsblk -ndo SIZE "$part" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      fstype="$(lsblk -ndo FSTYPE "$part" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      parttype="$(lsblk -ndo PARTTYPE "$part" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      mountpoint="$(lsblk -ndo MOUNTPOINT "$part" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
      mountpoint="${mountpoint:--}"
      usage_label="$(device_usage_label "part" "$fstype" "$mountpoint" "$parttype")"
      type_label="partition"
      gpt_label="$(device_gpt_label "$disk")"
      model="$(truncate_field "$(device_model_label "$disk")" 26)"
      display_path="$(truncate_field "  ${branch}${part}" 24)"
      desc="$(printf '%-24s %-10s %-12s %-8s %-3s %-26s %s' "$display_path" "$type_label" "$usage_label" "${size:---}" "$gpt_label" "$model" "$risk")"
      idx="${#selected_paths[@]}"
      tag="$((idx + 1))"
      options+=("$tag" "$desc")
      selected_paths+=("$part")
    done
  done

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No disk devices found."
  if use_whiptail_ui; then
    term_cols="$(tput cols 2>/dev/null || echo 120)"
    term_lines="$(tput lines 2>/dev/null || echo 30)"
    if (( menu_w > term_cols - 4 )); then menu_w=$((term_cols - 4)); fi
    if (( menu_w < 120 )); then menu_w=120; fi
    if (( menu_h > term_lines - 2 )); then menu_h=$((term_lines - 2)); fi
    if (( menu_h < 20 )); then menu_h=20; fi
    if (( list_h > ${#selected_paths[@]} )); then list_h="${#selected_paths[@]}"; fi
    if (( list_h < 8 )); then list_h=8; fi

    value="$(whiptail --title "GParted Mode" --menu "Select disk to inspect or edit\nDevice                    Type       Usage        Size     GPT Model                      Risk" "$menu_h" "$menu_w" "$list_h" "${options[@]}" 3>&1 1>&2 2>&3)" || rc=$?
    case "$rc" in
      0)
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
          die "$EXIT_VALIDATION" "Invalid selection value: $value"
        fi
        idx="$((value - 1))"
        if (( idx < 0 || idx >= ${#selected_paths[@]} )); then
          die "$EXIT_VALIDATION" "Selection out of range: $value"
        fi
        selected="${selected_paths[$idx]}"
        if [[ "$(lsblk -ndo TYPE "$selected" 2>/dev/null | head -n1 | awk '{$1=$1; print}')" == "part" ]]; then
          part_disk="$(base_disk_for_path "$selected")"
          [[ -n "$part_disk" ]] && selected="$part_disk"
        fi
        printf '%s' "$selected"
        ;;
      1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
      *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
    esac
    return 0
  fi

  printf '\nAvailable disks:\n' >&2
  for selected in "${!disks[@]}"; do
    disk="${disks[$selected]}"
    printf '  %s) %s size=%s model=%s risk=%s\n' \
      "$((selected + 1))" "$disk" "$(disk_size "$disk")" "$(disk_model "$disk")" "$(device_risk_flags "$disk")" >&2
  done
  printf '  0) Back\n' >&2
  choice="$(prompt_text "Select disk number" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid disk selection: $choice"
  [[ "$choice" -eq 0 ]] && printf '%s' "$MENU_BACK_TOKEN" && return 0
  selected=$((choice - 1))
  [[ "$selected" -ge 0 && "$selected" -lt "${#disks[@]}" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
  printf '%s' "${disks[$selected]}"
}

prompt_disk_editor_action() {
  if use_whiptail_ui; then
    whiptail_menu_select "GParted Mode" "Choose disk action" \
      "inspect" "Inspect disk layout, signatures, mountpoints, and risk flags" \
      "wipe-signatures" "Wipe signatures from disk or partition" \
      "make-table" "Create or replace partition table (gpt/msdos)" \
      "create-partition" "Create a partition using start/end or remaining space" \
      "delete-partition" "Delete an existing partition" \
      "resize-partition" "Resize an existing partition" \
      "format-partition" "Format partition as ext4, xfs, exfat, or swap" \
      "set-label" "Set filesystem label on supported filesystems" \
      "mount-now" "Mount a formatted partition on the host now" \
      "back" "Return to disk selection"
    return 0
  fi

  cat <<'EOF' >&2

---- GParted Mode ----
1) Inspect disk
2) Wipe signatures
3) Create or replace partition table
4) Create partition
5) Delete partition
6) Resize partition
7) Format partition
8) Set filesystem label
9) Mount formatted partition now
0) Back
EOF
  case "$(prompt_text "Select an action" "1")" in
    1) printf 'inspect' ;;
    2) printf 'wipe-signatures' ;;
    3) printf 'make-table' ;;
    4) printf 'create-partition' ;;
    5) printf 'delete-partition' ;;
    6) printf 'resize-partition' ;;
    7) printf 'format-partition' ;;
    8) printf 'set-label' ;;
    9) printf 'mount-now' ;;
    0) printf '%s' "$MENU_BACK_TOKEN" ;;
    *) die "$EXIT_USAGE" "Unknown disk editor action selection." ;;
  esac
}

prompt_partition_selection_for_disk() {
  local disk="$1"
  local title="${2:-Select partition}"
  local prompt="${3:-Choose a partition}"
  local options=()
  local parts=()
  local part fs label uuid mount desc
  local choice selected idx tag rc=0 value=""
  local menu_h=24 menu_w=180 list_h=12 term_cols term_lines
  local part_count part_idx branch display_path

  while read -r part; do
    [[ -n "$part" ]] || continue
    parts+=("$part")
    fs="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
    label="$(blkid -s LABEL -o value "$part" 2>/dev/null || true)"
    uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
    mount="$(findmnt -rn -o TARGET --source "$part" 2>/dev/null || true)"
    desc="fs=${fs:--} label=${label:--} uuid=${uuid:--} mount=${mount:--}"
    options+=("$part" "$desc")
  done < <(disk_partitions_list "$disk")

  [[ "${#options[@]}" -gt 0 ]] || die "$EXIT_VALIDATION" "No partitions found on $disk."
  if use_whiptail_ui; then
    options=()
    part_count="${#parts[@]}"
    for ((part_idx=0; part_idx<part_count; part_idx++)); do
      part="${parts[$part_idx]}"
      fs="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
      label="$(blkid -s LABEL -o value "$part" 2>/dev/null || true)"
      uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
      mount="$(findmnt -rn -o TARGET --source "$part" 2>/dev/null || true)"
      if (( part_idx == part_count - 1 )); then
        branch="└─"
      else
        branch="├─"
      fi
      display_path="$(truncate_field "  ${branch}${part}" 28)"
      desc="$(printf '%-28s %-8s %-16s %-28s %s' "$display_path" "${fs:---}" "$(truncate_field "${label:---}" 16)" "$(truncate_field "${mount:---}" 28)" "$(truncate_field "${uuid:---}" 24)")"
      idx="${#options[@]}"
      tag="$((idx / 2 + 1))"
      options+=("$tag" "$desc")
    done

    term_cols="$(tput cols 2>/dev/null || echo 120)"
    term_lines="$(tput lines 2>/dev/null || echo 30)"
    if (( menu_w > term_cols - 4 )); then menu_w=$((term_cols - 4)); fi
    if (( menu_w < 120 )); then menu_w=120; fi
    if (( menu_h > term_lines - 2 )); then menu_h=$((term_lines - 2)); fi
    if (( menu_h < 20 )); then menu_h=20; fi
    if (( list_h > part_count )); then list_h="$part_count"; fi
    if (( list_h < 8 )); then list_h=8; fi

    value="$(whiptail --title "$title" --menu "$prompt\nPartition                  FS       Label            Mount path                   UUID\nDisk: $disk" "$menu_h" "$menu_w" "$list_h" "${options[@]}" 3>&1 1>&2 2>&3)" || rc=$?
    case "$rc" in
      0)
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
          die "$EXIT_VALIDATION" "Invalid selection value: $value"
        fi
        idx="$((value - 1))"
        if (( idx < 0 || idx >= part_count )); then
          die "$EXIT_VALIDATION" "Selection out of range: $value"
        fi
        printf '%s' "${parts[$idx]}"
        ;;
      1|255) printf '%s' "$MENU_BACK_TOKEN" ;;
      *) die "$EXIT_CANCELLED" "Operation cancelled." ;;
    esac
    return 0
  fi

  printf '\n%s\n' "$prompt" >&2
  for selected in "${!parts[@]}"; do
    part="${parts[$selected]}"
    printf '  %s) %s fs=%s label=%s uuid=%s mount=%s\n' \
      "$((selected + 1))" "$part" \
      "$(blkid -s TYPE -o value "$part" 2>/dev/null || echo --)" \
      "$(blkid -s LABEL -o value "$part" 2>/dev/null || echo --)" \
      "$(blkid -s UUID -o value "$part" 2>/dev/null || echo --)" \
      "$(findmnt -rn -o TARGET --source "$part" 2>/dev/null || echo --)" >&2
  done
  printf '  0) Back\n' >&2
  choice="$(prompt_text "Select partition number" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid partition selection: $choice"
  [[ "$choice" -eq 0 ]] && printf '%s' "$MENU_BACK_TOKEN" && return 0
  selected=$((choice - 1))
  [[ "$selected" -ge 0 && "$selected" -lt "${#parts[@]}" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
  printf '%s' "${parts[$selected]}"
}

prompt_partition_table_type() {
  if use_whiptail_ui; then
    whiptail_menu_select "Partition Table" "Choose partition table type" \
      "gpt" "GUID Partition Table (recommended)" \
      "msdos" "MBR / msdos"
    return 0
  fi
  prompt_text "Choose partition table type (gpt/msdos)" "gpt"
}

prompt_partition_filesystem_type() {
  if use_whiptail_ui; then
    whiptail_menu_select "Format Partition" "Choose filesystem type" \
      "btrfs" "Btrfs" \
      "ext2" "Linux ext2" \
      "ext3" "Linux ext3" \
      "ext4" "Linux ext4" \
      "fat32" "FAT32 / vfat" \
      "ntfs" "NTFS" \
      "xfs" "XFS" \
      "exfat" "exFAT" \
      "swap" "Linux swap"
    return 0
  fi
  prompt_text "Choose filesystem type (btrfs/ext2/ext3/ext4/fat32/ntfs/xfs/exfat/swap)" "ext4"
}

prompt_disk_editor_post_format_action() {
  if use_whiptail_ui; then
    whiptail_menu_select "Format Complete" "Choose next step" \
      "return" "Return to disk editor" \
      "mount" "Mount on host now" \
      "exit" "Exit disk editor"
    return 0
  fi
  prompt_text "Choose next step (return/mount/exit)" "return"
}

prompt_disk_editor_format_now() {
  prompt_yes_no "Format new partition now?" "y"
}

confirm_disk_editor_destructive_action() {
  local action="$1"
  local target="$2"
  local risk_target="${3:-$target}"
  local risk_flags=""
  local warning=""

  risk_flags="$(device_risk_flags "$risk_target")"
  warning="This will ${action} on ${target}."
  if [[ "$risk_flags" != "safe" ]]; then
    warning="${warning}\n\nWARNING: ${risk_target} looks active or system-related (${risk_flags}). The Proxmox host may crash, lose mounts, or become unbootable."
  else
    warning="${warning}\n\nWARNING: This action is destructive and may remove data."
  fi

  prompt_yes_no "$warning" "n" || die "$EXIT_CANCELLED" "Destructive action cancelled."
}

resolve_partition_path_by_number() {
  local disk="$1"
  local number="$2"
  lsblk -nrpo PATH,PARTN "$disk" 2>/dev/null | awk -v partn="$number" '$2 == partn { print $1 }' | head -n1
}

validate_partition_boundary_value() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?(MiB|GiB|%)$ ]] || die "$EXIT_VALIDATION" "Invalid boundary value: $value. Use values like 1MiB, 512MiB, 100%, 20GiB."
}

partition_number() {
  lsblk -ndo PARTN "$1" 2>/dev/null | head -n1 | awk '{$1=$1; print}'
}

maybe_mount_formatted_partition() {
  local partition="$1"
  local fs_type="$2"
  local next_step=""
  local saved_device="$DEVICE"
  local saved_uuid="$UUID_VALUE"
  local saved_mount="$MOUNT_PATH"
  local saved_persist="$PERSIST_MODE"

  next_step="$(prompt_disk_editor_post_format_action)"
  is_menu_back "$next_step" && next_step="return"

  case "$next_step" in
    mount)
      DEVICE="$partition"
      UUID_VALUE="$(resolve_uuid_from_device "$partition")"
      [[ -n "$UUID_VALUE" ]] || die "$EXIT_VALIDATION" "Could not resolve a UUID for $partition after formatting."
      MOUNT_PATH=""
      PERSIST_MODE=""
      HOST_FS_TYPE="$fs_type"
      run_host_mount
      ;;
    exit)
      DEVICE="$saved_device"
      UUID_VALUE="$saved_uuid"
      MOUNT_PATH="$saved_mount"
      PERSIST_MODE="$saved_persist"
      return 10
      ;;
    *)
      ;;
  esac

  DEVICE="$saved_device"
  UUID_VALUE="$saved_uuid"
  MOUNT_PATH="$saved_mount"
  PERSIST_MODE="$saved_persist"
  return 0
}

run_disk_editor_inspect() {
  local disk="$1"
  local report

  report="$(disk_inspection_report "$disk")"
  if use_whiptail_ui; then
    whiptail_show_text "Disk Inspect" "$report"
  else
    printf '\n%s\n' "$report"
  fi
}

run_disk_editor_wipe_signatures() {
  local disk="$1"
  local target_mode="disk"
  local target="$disk"

  require_commands wipefs

  if [[ -n "$(disk_partitions_list "$disk")" ]]; then
    if use_whiptail_ui; then
      target_mode="$(whiptail_menu_select "Wipe Signatures" "Choose signature wipe target" \
        "disk" "Wipe signatures on the whole disk node" \
        "partition" "Choose a specific partition to wipe")"
      is_menu_back "$target_mode" && return 0
    else
      target_mode="$(prompt_text "Wipe signatures on disk or partition?" "disk")"
    fi
  fi

  if [[ "$target_mode" == "partition" ]]; then
    target="$(prompt_partition_selection_for_disk "$disk" "Wipe Signatures" "Choose partition to wipe")"
    is_menu_back "$target" && return 0
  fi

  confirm_disk_editor_destructive_action "wipe signatures" "$target" "$disk"
  run_cmd "wipefs -a '$target'"
  refresh_block_device_data "$disk"
  record_disk_editor_action "wipe-signatures" "$target" "disk=$disk"
}

run_disk_editor_make_table() {
  local disk="$1"
  local table_type

  require_commands parted
  table_type="$(prompt_partition_table_type)"
  is_menu_back "$table_type" && return 0

  confirm_disk_editor_destructive_action "create a ${table_type} partition table" "$disk" "$disk"
  run_cmd "parted -s '$disk' mklabel '$table_type'"
  refresh_block_device_data "$disk"
  record_disk_editor_action "make-table" "$disk" "table=$table_type"
}

run_disk_editor_create_partition() {
  local disk="$1"
  local start_value=""
  local end_value=""
  local before_parts=""
  local after_parts=""
  local new_partition=""
  local rc=0

  require_commands parted

  start_value="$(prompt_text "Partition start (example: 1MiB)" "1MiB")"
  is_menu_back "$start_value" && return 0
  end_value="$(prompt_text "Partition end (example: 100% or 512GiB)" "100%")"
  is_menu_back "$end_value" && return 0

  validate_partition_boundary_value "$start_value"
  validate_partition_boundary_value "$end_value"

  before_parts="$(disk_partitions_list "$disk")"
  confirm_disk_editor_destructive_action "create a partition on" "$disk" "$disk"
  run_cmd "parted -s '$disk' mkpart primary '$start_value' '$end_value'"
  refresh_block_device_data "$disk"
  after_parts="$(disk_partitions_list "$disk")"
  new_partition="$(comm -13 <(printf '%s\n' "$before_parts" | sed '/^$/d' | sort) <(printf '%s\n' "$after_parts" | sed '/^$/d' | sort) | head -n1)"
  record_disk_editor_action "create-partition" "${new_partition:-$disk}" "disk=$disk start=$start_value end=$end_value"
  if [[ -n "$new_partition" ]]; then
    info "Created partition: $new_partition"
    if prompt_disk_editor_format_now; then
      run_disk_editor_format_partition_internal "$disk" "$new_partition" || rc=$?
      [[ "$rc" -eq 10 ]] && return 10
    fi
  fi
}

run_disk_editor_delete_partition() {
  local disk="$1"
  local partition=""
  local number=""

  require_commands parted
  partition="$(prompt_partition_selection_for_disk "$disk" "Delete Partition" "Choose partition to delete")"
  is_menu_back "$partition" && return 0
  number="$(partition_number "$partition")"
  [[ -n "$number" ]] || die "$EXIT_VALIDATION" "Could not determine partition number for $partition"

  confirm_disk_editor_destructive_action "delete partition" "$partition" "$disk"
  if device_has_swap_usage "$partition"; then
    run_cmd "swapoff '$partition'"
  fi
  if findmnt -rn --source "$partition" >/dev/null 2>&1; then
    run_cmd "umount '$partition'"
  fi
  run_cmd "parted -s '$disk' rm '$number'"
  refresh_block_device_data "$disk"
  record_disk_editor_action "delete-partition" "$partition" "disk=$disk number=$number"
}

run_disk_editor_resize_partition() {
  local disk="$1"
  local partition=""
  local number=""
  local end_value=""

  require_commands parted
  partition="$(prompt_partition_selection_for_disk "$disk" "Resize Partition" "Choose partition to resize")"
  is_menu_back "$partition" && return 0
  number="$(partition_number "$partition")"
  [[ -n "$number" ]] || die "$EXIT_VALIDATION" "Could not determine partition number for $partition"
  end_value="$(prompt_text "New partition end (example: 100%, 900GiB)" "100%")"
  is_menu_back "$end_value" && return 0
  validate_partition_boundary_value "$end_value"

  confirm_disk_editor_destructive_action "resize partition" "$partition" "$disk"
  run_cmd "parted -s '$disk' resizepart '$number' '$end_value'"
  refresh_block_device_data "$disk"
  record_disk_editor_action "resize-partition" "$partition" "disk=$disk end=$end_value"
}

run_disk_editor_format_partition_internal() {
  local disk="$1"
  local partition="$2"
  local fs_type=""
  local label=""
  local rc=0

  fs_type="$(prompt_partition_filesystem_type)"
  is_menu_back "$fs_type" && return 0
  label="$(prompt_text "Optional label for the new filesystem (leave empty to skip)" "")"

  case "$fs_type" in
    btrfs) require_commands mkfs.btrfs ;;
    ext2) require_commands mkfs.ext2 ;;
    ext3) require_commands mkfs.ext3 ;;
    ext4) require_commands mkfs.ext4 ;;
    fat32)
      if command_exists mkfs.fat; then
        :
      elif command_exists mkfs.vfat; then
        :
      else
        die "$EXIT_DEPENDENCY" "Missing required command: mkfs.fat or mkfs.vfat"
      fi
      ;;
    ntfs)
      if command_exists mkfs.ntfs; then
        :
      elif command_exists mkntfs; then
        :
      else
        die "$EXIT_DEPENDENCY" "Missing required command: mkfs.ntfs or mkntfs"
      fi
      ;;
    xfs) require_commands mkfs.xfs ;;
    exfat)
      if command_exists mkfs.exfat; then
        :
      elif command_exists mkexfatfs; then
        :
      else
        die "$EXIT_DEPENDENCY" "Missing required command: mkfs.exfat or mkexfatfs"
      fi
      ;;
    swap) require_commands mkswap ;;
    *) die "$EXIT_USAGE" "Unsupported filesystem type: $fs_type" ;;
  esac

  confirm_disk_editor_destructive_action "format partition" "$partition" "$disk"
  if device_has_swap_usage "$partition"; then
    run_cmd "swapoff '$partition'"
  fi
  if findmnt -rn --source "$partition" >/dev/null 2>&1; then
    run_cmd "umount '$partition'"
  fi

  case "$fs_type" in
    btrfs)
      if [[ -n "$label" ]]; then
        run_cmd "mkfs.btrfs -f -L '$label' '$partition'"
      else
        run_cmd "mkfs.btrfs -f '$partition'"
      fi
      ;;
    ext2)
      if [[ -n "$label" ]]; then
        run_cmd "mkfs.ext2 -F -L '$label' '$partition'"
      else
        run_cmd "mkfs.ext2 -F '$partition'"
      fi
      ;;
    ext3)
      if [[ -n "$label" ]]; then
        run_cmd "mkfs.ext3 -F -L '$label' '$partition'"
      else
        run_cmd "mkfs.ext3 -F '$partition'"
      fi
      ;;
    ext4)
      if [[ -n "$label" ]]; then
        run_cmd "mkfs.ext4 -F -L '$label' '$partition'"
      else
        run_cmd "mkfs.ext4 -F '$partition'"
      fi
      ;;
    fat32)
      if command_exists mkfs.fat; then
        if [[ -n "$label" ]]; then
          run_cmd "mkfs.fat -F 32 -n '$label' '$partition'"
        else
          run_cmd "mkfs.fat -F 32 '$partition'"
        fi
      else
        if [[ -n "$label" ]]; then
          run_cmd "mkfs.vfat -F 32 -n '$label' '$partition'"
        else
          run_cmd "mkfs.vfat -F 32 '$partition'"
        fi
      fi
      ;;
    ntfs)
      if command_exists mkfs.ntfs; then
        if [[ -n "$label" ]]; then
          run_cmd "mkfs.ntfs -F -L '$label' '$partition'"
        else
          run_cmd "mkfs.ntfs -F '$partition'"
        fi
      else
        if [[ -n "$label" ]]; then
          run_cmd "mkntfs -F -L '$label' '$partition'"
        else
          run_cmd "mkntfs -F '$partition'"
        fi
      fi
      ;;
    xfs)
      if [[ -n "$label" ]]; then
        run_cmd "mkfs.xfs -f -L '$label' '$partition'"
      else
        run_cmd "mkfs.xfs -f '$partition'"
      fi
      ;;
    exfat)
      if command_exists mkfs.exfat; then
        if [[ -n "$label" ]]; then
          run_cmd "mkfs.exfat -n '$label' '$partition'"
        else
          run_cmd "mkfs.exfat '$partition'"
        fi
      else
        if [[ -n "$label" ]]; then
          run_cmd "mkexfatfs -n '$label' '$partition'"
        else
          run_cmd "mkexfatfs '$partition'"
        fi
      fi
      ;;
    swap)
      if [[ -n "$label" ]]; then
        run_cmd "mkswap -L '$label' '$partition'"
      else
        run_cmd "mkswap '$partition'"
      fi
      ;;
  esac

  refresh_block_device_data "$disk"
  record_disk_editor_action "format-partition" "$partition" "disk=$disk fs=$fs_type label=${label:--}"
  maybe_mount_formatted_partition "$partition" "$fs_type" || rc=$?
  [[ "$rc" -eq 10 ]] && return 10
  return 0
}

run_disk_editor_format_partition() {
  local disk="$1"
  local partition=""

  partition="$(prompt_partition_selection_for_disk "$disk" "Format Partition" "Choose partition to format")"
  is_menu_back "$partition" && return 0
  run_disk_editor_format_partition_internal "$disk" "$partition"
}

run_disk_editor_set_label() {
  local disk="$1"
  local partition=""
  local fs_type=""
  local new_label=""

  partition="$(prompt_partition_selection_for_disk "$disk" "Set Label" "Choose partition to label")"
  is_menu_back "$partition" && return 0
  fs_type="$(blkid -s TYPE -o value "$partition" 2>/dev/null || true)"
  [[ -n "$fs_type" ]] || die "$EXIT_VALIDATION" "Could not detect filesystem type for $partition"
  new_label="$(prompt_text "Enter new label for $partition" "")"
  [[ -n "$new_label" ]] || die "$EXIT_VALIDATION" "Label cannot be empty."

  case "$fs_type" in
    btrfs)
      require_commands btrfs
      ;;
    ext2|ext3|ext4)
      require_commands e2label
      ;;
    ntfs)
      require_commands ntfslabel
      ;;
    vfat|fat|fat32)
      if command_exists fatlabel; then
        :
      elif command_exists dosfslabel; then
        :
      else
        die "$EXIT_DEPENDENCY" "Missing required command: fatlabel or dosfslabel"
      fi
      ;;
    xfs)
      require_commands xfs_admin
      ;;
    exfat)
      if command_exists exfatlabel; then
        :
      elif command_exists tune.exfat; then
        :
      else
        die "$EXIT_DEPENDENCY" "Missing required command: exfatlabel or tune.exfat"
      fi
      ;;
    swap)
      require_commands swaplabel
      ;;
    *)
      die "$EXIT_VALIDATION" "Filesystem labels are not supported in this helper for type: $fs_type"
      ;;
  esac

  confirm_disk_editor_destructive_action "set label on" "$partition" "$disk"
  case "$fs_type" in
    btrfs)
      run_cmd "btrfs filesystem label '$partition' '$new_label'"
      ;;
    ext2|ext3|ext4)
      run_cmd "e2label '$partition' '$new_label'"
      ;;
    ntfs)
      run_cmd "ntfslabel '$partition' '$new_label'"
      ;;
    vfat|fat|fat32)
      if command_exists fatlabel; then
        run_cmd "fatlabel '$partition' '$new_label'"
      else
        run_cmd "dosfslabel '$partition' '$new_label'"
      fi
      ;;
    xfs)
      run_cmd "xfs_admin -L '$new_label' '$partition'"
      ;;
    exfat)
      if command_exists exfatlabel; then
        run_cmd "exfatlabel '$partition' '$new_label'"
      else
        run_cmd "tune.exfat -L '$new_label' '$partition'"
      fi
      ;;
    swap)
      run_cmd "swaplabel -L '$new_label' '$partition'"
      ;;
  esac
  refresh_block_device_data "$disk"
  record_disk_editor_action "set-label" "$partition" "disk=$disk label=$new_label fs=$fs_type"
}

run_disk_editor_mount_now() {
  local disk="$1"
  local partition=""
  local fs_type=""
  local uuid=""
  local saved_device="$DEVICE"
  local saved_uuid="$UUID_VALUE"
  local saved_mount="$MOUNT_PATH"
  local saved_persist="$PERSIST_MODE"

  partition="$(prompt_partition_selection_for_disk "$disk" "Mount Partition" "Choose partition to mount on the host")"
  is_menu_back "$partition" && return 0
  fs_type="$(resolve_fstype_from_device "$partition")"
  uuid="$(resolve_uuid_from_device "$partition")"
  [[ -n "$fs_type" ]] || die "$EXIT_VALIDATION" "No filesystem found on $partition. Format it first."
  [[ -n "$uuid" ]] || die "$EXIT_VALIDATION" "No UUID found on $partition. Format it first."

  DEVICE="$partition"
  UUID_VALUE="$uuid"
  MOUNT_PATH=""
  PERSIST_MODE=""
  HOST_FS_TYPE="$fs_type"
  run_host_mount

  DEVICE="$saved_device"
  UUID_VALUE="$saved_uuid"
  MOUNT_PATH="$saved_mount"
  PERSIST_MODE="$saved_persist"
}

run_disk_editor() {
  local disk=""
  local action=""
  local rc=0

  require_root
  require_proxmox
  ensure_state_dir
  require_commands lsblk blkid findmnt parted awk grep sed mount umount wipefs

  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Disk editor requires an interactive TTY."

  while true; do
    disk="$(prompt_disk_editor_disk_selection)"
    is_menu_back "$disk" && return 0

    while true; do
      action="$(prompt_disk_editor_action)"
      is_menu_back "$action" && break
      case "$action" in
        inspect) run_disk_editor_inspect "$disk" ;;
        wipe-signatures) run_disk_editor_wipe_signatures "$disk" ;;
        make-table) run_disk_editor_make_table "$disk" ;;
        create-partition)
          rc=0
          run_disk_editor_create_partition "$disk" || rc=$?
          [[ "$rc" -eq 10 ]] && return 0
          ;;
        delete-partition) run_disk_editor_delete_partition "$disk" ;;
        resize-partition) run_disk_editor_resize_partition "$disk" ;;
        format-partition)
          rc=0
          run_disk_editor_format_partition "$disk" || rc=$?
          [[ "$rc" -eq 10 ]] && return 0
          ;;
        set-label) run_disk_editor_set_label "$disk" ;;
        mount-now) run_disk_editor_mount_now "$disk" ;;
        back) break ;;
        *) warn "Unknown disk editor action: $action" ;;
      esac
    done
  done
}

list_disk_summary() {
  info "Available block devices:"
  lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,PTTYPE,MODEL,UUID,MOUNTPOINT -e 7,11
}

resolve_device_from_uuid() {
  local uuid="$1"
  blkid -U "$uuid" 2>/dev/null || true
}

resolve_uuid_from_device() {
  local device="$1"
  blkid -s UUID -o value "$device" 2>/dev/null || true
}

resolve_fstype_from_device() {
  local device="$1"
  blkid -s TYPE -o value "$device" 2>/dev/null || true
}

find_existing_mount_source() {
  local target="$1"
  local row mnt src
  row="$(findmnt -rn -o TARGET,SOURCE --target "$target" 2>/dev/null | head -n1 || true)"
  mnt="$(awk '{print $1}' <<<"$row" 2>/dev/null || true)"
  src="$(awk '{print $2}' <<<"$row" 2>/dev/null || true)"
  if [[ "$mnt" == "$target" ]]; then
    printf '%s' "$src"
  fi
}

is_path_mounted() {
  local target="$1"
  [[ -n "$(find_existing_mount_source "$target")" ]]
}

find_existing_mount_uuid() {
  local target="$1"
  local src

  src="$(find_existing_mount_source "$target")"
  if [[ "$src" =~ ^UUID= ]]; then
    printf '%s' "${src#UUID=}"
    return
  fi
  if [[ -b "$src" ]]; then
    resolve_uuid_from_device "$src"
  fi
}

fstab_find_entry_for_uuid() {
  local uuid="$1"
  awk -v uuid="$uuid" '
    /^[[:space:]]*#/ { next }
    $1 == "UUID=" uuid { print $0 }
  ' /etc/fstab 2>/dev/null || true
}

fstab_find_entry_for_mount() {
  local mount_path="$1"
  awk -v mount_path="$mount_path" '
    /^[[:space:]]*#/ { next }
    $2 == mount_path { print $0 }
  ' /etc/fstab 2>/dev/null || true
}

add_fstab_entry() {
  local uuid="$1"
  local mount_path="$2"
  local fs_type="$3"
  local exact_line

  exact_line="UUID=${uuid} ${mount_path} ${fs_type} defaults,nofail 0 2"
  if grep -Fqx "$exact_line" /etc/fstab 2>/dev/null; then
    info "Matching /etc/fstab entry already exists."
    return 0
  fi

  backup_file /etc/fstab
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: append to /etc/fstab -> $exact_line"
    return 0
  fi
  echo "$exact_line" >>/etc/fstab
  info "Added /etc/fstab entry for UUID=$uuid."
}

remove_fstab_entry() {
  local uuid="$1"
  local mount_path="$2"
  local tmp removed=0

  [[ -f /etc/fstab ]] || return 0
  backup_file /etc/fstab

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: remove /etc/fstab entry for UUID=$uuid mount_path=$mount_path"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v uuid="$uuid" -v mount_path="$mount_path" '
    BEGIN { removed = 0 }
    /^[[:space:]]*#/ { print; next }
    {
      if ($1 == "UUID=" uuid && $2 == mount_path) {
        removed = 1
        next
      }
      print
    }
    END {
      if (removed == 0) {
        exit 2
      }
    }
  ' /etc/fstab >"$tmp" || removed=$?

  if [[ "$removed" -eq 2 ]]; then
    rm -f "$tmp"
    info "No matching /etc/fstab entry found for UUID=$uuid mount_path=$mount_path."
    return 0
  fi

  mv "$tmp" /etc/fstab
  info "Removed matching /etc/fstab entry."
}

remove_fstab_entry_for_mount_path() {
  local mount_path="$1"
  local tmp removed=0

  [[ -f /etc/fstab ]] || return 0
  backup_file /etc/fstab

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: remove /etc/fstab entry for mount_path=$mount_path"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v mount_path="$mount_path" '
    BEGIN { removed = 0 }
    /^[[:space:]]*#/ { print; next }
    {
      opts = $4
      is_bind = (opts ~ /(^|,)bind(,|$)/)
      if ($2 == mount_path && !is_bind) {
        removed = 1
        next
      }
      print
    }
    END {
      if (removed == 0) exit 2
    }
  ' /etc/fstab >"$tmp" || removed=$?

  if [[ "$removed" -eq 2 ]]; then
    rm -f "$tmp"
    info "No matching non-bind /etc/fstab entry found for mount_path=$mount_path."
    return 0
  fi

  mv "$tmp" /etc/fstab
  info "Removed matching non-bind /etc/fstab entry for mount_path=$mount_path."
}

remove_fstab_bind_entries_for_path() {
  local mount_path="$1"
  local tmp removed=0

  [[ -f /etc/fstab ]] || return 0
  backup_file /etc/fstab

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: remove bind entries in /etc/fstab related to $mount_path"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v p="$mount_path" '
    BEGIN { removed = 0 }
    /^[[:space:]]*#/ { print; next }
    {
      opts = $4
      is_bind = (opts ~ /(^|,)bind(,|$)/)
      src_match = ($1 == p || index($1, p "/") == 1)
      dst_match = ($2 == p || index($2, p "/") == 1)
      if (is_bind && (src_match || dst_match)) {
        removed = 1
        next
      }
      print
    }
    END { if (removed == 0) exit 2 }
  ' /etc/fstab >"$tmp" || removed=$?

  if [[ "$removed" -eq 2 ]]; then
    rm -f "$tmp"
    info "No related bind entries found in /etc/fstab for $mount_path."
    return 0
  fi

  mv "$tmp" /etc/fstab
  info "Removed related bind entries from /etc/fstab for $mount_path."
}

unmount_bind_children_for_path() {
  local mount_path="$1"
  local target
  local had_children=0

  while read -r target; do
    [[ -n "$target" ]] || continue
    had_children=1
    run_cmd "umount '$target'" || true
  done < <(
    findmnt -rn -o SOURCE,TARGET 2>/dev/null | \
      awk -v p="$mount_path" '$1 == p || index($1, p "/") == 1 { print $2 }' | \
      awk -v p="$mount_path" '$1 != p' | \
      sort -r
  )

  if [[ "$had_children" -eq 1 ]]; then
    info "Processed dependent bind mounts for $mount_path."
  fi
}

prompt_mount_persistence() {
  if prompt_yes_no "Persist this host mount in /etc/fstab?" "y"; then
    PERSIST_MODE="persistent"
  else
    PERSIST_MODE="temporary"
  fi
}

host_state_line() {
  printf '%s|%s|%s|%s|%s' "$UUID_VALUE" "$DEVICE" "$MOUNT_PATH" "$PERSIST_MODE" "$1"
}

lxc_state_line() {
  printf '%s|%s|%s|%s' "$CTID" "$MP_SLOT" "$HOST_PATH" "$CONTAINER_PATH"
}

validate_host_mount_inputs() {
  [[ -b "$DEVICE" ]] || die "$EXIT_VALIDATION" "Block device not found: $DEVICE"
  [[ -n "$UUID_VALUE" ]] || die "$EXIT_VALIDATION" "No filesystem UUID found on $DEVICE. v1 only supports already-formatted disks."
  [[ -n "$1" ]] || die "$EXIT_VALIDATION" "No filesystem type found on $DEVICE."
  [[ "$MOUNT_PATH" == /* ]] || die "$EXIT_VALIDATION" "Mount path must be absolute: $MOUNT_PATH"
}

prepare_host_mount_inputs() {
  local fs_type
  require_commands lsblk blkid findmnt mount awk grep

  if [[ -z "$DEVICE" && -z "$UUID_VALUE" ]]; then
    if use_whiptail_ui; then
      DEVICE="$(prompt_device_selection)"
      if is_menu_back "$DEVICE"; then
        return 2
      fi
    else
      list_disk_summary
      DEVICE="$(prompt_text "Enter source block device (example: /dev/sdb1)")"
    fi
  fi

  if [[ -n "$DEVICE" ]]; then
    DEVICE="$(normalize_path "$DEVICE")"
  fi

  if [[ -z "$DEVICE" && -n "$UUID_VALUE" ]]; then
    DEVICE="$(resolve_device_from_uuid "$UUID_VALUE")"
  fi
  [[ -n "$DEVICE" ]] || die "$EXIT_VALIDATION" "Could not resolve a block device from the provided input."

  if [[ -z "$UUID_VALUE" ]]; then
    UUID_VALUE="$(resolve_uuid_from_device "$DEVICE")"
  fi
  fs_type="$(resolve_fstype_from_device "$DEVICE")"

  if [[ -z "$MOUNT_PATH" ]]; then
    MOUNT_PATH="$(prompt_text "Enter host mount path" "/mnt/pve/$(basename "$DEVICE")")"
  fi
  MOUNT_PATH="$(normalize_path "$MOUNT_PATH")"

  if [[ -z "$PERSIST_MODE" ]]; then
    prompt_mount_persistence
  fi

  validate_host_mount_inputs "$fs_type"

  local current_uuid current_fstab_mount current_fstab_uuid current_fstab_src
  current_uuid="$(find_existing_mount_uuid "$MOUNT_PATH")"
  if [[ -n "$current_uuid" && "$current_uuid" != "$UUID_VALUE" ]]; then
    die "$EXIT_VALIDATION" "Mount path $MOUNT_PATH is already mounted from a different UUID: $current_uuid"
  fi

  current_fstab_mount="$(fstab_find_entry_for_mount "$MOUNT_PATH")"
  current_fstab_src="$(awk '{print $1}' <<<"$current_fstab_mount" 2>/dev/null || true)"
  if [[ -n "$current_fstab_mount" && "$current_fstab_src" != "UUID=$UUID_VALUE" ]]; then
    die "$EXIT_VALIDATION" "Mount path $MOUNT_PATH already exists in /etc/fstab with a different source."
  fi

  current_fstab_uuid="$(fstab_find_entry_for_uuid "$UUID_VALUE")"
  if [[ -n "$current_fstab_uuid" ]]; then
    local fstab_mp
    fstab_mp="$(awk '{print $2}' <<<"$current_fstab_uuid")"
    if [[ -n "$fstab_mp" && "$fstab_mp" != "$MOUNT_PATH" ]]; then
      die "$EXIT_VALIDATION" "UUID $UUID_VALUE already exists in /etc/fstab for a different mount path: $fstab_mp"
    fi
  fi

  HOST_FS_TYPE="$fs_type"
}

run_host_mount() {
  local current_uuid record
  local prepare_rc=0

  require_root
  require_proxmox
  ensure_state_dir

  info "Starting host mount workflow..."
  prepare_host_mount_inputs || prepare_rc=$?
  case "$prepare_rc" in
    0) ;;
    2)
      info "Host mount menu: back requested."
      return 0
      ;;
    *)
      return "$prepare_rc"
      ;;
  esac
  info "Resolved source device=$DEVICE uuid=$UUID_VALUE fs=$HOST_FS_TYPE target=$MOUNT_PATH persist=$PERSIST_MODE"

  run_cmd "mkdir -p '$MOUNT_PATH'"

  current_uuid="$(find_existing_mount_uuid "$MOUNT_PATH")"
  if [[ "$current_uuid" == "$UUID_VALUE" ]]; then
    info "Host mount already active for UUID=$UUID_VALUE on $MOUNT_PATH."
  else
    run_cmd "mount -U '$UUID_VALUE' '$MOUNT_PATH'"
  fi

  if [[ "$PERSIST_MODE" == "persistent" ]]; then
    add_fstab_entry "$UUID_VALUE" "$MOUNT_PATH" "$HOST_FS_TYPE"
  else
    info "Temporary host mount selected; /etc/fstab will not be modified."
  fi

  record="$(host_state_line "$HOST_FS_TYPE")"
  state_append_unique "$HOST_STATE_FILE" "$record"
  info "Host mount workflow completed."
}

pct_exists() {
  pct config "$1" >/dev/null 2>&1
}

pct_config_entries() {
  pct config "$1" 2>/dev/null || true
}

pct_is_unprivileged() {
  pct config "$1" 2>/dev/null | awk '$1 == "unprivileged:" && $2 == "1" { found = 1 } END { exit(found ? 0 : 1) }'
}

pct_bind_entries() {
  local ctid="$1"
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^mp([0-9]+):[[:space:]]*([^,]+),mp=([^,]+) ]]; then
      printf 'mp%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
  done <<<"$(pct_config_entries "$ctid")"
}

next_free_mp_slot() {
  local ctid="$1"
  local used
  local i

  used="$(pct_bind_entries "$ctid" | cut -d'|' -f1 || true)"
  for i in $(seq 0 255); do
    if ! grep -Fxq "mp${i}" <<<"$used"; then
      printf 'mp%s' "$i"
      return 0
    fi
  done
  return 1
}

prompt_host_path_for_lxc() {
  local mode=""
  local selected_path=""

  mode="$(prompt_host_path_mode_selection)"
  if is_menu_back "$mode"; then
    return 2
  fi

  case "$mode" in
    browse)
      if use_whiptail_ui; then
        selected_path="$(prompt_browse_host_directory_selection)"
        if is_menu_back "$selected_path"; then
          return 2
        fi
        if [[ "$selected_path" != "manual-entry" ]]; then
          HOST_PATH="$selected_path"
          HOST_PATH="$(normalize_path "$HOST_PATH")"
          return 0
        fi
      fi
      ;;
    manual-entry)
      ;;
    *)
      die "$EXIT_VALIDATION" "Unknown host path mode: $mode"
      ;;
  esac

  show_pve_host_directories_hint 1
  HOST_PATH="$(prompt_text "Enter full host path (example: /mnt/pve/media-folder/videolxc2)")"
  HOST_PATH="$(normalize_path "$HOST_PATH")"
}

prompt_container_path_for_lxc() {
  local default_path=""
  local selected_path=""
  local options=()

  default_path="/mnt/$(basename "$HOST_PATH")"

  if use_whiptail_ui; then
    options=(
      "$default_path" "Recommended based on selected host folder"
      "/mnt/media" "Common media mount path"
      "/mnt/videos" "Good for video libraries"
      "/data" "Generic data directory"
      "/srv/media" "Service-style media path"
      "manual-entry" "Type a full container path manually"
    )
    selected_path="$(whiptail_menu_select "LXC Attach" "Select target path inside container or choose manual-entry" "${options[@]}")"
    if is_menu_back "$selected_path"; then
      return 2
    fi
    if [[ "$selected_path" != "manual-entry" ]]; then
      CONTAINER_PATH="$selected_path"
      CONTAINER_PATH="$(normalize_path "$CONTAINER_PATH")"
      return 0
    fi
  fi

  CONTAINER_PATH="$(prompt_text "Enter full target path inside container (example: /mnt/videolxc2)" "$default_path")"
  CONTAINER_PATH="$(normalize_path "$CONTAINER_PATH")"
}

prepare_lxc_attach_inputs() {
  require_commands pct awk grep mkdir chmod

  if [[ -z "$CTID" ]]; then
    if use_whiptail_ui; then
      CTID="$(prompt_ctid_selection)"
      if is_menu_back "$CTID"; then
        return 2
      fi
    else
      CTID="$(prompt_text "Enter LXC container ID")"
    fi
  fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "$EXIT_VALIDATION" "Invalid CTID: $CTID"
  pct_exists "$CTID" || die "$EXIT_VALIDATION" "LXC container not found: $CTID"

  if [[ -z "$HOST_PATH" ]]; then
    prompt_host_path_for_lxc || return $?
  fi
  HOST_PATH="$(normalize_path "$HOST_PATH")"

  if [[ -z "$CONTAINER_PATH" ]]; then
    prompt_container_path_for_lxc || return $?
  fi
  CONTAINER_PATH="$(normalize_path "$CONTAINER_PATH")"
  [[ "$CONTAINER_PATH" == /* ]] || die "$EXIT_VALIDATION" "Container path must be absolute: $CONTAINER_PATH"

  if [[ -z "$MP_SLOT" ]]; then
    MP_SLOT="$(next_free_mp_slot "$CTID")"
    info "Auto-selected next free LXC bind slot: $MP_SLOT"
  else
    MP_SLOT="$(normalize_mp_slot "$MP_SLOT")"
  fi

  local bind_line bind_slot bind_host bind_container
  while IFS= read -r bind_line; do
    [[ -n "$bind_line" ]] || continue
    IFS='|' read -r bind_slot bind_host bind_container <<<"$bind_line"
    if [[ "$bind_slot" == "$MP_SLOT" ]]; then
      die "$EXIT_VALIDATION" "LXC bind slot already in use for CT $CTID: $MP_SLOT"
    fi
    if [[ "$bind_host" == "$HOST_PATH" && "$bind_container" == "$CONTAINER_PATH" ]]; then
      MP_SLOT="$bind_slot"
      info "Identical LXC bind mount already exists for CT $CTID."
      return 1
    fi
    if [[ "$bind_host" == "$HOST_PATH" && "$bind_container" != "$CONTAINER_PATH" ]]; then
      die "$EXIT_VALIDATION" "Host path already attached to CT $CTID with a different container path: $bind_container"
    fi
    if [[ "$bind_container" == "$CONTAINER_PATH" && "$bind_host" != "$HOST_PATH" ]]; then
      die "$EXIT_VALIDATION" "Container path already used in CT $CTID by a different host path: $bind_host"
    fi
  done <<<"$(pct_bind_entries "$CTID")"

  return 0
}

apply_recommended_unprivileged_ownership() {
  if [[ -n "$CHOWN_VALUE" ]]; then
    return 0
  fi
  if pct_is_unprivileged "$CTID"; then
    warn "CT $CTID is unprivileged. Recommended ownership for new bind folders is 100000:100000."
    if [[ -t 0 && -t 1 ]] && prompt_yes_no "Apply recommended ownership 100000:100000 to the new host path?" "n"; then
      CHOWN_VALUE="100000:100000"
    fi
  fi
}

run_lxc_attach() {
  local created_dir=0 record
  local prepare_rc=0

  require_root
  require_proxmox
  ensure_state_dir

  info "Starting LXC attach workflow..."
  prepare_lxc_attach_inputs || prepare_rc=$?
  case "$prepare_rc" in
    0) ;;
    1)
      record="$(lxc_state_line)"
      state_append_unique "$LXC_STATE_FILE" "$record"
      return 0
      ;;
    2)
      info "LXC attach menu: back requested."
      return 0
      ;;
    *)
      return "$prepare_rc"
      ;;
  esac

  if [[ ! -d "$HOST_PATH" ]]; then
    run_cmd "mkdir -p '$HOST_PATH'"
    created_dir=1
  fi

  if [[ $created_dir -eq 1 ]]; then
    run_cmd "chmod '$CHMOD_VALUE' '$HOST_PATH'"
    apply_recommended_unprivileged_ownership
    if [[ -n "$CHOWN_VALUE" ]]; then
      run_cmd "chown '$CHOWN_VALUE' '$HOST_PATH'"
    fi
  else
    info "Host path already exists: $HOST_PATH"
  fi

  run_cmd "pct set '$CTID' -${MP_SLOT} '$HOST_PATH,mp=$CONTAINER_PATH'"

  record="$(lxc_state_line)"
  state_append_unique "$LXC_STATE_FILE" "$record"
  info "LXC attach workflow completed."
}

print_managed_host_state() {
  info "Managed host mounts:"
  if [[ -f "$HOST_STATE_FILE" ]] && [[ -s "$HOST_STATE_FILE" ]]; then
    awk -F'|' '{ printf "  UUID=%s device=%s mount=%s persist=%s fs=%s\n", $1, $2, $3, $4, $5 }' "$HOST_STATE_FILE"
  else
    echo "  (none)"
  fi
}

print_managed_lxc_state() {
  info "Managed LXC binds:"
  if [[ -f "$LXC_STATE_FILE" ]] && [[ -s "$LXC_STATE_FILE" ]]; then
    awk -F'|' '{ printf "  CT=%s slot=%s host=%s container=%s\n", $1, $2, $3, $4 }' "$LXC_STATE_FILE"
  else
    echo "  (none)"
  fi
}

print_disk_editor_state() {
  info "Recent disk editor actions:"
  if [[ -f "$DISK_EDITOR_STATE_FILE" ]] && [[ -s "$DISK_EDITOR_STATE_FILE" ]]; then
    tail -n 20 "$DISK_EDITOR_STATE_FILE"
  else
    echo "  (none)"
  fi
}

print_current_lxc_binds() {
  local ctid any=0 entries

  info "Current LXC bind mounts from pct config:"
  while read -r ctid; do
    [[ -n "$ctid" ]] || continue
    entries="$(pct_bind_entries "$ctid")"
    if [[ -n "$entries" ]]; then
      any=1
      echo "  CT $ctid:"
      awk -F'|' '{ printf "    %s -> %s => %s\n", $1, $2, $3 }' <<<"$entries"
    fi
  done < <(pct list 2>/dev/null | awk 'NR > 1 { print $1 }')

  if [[ $any -eq 0 ]]; then
    echo "  (none)"
  fi
}

print_matching_fstab_entries() {
  local any=0 uuid mount_path

  info "Matching /etc/fstab entries for managed host mounts:"
  if [[ ! -f "$HOST_STATE_FILE" ]] || [[ ! -s "$HOST_STATE_FILE" ]]; then
    echo "  (none)"
    return
  fi

  while IFS='|' read -r uuid _ mount_path _ _; do
    [[ -n "$uuid" ]] || continue
    local line
    line="$(fstab_find_entry_for_uuid "$uuid")"
    if [[ -n "$line" ]]; then
      any=1
      echo "  $line"
    elif [[ -n "$(fstab_find_entry_for_mount "$mount_path")" ]]; then
      any=1
      fstab_find_entry_for_mount "$mount_path" | sed 's/^/  /'
    fi
  done <"$HOST_STATE_FILE"

  if [[ $any -eq 0 ]]; then
    echo "  (none)"
  fi
}

print_managed_mount_runtime() {
  local any=0 uuid mount_path mounted_src

  info "Runtime state for managed host mounts:"
  if [[ ! -f "$HOST_STATE_FILE" ]] || [[ ! -s "$HOST_STATE_FILE" ]]; then
    echo "  (none)"
    return
  fi

  while IFS='|' read -r uuid _ mount_path persist fs_type; do
    [[ -n "$uuid" ]] || continue
    any=1
    mounted_src="$(find_existing_mount_source "$mount_path")"
    printf '  mount=%s uuid=%s fs=%s persist=%s source=%s\n' \
      "$mount_path" "$uuid" "$fs_type" "$persist" "${mounted_src:-not-mounted}"
  done <"$HOST_STATE_FILE"

  if [[ $any -eq 0 ]]; then
    echo "  (none)"
  fi
}

run_status() {
  require_root
  require_proxmox
  ensure_state_dir
  require_commands lsblk pct awk grep

  info "Collecting status..."
  if use_whiptail_ui; then
    whiptail_show_text "Status" "$(status_report_content)"
    return 0
  fi
  list_disk_summary
  print_managed_host_state
  print_matching_fstab_entries
  print_managed_mount_runtime
  print_managed_lxc_state
  print_disk_editor_state
  print_current_lxc_binds
}

select_host_state_record() {
  local lines count choice selected

  [[ -f "$HOST_STATE_FILE" && -s "$HOST_STATE_FILE" ]] || die "$EXIT_VALIDATION" "No managed host mounts found in state."
  mapfile -t lines <"$HOST_STATE_FILE"
  count="${#lines[@]}"

  if [[ "$count" -eq 1 ]]; then
    printf '%s' "${lines[0]}"
    return 0
  fi

  if use_whiptail_ui; then
    choice="$(prompt_host_rollback_record)"
    if is_menu_back "$choice"; then
      return 2
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
    selected=$((choice - 1))
    [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
    printf '%s' "${lines[$selected]}"
    return 0
  fi
  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Multiple host mount entries found; please specify --uuid or --mount-path."
  info "Select managed host mount to rollback:"
  for i in "${!lines[@]}"; do
    echo "  $((i + 1))) ${lines[$i]}"
  done
  choice="$(prompt_text "Enter selection number" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
  selected=$((choice - 1))
  [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
  printf '%s' "${lines[$selected]}"
}

select_any_host_mount_record() {
  local lines count choice selected

  mapfile -t lines < <(list_non_system_host_mounts)
  count="${#lines[@]}"
  [[ "$count" -gt 0 ]] || die "$EXIT_VALIDATION" "No removable non-system mounted disks found."

  if [[ "$count" -eq 1 ]]; then
    printf '%s' "${lines[0]}"
    return 0
  fi

  if use_whiptail_ui; then
    choice="$(prompt_any_host_mount_record)"
    if is_menu_back "$choice"; then
      return 2
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
    selected=$((choice - 1))
    [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
    printf '%s' "${lines[$selected]}"
    return 0
  fi
  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Multiple mounted disks found; please specify --mount-path."

  info "Select mounted disk to remove:"
  for i in "${!lines[@]}"; do
    echo "  $((i + 1))) ${lines[$i]}"
  done
  choice="$(prompt_text "Enter selection number" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
  selected=$((choice - 1))
  [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
  printf '%s' "${lines[$selected]}"
}

select_lxc_state_record() {
  local lines count choice selected

  [[ -f "$LXC_STATE_FILE" && -s "$LXC_STATE_FILE" ]] || die "$EXIT_VALIDATION" "No managed LXC bind mounts found in state."
  mapfile -t lines <"$LXC_STATE_FILE"
  count="${#lines[@]}"

  if [[ "$count" -eq 1 ]]; then
    printf '%s' "${lines[0]}"
    return 0
  fi

  if use_whiptail_ui; then
    choice="$(prompt_lxc_rollback_record)"
    if is_menu_back "$choice"; then
      return 2
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
    selected=$((choice - 1))
    [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
    printf '%s' "${lines[$selected]}"
    return 0
  fi
  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Multiple LXC bind entries found; please specify --ctid plus --mp-slot."
  info "Select managed LXC bind mount to rollback:"
  for i in "${!lines[@]}"; do
    echo "  $((i + 1))) ${lines[$i]}"
  done
  choice="$(prompt_text "Enter selection number" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "Invalid selection: $choice"
  selected=$((choice - 1))
  [[ "$selected" -ge 0 && "$selected" -lt "$count" ]] || die "$EXIT_USAGE" "Selection out of range: $choice"
  printf '%s' "${lines[$selected]}"
}

run_rollback_host() {
  local record fs_type="" mounted_src remove_mode state_record_found=0
  local fstab_line fstab_src

  require_root
  require_proxmox
  ensure_state_dir
  require_commands umount findmnt awk grep lsblk

  if [[ -n "$UUID_VALUE" || -n "$MOUNT_PATH" ]]; then
    if [[ -n "$MOUNT_PATH" && -z "$UUID_VALUE" ]]; then
      MOUNT_PATH="$(normalize_path "$MOUNT_PATH")"
      mounted_src="$(find_existing_mount_source "$MOUNT_PATH")"
      if [[ -n "$mounted_src" ]]; then
        DEVICE="$mounted_src"
        if [[ "$DEVICE" =~ ^UUID= ]]; then
          UUID_VALUE="${DEVICE#UUID=}"
        else
          UUID_VALUE="$(resolve_uuid_from_device "$DEVICE")"
        fi
        fs_type="$(resolve_fstype_from_device "$DEVICE")"
      else
        info "Mount path is not currently mounted: $MOUNT_PATH (cleanup mode)."
      fi
      if [[ -f "$HOST_STATE_FILE" && -s "$HOST_STATE_FILE" ]]; then
        while IFS='|' read -r state_uuid state_device state_mount state_persist state_fs; do
          if [[ "$state_mount" == "$MOUNT_PATH" ]]; then
            PERSIST_MODE="$state_persist"
            [[ -z "$DEVICE" ]] && DEVICE="$state_device"
            [[ -z "$UUID_VALUE" ]] && UUID_VALUE="$state_uuid"
            [[ -z "$fs_type" ]] && fs_type="$state_fs"
            record="${state_uuid}|${state_device}|${state_mount}|${state_persist}|${state_fs}"
            state_record_found=1
            break
          fi
        done <"$HOST_STATE_FILE"
      fi
      if [[ -z "$UUID_VALUE" ]]; then
        fstab_line="$(fstab_find_entry_for_mount "$MOUNT_PATH" | head -n1)"
        if [[ -n "$fstab_line" ]]; then
          fstab_src="$(awk '{print $1}' <<<"$fstab_line")"
          if [[ "$fstab_src" =~ ^UUID= ]]; then
            UUID_VALUE="${fstab_src#UUID=}"
          elif [[ "$fstab_src" == /dev/* ]]; then
            DEVICE="$fstab_src"
            UUID_VALUE="$(resolve_uuid_from_device "$DEVICE")"
          fi
        fi
      fi
    else
      fs_type=""
      while IFS='|' read -r state_uuid state_device state_mount state_persist state_fs; do
        if [[ "$state_uuid" == "$UUID_VALUE" && "$state_mount" == "$MOUNT_PATH" ]]; then
          DEVICE="$state_device"
          PERSIST_MODE="$state_persist"
          fs_type="$state_fs"
          record="${state_uuid}|${state_device}|${state_mount}|${state_persist}|${state_fs}"
          state_record_found=1
          break
        fi
      done <"$HOST_STATE_FILE"
    fi
  else
    remove_mode="managed"
    if [[ -t 0 && -t 1 ]]; then
      remove_mode="$(prompt_host_remove_mode)"
      if is_menu_back "$remove_mode"; then
        info "Remove host mount menu: back requested."
        return 0
      fi
    fi
    case "${remove_mode,,}" in
      managed)
        record="$(select_host_state_record)" || {
          [[ $? -eq 2 ]] && info "Remove host mount selection: back requested." && return 0
          return $?
        }
        IFS='|' read -r UUID_VALUE DEVICE MOUNT_PATH PERSIST_MODE fs_type <<<"$record"
        state_record_found=1
        ;;
      all)
        record="$(select_any_host_mount_record)" || {
          [[ $? -eq 2 ]] && info "Remove mounted disk selection: back requested." && return 0
          return $?
        }
        IFS='|' read -r UUID_VALUE DEVICE MOUNT_PATH fs_type <<<"$record"
        PERSIST_MODE="detected"
        if [[ -f "$HOST_STATE_FILE" && -s "$HOST_STATE_FILE" ]]; then
          while IFS='|' read -r state_uuid state_device state_mount state_persist state_fs; do
            if [[ "$state_mount" == "$MOUNT_PATH" ]]; then
              record="${state_uuid}|${state_device}|${state_mount}|${state_persist}|${state_fs}"
              state_record_found=1
              break
            fi
          done <"$HOST_STATE_FILE"
        fi
        ;;
      *)
        die "$EXIT_USAGE" "Unknown remove mode: $remove_mode"
        ;;
    esac
  fi

  [[ -n "$MOUNT_PATH" ]] || die "$EXIT_VALIDATION" "Host mount target path is empty."

  if [[ $FORCE_YES -ne 1 ]] && [[ -t 0 && -t 1 ]]; then
    prompt_yes_no "Remove host mount $MOUNT_PATH${UUID_VALUE:+ (UUID=$UUID_VALUE)}?" "n" || die "$EXIT_CANCELLED" "Rollback cancelled."
  fi

  unmount_bind_children_for_path "$MOUNT_PATH"
  if is_path_mounted "$MOUNT_PATH"; then
    run_cmd "umount '$MOUNT_PATH'" || true
    if is_path_mounted "$MOUNT_PATH"; then
      warn "Normal unmount failed for $MOUNT_PATH; trying lazy unmount."
      run_cmd "umount -l '$MOUNT_PATH'" || true
    fi
    if is_path_mounted "$MOUNT_PATH"; then
      die "$EXIT_VALIDATION" "Unable to unmount $MOUNT_PATH"
    fi
  else
    info "Mount path is not currently mounted: $MOUNT_PATH"
  fi

  if [[ -n "$UUID_VALUE" ]]; then
    remove_fstab_entry "$UUID_VALUE" "$MOUNT_PATH"
  else
    remove_fstab_entry_for_mount_path "$MOUNT_PATH"
  fi
  remove_fstab_bind_entries_for_path "$MOUNT_PATH"
  if [[ $state_record_found -eq 1 && -n "${record:-}" ]]; then
    state_remove_line "$HOST_STATE_FILE" "$record"
  fi
  info "Host rollback completed."
}

run_rollback_lxc() {
  local record remove_dir=0

  require_root
  require_proxmox
  ensure_state_dir
  require_commands pct awk grep

  if [[ -n "$CTID" && -n "$MP_SLOT" ]]; then
    MP_SLOT="$(normalize_mp_slot "$MP_SLOT")"
    while IFS='|' read -r state_ctid state_slot state_host state_container; do
      if [[ "$state_ctid" == "$CTID" && "$state_slot" == "$MP_SLOT" ]]; then
        HOST_PATH="$state_host"
        CONTAINER_PATH="$state_container"
        record="${state_ctid}|${state_slot}|${state_host}|${state_container}"
        break
      fi
    done <"$LXC_STATE_FILE"
  else
    record="$(select_lxc_state_record)" || {
      [[ $? -eq 2 ]] && info "Remove LXC bind selection: back requested." && return 0
      return $?
    }
    IFS='|' read -r CTID MP_SLOT HOST_PATH CONTAINER_PATH <<<"$record"
  fi

  [[ -n "${record:-}" ]] || die "$EXIT_VALIDATION" "Managed LXC bind record not found."

  if [[ $FORCE_YES -ne 1 ]] && [[ -t 0 && -t 1 ]]; then
    prompt_yes_no "Rollback LXC bind ${MP_SLOT} from CT ${CTID}?" "n" || die "$EXIT_CANCELLED" "Rollback cancelled."
  fi

  run_cmd "pct set '$CTID' -delete '$MP_SLOT'"
  state_remove_line "$LXC_STATE_FILE" "$record"

  if [[ $REMOVE_EMPTY_DIR -eq 1 ]]; then
    if [[ -d "$HOST_PATH" ]] && [[ -z "$(ls -A "$HOST_PATH" 2>/dev/null)" ]]; then
      run_cmd "rmdir '$HOST_PATH'"
      remove_dir=1
    else
      warn "Host path is not empty; skipping directory removal: $HOST_PATH"
    fi
  fi

  info "LXC rollback completed. removed_empty_dir=$remove_dir"
}

run_advanced_menu() {
  local choice
  local about_text=""

  about_text="Proxmox Disk Mount + LXC Helper
Version: ${SCRIPT_VERSION}
Author: ${AUTHOR_NAME}
Repository: ${AUTHOR_REFERENCE_URL}

This menu is intentionally minimal.
Main actions are available in the main menu.

GParted mode:
- CLI disk editor using native Proxmox/Linux tools
- Not the real GUI gparted app
- v2 placeholder: best-effort fs resize/check support later"

  if use_whiptail_ui; then
    while true; do
      choice="$(whiptail_menu_select "Advanced Menu" "Choose an action" \
        "1" "About" \
        "0" "Back")"
      is_menu_back "$choice" && return 0
      case "$choice" in
        1) whiptail_show_text "About" "$about_text" ;;
        0) return 0 ;;
        *) warn "Unknown option: $choice" ;;
      esac
    done
  fi

  while true; do
    cat <<EOF

---- Advanced Menu ----
1) About
0) Back
EOF
    read -r -p "Select an option [0-1]: " choice
    case "$choice" in
      1) printf '\n%s\n' "$about_text" ;;
      0|q|Q|back) return 0 ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
}

MIRROR_TITLE="Mirror Folder Manager"
MIRROR_FSTAB="/etc/fstab"
MIRROR_START_SRC="/mnt"
MIRROR_START_DST="/mnt"
MIRROR_TRY_UMOUNT_NOTE=""

mirror_require_tools() {
  require_root
  require_proxmox
  require_commands whiptail findmnt awk sed sort dirname basename mount umount grep
}

mirror_escape_sed() {
  echo "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

mirror_is_mounted() {
  # Exact mountpoint check (not parent filesystem).
  local target="$1"
  awk -v t="$target" '
    $5 == t { found=1; exit 0 }
    END { exit(found ? 0 : 1) }
  ' /proc/self/mountinfo
}

mirror_get_mount_source() {
  # Return exact mountpoint source from mountinfo.
  local target="$1"
  awk -v t="$target" '
    $5 == t {
      split($0, a, " - ");
      split(a[2], b, " ");
      print b[2];
      exit
    }
  ' /proc/self/mountinfo
}

mirror_active_relevant_mounts() {
  # Output: "<source>|<target>|BIND>"
  # Only real bind/rbind mounts are mirrors.
  findmnt -rn -o SOURCE,TARGET,OPTIONS 2>/dev/null | \
    awk '
      {
        src=$1; tgt=$2; opts=$3;
        is_bind = (opts ~ /(^|,)bind(,|$)/ || opts ~ /(^|,)rbind(,|$)/);
        if (is_bind) {
          print src "|" tgt "|BIND";
        }
      }'
}

mirror_fstab_bind_mounts() {
  # Output: "<source> <target>"
  awk '
    /^[[:space:]]*#/ {next}
    NF < 4 {next}
    {
      if ($3 == "none" && $4 ~ /(^|,)bind(,|$)/) {
        print $1 " " $2;
      }
    }
  ' "$MIRROR_FSTAB"
}

mirror_add_fstab_bind() {
  local src="$1" dst="$2"
  local src_re dst_re
  src_re="$(mirror_escape_sed "$src")"
  dst_re="$(mirror_escape_sed "$dst")"

  if grep -E "^[[:space:]]*${src_re}[[:space:]]+${dst_re}[[:space:]]+none[[:space:]]+.*bind" "$MIRROR_FSTAB" >/dev/null 2>&1; then
    return 0
  fi

  cp "$MIRROR_FSTAB" "${MIRROR_FSTAB}.bak.$(date +%F-%H%M%S)"
  printf '%s %s none bind,nofail 0 0\n' "$src" "$dst" >>"$MIRROR_FSTAB"
}

mirror_remove_fstab_bind_by_target() {
  local dst="$1"
  local tmp
  tmp="$(mktemp)"

  cp "$MIRROR_FSTAB" "${MIRROR_FSTAB}.bak.$(date +%F-%H%M%S)"
  awk -v d="$dst" '
    /^[[:space:]]*#/ {print; next}
    NF < 4 {print; next}
    {
      if ($2 == d && $3 == "none" && $4 ~ /(^|,)bind(,|$)/) next
      print
    }
  ' "$MIRROR_FSTAB" >"$tmp"
  cat "$tmp" >"$MIRROR_FSTAB"
  rm -f "$tmp"
}

mirror_try_unmount_target() {
  local dst="$1"
  local err
  MIRROR_TRY_UMOUNT_NOTE=""

  # 1) normal unmount
  if umount "$dst" 2>/tmp/mirror_umount_err.$$; then
    rm -f /tmp/mirror_umount_err.$$
    return 0
  fi

  err="$(cat /tmp/mirror_umount_err.$$ 2>/dev/null || true)"
  rm -f /tmp/mirror_umount_err.$$

  # Already unmounted between list refresh and action: treat as success.
  if echo "$err" | grep -qi "not mounted"; then
    MIRROR_TRY_UMOUNT_NOTE="Target is already not mounted."
    return 0
  fi

  # 2) recursive unmount for nested mounts
  if umount -R "$dst" >/dev/null 2>&1; then
    return 0
  fi

  # 3) lazy fallback if busy
  if whiptail --title "$MIRROR_TITLE" --yesno \
    "Normal unmount failed:\n$err\n\nTry lazy unmount (umount -l)?" \
    14 90; then
    if umount -l "$dst" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

mirror_browse_folder() {
  local current="$1"
  local choice

  [[ -z "$current" || "$current" != /* ]] && current="/"
  [[ ! -d "$current" ]] && current="/"

  while true; do
    local options=()
    options+=("SELECT" "[Use this folder] $current")
    [[ "$current" != "/" ]] && options+=("UP" "../")

    local children=()
    while IFS= read -r -d '' d; do
      children+=("$d")
    done < <(find "$current" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    for d in "${children[@]}"; do
      options+=("$d" "$(basename "$d")/")
    done

    choice="$(whiptail --title "$MIRROR_TITLE - Folder Browser" --menu \
      "Arrows: navigate | Enter: open | SELECT: choose current folder\n\nCurrent: $current" \
      24 100 14 \
      "${options[@]}" \
      3>&1 1>&2 2>&3)" || return "$EXIT_CANCELLED"

    case "$choice" in
      SELECT)
        echo "$current"
        return 0
        ;;
      UP)
        current="$(dirname "$current")"
        [[ -z "$current" ]] && current="/"
        ;;
      *)
        if [[ -d "$choice" ]]; then
          current="$choice"
        fi
        ;;
    esac
  done
}

mirror_create_wizard() {
  local src dst existing_src

  src="$(mirror_browse_folder "$MIRROR_START_SRC")" || return 0
  dst="$(mirror_browse_folder "$MIRROR_START_DST")" || return 0

  if [[ "$src" == "$dst" ]]; then
    whiptail --title "$MIRROR_TITLE" --msgbox "Source and target cannot be the same folder." 10 70
    return 0
  fi

  if ! whiptail --title "$MIRROR_TITLE" --yesno \
    "Create mirror?\n\nSource: $src\nTarget: $dst\n\nThis is a bind mount (live view, not copy)." \
    14 88; then
    return 0
  fi

  mkdir -p "$dst"

  if mirror_is_mounted "$dst"; then
    existing_src="$(mirror_get_mount_source "$dst")"
    if ! whiptail --title "$MIRROR_TITLE" --yesno \
      "Target is already mounted:\n$dst <- $existing_src\n\nReplace it with new source?\n$dst <- $src" \
      14 88; then
      return 0
    fi
    if ! mirror_try_unmount_target "$dst"; then
      whiptail --title "$MIRROR_TITLE" --msgbox "Failed to unmount existing target:\n$dst" 10 78
      return 0
    fi
  fi

  mount --bind "$src" "$dst"

  if whiptail --title "$MIRROR_TITLE" --yesno \
    "Mirror mounted successfully.\n\nAdd this mapping to /etc/fstab for autoload at boot?" \
    12 74; then
    mirror_add_fstab_bind "$src" "$dst"
    whiptail --title "$MIRROR_TITLE" --msgbox \
      "Done.\nMounted now and saved in /etc/fstab:\n$src -> $dst" 12 88
  else
    whiptail --title "$MIRROR_TITLE" --msgbox \
      "Done.\nMounted now (without /etc/fstab entry):\n$src -> $dst" 12 88
  fi
  return 0
}

mirror_unmount_existing_menu() {
  local rows=() options=() line src dst selected idx state subtype
  local seen_targets=""

  # Active relevant mounts
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    src="$(echo "$line" | awk -F'|' '{print $1}')"
    dst="$(echo "$line" | awk -F'|' '{print $2}')"
    state="$(echo "$line" | awk -F'|' '{print $3}')"
    rows+=("ACTIVE|$src|$dst|$state")
    options+=("${#rows[@]}" "[ACTIVE:$state] $dst  <-  $src")
    seen_targets+=$'\n'"$dst"
  done < <(mirror_active_relevant_mounts)

  # fstab-only entries (not currently active)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    src="${line%% *}"
    dst="${line#* }"
    if grep -Fxq "$dst" <<<"$seen_targets"; then
      continue
    fi
    rows+=("FSTAB|$src|$dst|BIND")
    options+=("${#rows[@]}" "[FSTAB]  $dst  <-  $src")
  done < <(mirror_fstab_bind_mounts)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    whiptail --title "$MIRROR_TITLE" --msgbox "No active or fstab bind mirrors found." 10 70
    return 0
  fi

  selected="$(whiptail --title "$MIRROR_TITLE - Unmount / Remove Mirror" --menu \
    "Select mirror entry:\n[ACTIVE] bind mounted now, [FSTAB] config only" \
    24 120 14 \
    "${options[@]}" \
    3>&1 1>&2 2>&3)" || return 0

  idx=$((selected - 1))
  [[ $idx -lt 0 || $idx -ge ${#rows[@]} ]] && {
    whiptail --title "$MIRROR_TITLE" --msgbox "Internal error: invalid selection." 10 60
    return 0
  }

  state="$(echo "${rows[$idx]}" | awk -F'|' '{print $1}')"
  src="$(echo "${rows[$idx]}" | awk -F'|' '{print $2}')"
  dst="$(echo "${rows[$idx]}" | awk -F'|' '{print $3}')"
  subtype="$(echo "${rows[$idx]}" | awk -F'|' '{print $4}')"

  if [[ "$state" == "ACTIVE" ]]; then
    if ! whiptail --title "$MIRROR_TITLE" --yesno \
      "Unmount this active mount?\nType: $subtype\n\n$src -> $dst" 12 88; then
      return 0
    fi

    if ! mirror_try_unmount_target "$dst"; then
      whiptail --title "$MIRROR_TITLE" --msgbox \
        "Failed to unmount:\n$dst\n\nCheck if path is busy and try again." 12 78
      return 0
    fi

    if [[ -n "$MIRROR_TRY_UMOUNT_NOTE" ]]; then
      whiptail --title "$MIRROR_TITLE" --msgbox \
        "$MIRROR_TRY_UMOUNT_NOTE\n\n$dst" 10 70
    fi
  fi

  if [[ "$subtype" == "BIND" ]]; then
    if whiptail --title "$MIRROR_TITLE" --yesno \
      "Remove matching /etc/fstab entry too?\n\n$src -> $dst" \
      12 88; then
      mirror_remove_fstab_bind_by_target "$dst"
      whiptail --title "$MIRROR_TITLE" --msgbox "Done.\nEntry removed from /etc/fstab." 10 70
    else
      if [[ "$state" == "ACTIVE" ]]; then
        whiptail --title "$MIRROR_TITLE" --msgbox "Done.\nUnmounted, fstab unchanged." 10 70
      else
        whiptail --title "$MIRROR_TITLE" --msgbox "No changes applied." 10 50
      fi
    fi
  else
    if [[ "$state" == "ACTIVE" ]]; then
      whiptail --title "$MIRROR_TITLE" --msgbox "Done.\nUnmounted active mount (non-bind)." 10 70
    else
      whiptail --title "$MIRROR_TITLE" --msgbox "No changes applied." 10 50
    fi
  fi
  return 0
}

mirror_list_existing() {
  local active cfg msg
  active="$(mirror_active_relevant_mounts || true)"
  cfg="$(mirror_fstab_bind_mounts || true)"

  msg="Active bind mirrors:\n"
  if [[ -n "$active" ]]; then
    msg+="$active"
  else
    msg+="(none)"
  fi

  msg+="\n\nConfigured in /etc/fstab:\n"
  if [[ -n "$cfg" ]]; then
    msg+="$cfg"
  else
    msg+="(none)"
  fi

  whiptail --title "$MIRROR_TITLE - Existing Mirrors" --msgbox "$msg" 26 110
}

mirror_show_help() {
  local msg
  msg="$(cat <<EOF
How this works:
1) Create mirror (wizard):
   - choose SOURCE folder (browser like mini-MC)
   - choose TARGET folder
   - mount bind SOURCE -> TARGET
   - optionally add to /etc/fstab for autoload

2) Unmount existing:
   - list includes ACTIVE mounts and FSTAB-only entries
   - ACTIVE:BIND  -> unmount + optional fstab cleanup
   - ACTIVE:MOUNT -> unmount regular mountpoint
   - FSTAB        -> remove stale bind entry without unmount

Important:
- Bind mount is a live mirror view, not copying files.
- Existing files in target become hidden while mount is active.
- Run this helper on Proxmox host as root.
EOF
)"
  whiptail --title "$MIRROR_TITLE - Help" --msgbox "$msg" 22 90
}

mirror_main_menu() {
  local choice
  while true; do
    choice="$(whiptail --title "$MIRROR_TITLE" --menu \
      "Choose action" \
      18 80 10 \
      "1" "Create mirror (wizard)" \
      "2" "Unmount existing mirror" \
      "3" "List existing mirrors" \
      "4" "Help" \
      "0" "Exit" \
      3>&1 1>&2 2>&3)" || return 0

    case "$choice" in
      1) mirror_create_wizard ;;
      2) mirror_unmount_existing_menu ;;
      3) mirror_list_existing ;;
      4) mirror_show_help ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

run_mirror_folder_tool() {
  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Mirror folder helper requires an interactive TTY."
  mirror_require_tools

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: start built-in mirror folder helper (no changes applied)."
    return 0
  fi

  info "Starting built-in mirror folder helper."
  mirror_main_menu
}

run_menu_action() {
  local title="$1"
  shift
  local rc=0
  local message=""

  ("$@") || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi

  if [[ "$rc" -eq "$EXIT_CANCELLED" ]]; then
    message="${title}: cancelled (code=${rc}). Returned to menu."
    warn "$message"
  else
    message="${title}: failed (code=${rc}). Returned to menu."
    error "$message"
  fi

  if use_whiptail_ui; then
    whiptail --title "Action Result" --msgbox "$message" 10 80 || true
  else
    printf '\n%s\n' "$message"
    read -r -p "Press Enter to continue..." _
  fi
  return 0
}

run_menu() {
  local choice

  [[ -t 0 && -t 1 ]] || die "$EXIT_USAGE" "Interactive menu requires a TTY. Use explicit commands instead."

  if use_whiptail_ui; then
    while true; do
      choice="$(whiptail_menu_select "Proxmox Disk Mount + LXC Helper" "Choose an action" \
        "1" "Host mount" \
        "2" "LXC attach" \
        "3" "GParted mode" \
        "4" "Mirror folder" \
        "5" "Status" \
        "6" "Remove mounting" \
        "7" "Advanced menu" \
        "8" "Help" \
        "0" "Exit")"
      is_menu_back "$choice" && info "Menu exit." && return 0
      case "$choice" in
        1) run_menu_action "Host mount" run_host_mount ;;
        2) run_menu_action "LXC attach" run_lxc_attach ;;
        3) run_menu_action "GParted mode" run_disk_editor ;;
        4) run_menu_action "Mirror folder" run_mirror_folder_tool ;;
        5) run_menu_action "Status" run_status ;;
        6)
          choice="$(whiptail_menu_select "Remove mounting" "Choose remove mode" \
            "host" "Remove host mount" \
            "lxc" "Remove LXC bind")"
          is_menu_back "$choice" && continue
          case "$choice" in
            host) run_menu_action "Remove host mount" run_rollback_host ;;
            lxc) run_menu_action "Remove LXC bind" run_rollback_lxc ;;
            *) ;;
          esac
          ;;
        7) run_menu_action "Advanced menu" run_advanced_menu ;;
        8) whiptail_show_text "Help" "$(usage)" ;;
        0) info "Menu exit."; return 0 ;;
        *) warn "Unknown option: $choice" ;;
      esac
    done
  fi

  while true; do
    cat <<EOF

==== Proxmox Disk Mount + LXC Helper ====
Author: ${AUTHOR_NAME}
Repo: ${AUTHOR_REFERENCE_URL}
Current defaults:
  chmod for new bind folders: ${CHMOD_VALUE}
  dry-run: ${DRY_RUN}

1) Host mount
2) LXC attach
3) GParted mode
4) Mirror folder
5) Status
6) Remove mounting
7) Advanced menu
8) Help
0) Exit
EOF
    read -r -p "Select an option [0-8]: " choice
    case "$choice" in
      1) run_menu_action "Host mount" run_host_mount ;;
      2) run_menu_action "LXC attach" run_lxc_attach ;;
      3) run_menu_action "GParted mode" run_disk_editor ;;
      4) run_menu_action "Mirror folder" run_mirror_folder_tool ;;
      5) run_menu_action "Status" run_status ;;
      6)
        if prompt_yes_no "Remove a host mount? (No = remove LXC bind)" "y"; then
          run_menu_action "Remove host mount" run_rollback_host
        else
          run_menu_action "Remove LXC bind" run_rollback_lxc
        fi
        ;;
      7) run_menu_action "Advanced menu" run_advanced_menu ;;
      8) usage ;;
      0|q|Q|exit|quit)
        info "Menu exit."
        return 0
        ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    COMMAND="menu"
  else
    case "$1" in
      menu|host-mount|lxc-attach|disk-editor|mirror-folder|status|remove-mount|remove-lxc|rollback-host|rollback-lxc|help)
        COMMAND="$1"
        shift
        ;;
      -h|--help)
        COMMAND="help"
        shift
        ;;
      --*)
        COMMAND="menu"
        ;;
      *)
        die "$EXIT_USAGE" "Unknown command: $1"
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        FORCE_YES=1
        shift
        ;;
      --device)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--device requires a value"
        DEVICE="$2"
        shift 2
        ;;
      --uuid)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--uuid requires a value"
        UUID_VALUE="$2"
        shift 2
        ;;
      --mount-path)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--mount-path requires a value"
        MOUNT_PATH="$2"
        shift 2
        ;;
      --persist)
        PERSIST_MODE="persistent"
        shift
        ;;
      --ctid)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--ctid requires a value"
        CTID="$2"
        shift 2
        ;;
      --host-path)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--host-path requires a value"
        HOST_PATH="$2"
        shift 2
        ;;
      --container-path)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--container-path requires a value"
        CONTAINER_PATH="$2"
        shift 2
        ;;
      --mp-slot)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--mp-slot requires a value"
        MP_SLOT="$2"
        shift 2
        ;;
      --chmod)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--chmod requires a value"
        CHMOD_VALUE="$2"
        shift 2
        ;;
      --chown)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "--chown requires a value"
        CHOWN_VALUE="$2"
        shift 2
        ;;
      --remove-empty-dir)
        REMOVE_EMPTY_DIR=1
        shift
        ;;
      -h|--help)
        COMMAND="help"
        shift
        ;;
      *)
        die "$EXIT_USAGE" "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -n "$PERSIST_MODE" && "$PERSIST_MODE" != "persistent" && "$PERSIST_MODE" != "temporary" ]]; then
    die "$EXIT_USAGE" "Invalid persistence mode: $PERSIST_MODE"
  fi
}

main() {
  parse_args "$@"

  if [[ "$COMMAND" == "help" ]]; then
    usage
    return 0
  fi

  info "$SCRIPT_NAME v$SCRIPT_VERSION command=$COMMAND dry_run=$DRY_RUN"
  case "$COMMAND" in
    menu)
      run_menu
      ;;
    host-mount)
      run_host_mount
      ;;
    lxc-attach)
      run_lxc_attach
      ;;
    disk-editor)
      run_disk_editor
      ;;
    mirror-folder)
      run_mirror_folder_tool
      ;;
    status)
      run_status
      ;;
    remove-mount|rollback-host)
      run_rollback_host
      ;;
    remove-lxc|rollback-lxc)
      run_rollback_lxc
      ;;
    *)
      die "$EXIT_USAGE" "Unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
