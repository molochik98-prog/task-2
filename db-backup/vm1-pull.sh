#!/bin/bash
# ВМ-2: pull копий Redis и MinIO с ВМ-1 по SSH (ключ на ВМ-1 только на чтение: rrsync -ro).
# Для каждой системы: скачать -> сверить SHA256SUMS -> положить копию -> ротация -> метка успеха.
# Метка .last-success = время создания копии на ВМ-1 (файл COMPLETE), а не время запуска pull:
# backup-watch поднимет тревогу и когда сломан pull, и когда ВМ-1 сама перестала делать бэкапы.
# ВМ-1 выключена или недоступна: не сбой запуска (ночью ВМ выключены), свежесть проверяет backup-watch.
# Функция, вызванная через && / ||, работает без set -e, поэтому важные шаги в ней проверены явно.
set -euo pipefail
umask 077

HOST=${PULL_HOST:-192.168.64.3}
REMOTE="backup-pull@$HOST"
DEST=/var/backups/vm1
KEEP=7
KEY=/var/lib/vm1-pull/.ssh/id_ed25519
KNOWN=/var/lib/vm1-pull/.ssh/known_hosts
SSH_CMD="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN"

fetch() { rsync -rt --timeout=60 --chmod=D700,F600 -e "$SSH_CMD" "$@"; }
trap 'rm -rf "$DEST"/*/.incoming.*' EXIT

# Коды возврата: 0 успех, 3 ВМ-1 недоступна, 1 сбой
pull_one() {
  local sys="$1" dir="$DEST/$1" tmp stamp name rc rc2 n_files n_sums sums_ok attempt ok=0
  install -d -m 700 "$dir" || return 1
  rm -rf "$dir"/.incoming.*
  tmp=$(mktemp -d "$dir/.incoming.XXXXXX") || return 1

  # 0. какая копия выдана на ВМ-1 сейчас (один маленький файл)
  fetch "$REMOTE:$sys/latest/COMPLETE" "$tmp/COMPLETE.now" && rc=0 || rc=$?
  if [[ $rc -eq 255 || $rc -eq 10 ]]; then
    echo "WARN: $sys: ВМ-1 недоступна по SSH (rsync rc=$rc), копия не обновлена"
    return 3
  fi
  [[ $rc -eq 0 ]] || { echo "FAIL: $sys: не прочитан COMPLETE на ВМ-1 (rsync rc=$rc)" >&2; return 1; }
  stamp=$(cat "$tmp/COMPLETE.now")
  [[ "$stamp" =~ ^[0-9]+$ ]] || { echo "FAIL: $sys: COMPLETE не число: '$stamp'" >&2; return 1; }
  name=$(date -u -d "@$stamp" +%Y%m%d-%H%M%S)
  if [[ -d "$dir/$name" ]]; then
    echo "$sys: копия $name уже есть, скачивание не нужно"
    echo "$stamp" > "$dir/.last-success" || return 1
    return 0
  fi

  # 1. скачать и сверить (до 3 попыток: latest на ВМ-1 может смениться посреди копирования)
  for attempt in 1 2 3; do
    rm -rf "$tmp/data" "$tmp/COMPLETE.chk"
    fetch "$REMOTE:$sys/latest/" "$tmp/data/" && rc=0 || rc=$?
    if [[ $rc -eq 0 && -f "$tmp/data/COMPLETE" && -f "$tmp/data/SHA256SUMS" ]]; then
      stamp=$(cat "$tmp/data/COMPLETE")
      n_files=$(find "$tmp/data" -type f ! -name SHA256SUMS ! -name COMPLETE | wc -l)
      n_sums=$(wc -l < "$tmp/data/SHA256SUMS")
      sums_ok=1
      if [[ "$n_sums" -gt 0 ]]; then
        (cd "$tmp/data" && sha256sum -c --quiet SHA256SUMS) || sums_ok=0
      fi
      fetch "$REMOTE:$sys/latest/COMPLETE" "$tmp/COMPLETE.chk" && rc2=0 || rc2=$?
      if [[ "$stamp" =~ ^[0-9]+$ && "$n_files" -eq "$n_sums" && $sums_ok -eq 1 && $rc2 -eq 0 && "$(cat "$tmp/COMPLETE.chk")" == "$stamp" ]]; then
        ok=1; break
      fi
    fi
    echo "попытка $attempt/3 ($sys): rsync rc=$rc, копия не прошла сверку или latest сменился, повтор через 5 с" >&2
    sleep 5
  done
  [[ $ok -eq 1 ]] || { echo "FAIL: $sys: нет сверенной копии за 3 попытки" >&2; return 1; }

  # 2. положить копию
  name=$(date -u -d "@$stamp" +%Y%m%d-%H%M%S)
  if [[ -d "$dir/$name" ]]; then
    echo "$sys: копия $name уже есть"
  else
    mv "$tmp/data" "$dir/$name" || return 1
    echo "$sys: сохранена копия $name ($(du -sb "$dir/$name" | cut -f1) байт, сверена по SHA256SUMS)"
  fi
  rm -rf "$tmp"

  # 3. ротация только после того, как новая копия на месте
  ls -1d "$dir"/[0-9]*-[0-9]* | sort | head -n -"$KEEP" | xargs -r rm -rf -- || return 1
  # 4. метка успеха последней
  echo "$stamp" > "$dir/.last-success" || return 1
  return 0
}

status=0
for sys in redis minio; do
  pull_one "$sys" && rc=0 || rc=$?
  case $rc in
    0) ;;
    3) echo "($sys: недоступность не считается сбоем, свежесть копии проверяет backup-watch)" ;;
    *) status=1 ;;
  esac
done
exit $status
