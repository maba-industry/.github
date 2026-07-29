#!/usr/bin/env bash
#
# labels.txt 에 정의된 공통 라벨을 조직 저장소에 반영합니다.
#
# GitHub는 조직 전체에 라벨을 소급 적용하는 기능을 제공하지 않습니다.
# (조직 설정의 기본 라벨은 '새로 만드는' 저장소에만 적용됩니다)
# 그래서 기존 저장소에는 이 스크립트로 일괄 반영합니다.
#
# 기본 동작은 미리보기(dry-run)이며, --apply 없이는 아무것도 변경하지 않습니다.
# bash 3.2 (macOS 기본) 에서 동작합니다.

set -eo pipefail

ORG="maba-industry"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABELS_FILE="$ROOT/labels.txt"

usage() {
  cat <<'EOF'
사용법: sync-labels.sh [저장소...] [옵션]

  저장소        maba-industry/foo 또는 foo (조직명 생략 가능)
  --all         조직의 모든 저장소 (아카이브 제외)
  --apply       실제로 반영 (생략하면 미리보기만)
  --prune       labels.txt 에 없는 라벨을 삭제 — 해당 라벨이 붙은
                이슈·PR에서 라벨이 사라집니다. 먼저 미리보기로 확인하세요.
  -h, --help    이 도움말

예시:
  ./scripts/sync-labels.sh --all                     # 전체 저장소 미리보기
  ./scripts/sync-labels.sh --all --apply             # 전체 저장소 반영
  ./scripts/sync-labels.sh maba-decal-shop --apply   # 특정 저장소만
EOF
}

apply=false
prune=false
all=false
repos=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=true ;;
    --prune) prune=true ;;
    --all)   all=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
    *)  case "$1" in
          */*) repos="$repos$1"$'\n' ;;
          *)   repos="$repos$ORG/$1"$'\n' ;;
        esac ;;
  esac
  shift
done

command -v gh >/dev/null || { echo "gh CLI가 필요합니다: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh 로그인이 필요합니다: gh auth login" >&2; exit 1; }
[ -f "$LABELS_FILE" ] || { echo "라벨 정의 파일이 없습니다: $LABELS_FILE" >&2; exit 1; }

# --- 대상 저장소 ------------------------------------------------------------
if $all; then
  repos="$(gh repo list "$ORG" --limit 500 --no-archived \
             --json nameWithOwner -q '.[].nameWithOwner')"$'\n'
elif [ -z "$repos" ]; then
  echo "대상 저장소를 지정하거나 --all 을 사용하세요." >&2
  usage >&2
  exit 1
fi

repo_count=$(printf '%s' "$repos" | grep -c . || true)

# --- 라벨 정의 --------------------------------------------------------------
names=(); colors=(); descs=()
while IFS='|' read -r name color desc; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -z "$color" ] && { echo "색상 누락: $name" >&2; exit 1; }
  names[${#names[@]}]="$name"
  colors[${#colors[@]}]="$color"
  descs[${#descs[@]}]="$desc"
done < "$LABELS_FILE"

[ ${#names[@]} -gt 0 ] || { echo "라벨 정의가 비어 있습니다." >&2; exit 1; }

mode="미리보기 — 변경 없음"
$apply && mode="적용 (--apply)"
$prune && mode="$mode + 미정의 라벨 삭제 (--prune)"

echo "조직   : $ORG"
echo "라벨   : ${#names[@]}개  ($LABELS_FILE)"
echo "저장소 : ${repo_count}개"
echo "모드   : $mode"
echo

# --- 반영 -------------------------------------------------------------------
failed=""
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "▸ $repo"

  i=0
  while [ $i -lt ${#names[@]} ]; do
    if $apply; then
      if gh label create "${names[$i]}" \
           --color "${colors[$i]}" \
           --description "${descs[$i]}" \
           --force --repo "$repo" >/dev/null 2>&1; then
        echo "    ✓ ${names[$i]}"
      else
        echo "    ✗ ${names[$i]}  (실패)"
        failed="$failed  $repo → ${names[$i]}"$'\n'
      fi
    else
      echo "    · ${names[$i]}"
    fi
    i=$((i + 1))
  done

  if $prune; then
    existing="$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
    while IFS= read -r have; do
      [ -z "$have" ] && continue
      keep=false
      for want in "${names[@]}"; do
        [ "$have" = "$want" ] && { keep=true; break; }
      done
      $keep && continue
      if $apply; then
        if gh label delete "$have" --yes --repo "$repo" >/dev/null 2>&1; then
          echo "    − $have  (삭제)"
        else
          echo "    ✗ $have  (삭제 실패)"
          failed="$failed  $repo → $have (삭제)"$'\n'
        fi
      else
        echo "    − $have  (삭제 대상)"
      fi
    done <<EOF
$existing
EOF
  fi
  echo
done <<EOF
$repos
EOF

if [ -n "$failed" ]; then
  echo "실패한 항목:"
  printf '%s' "$failed"
  exit 1
fi

$apply || echo "미리보기였습니다. 실제로 반영하려면 --apply 를 붙여 다시 실행하세요."
