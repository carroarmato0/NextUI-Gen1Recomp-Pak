#!/usr/bin/env bash
# Sample what the device is actually doing while the game runs, over ADB.
#
# "It's slow" has three causes here that need opposite fixes, so guessing is
# expensive:
#
#   GPU-bound      GPU utilisation near 100% while rendering.
#                  -> lower the voxel mod's quality, or cap FPS at 30 for steady
#                     pacing instead of a fluctuating 40-60.
#
#   CPU-bound      Real CPU utilisation near 100% with the GPU well under.
#                  -> PERFORMANCE tier, cheaper VOID FILL.
#
#   Swap thrashing pswpin/pswpout climbing, love's VmSwap growing.
#                  -> memory pressure, not rendering. No graphics setting helps;
#                     more swap only prevents the OOM kill.
#
# Two mistakes this script made on its first real run, now fixed, because both
# produce confidently wrong advice:
#
#   1. It read scaling_cur_freq as CPU load. schedutil parks the clock at the
#      ceiling regardless of utilisation, so "2000 MHz" looked like saturation
#      when the CPU was mostly idle. It now differences /proc/stat jiffies for
#      true utilisation, and love's own utime+stime separately.
#
#   2. It averaged GPU across the whole run. Time spent in menus at 6-10% pulled
#      a genuinely GPU-bound session down to a 42% mean and it concluded
#      "CPU-bound". The verdict now uses the 75th percentile of samples taken
#      while the game was actually busy.
#
# Usage:
#   scripts/profile-device.sh [seconds]      (default 60)
#
# Start it, then play. Prints a sample every 2s and a verdict at the end.
set -uo pipefail

DURATION="${1:-60}"
INTERVAL=2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v adb >/dev/null || { echo "adb is required" >&2; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "no device over adb" >&2; exit 2; }

NCPU="$(adb shell 'grep -c ^processor /proc/cpuinfo' 2>/dev/null | tr -d '\r')"
NCPU="${NCPU:-4}"
CEIL="$(adb shell 'cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq' 2>/dev/null | tr -d '\r')"
CEIL="${CEIL:-0}"

printf '\033[1mSampling for %ss. Play the game now — move around the overworld.\033[0m\n' "$DURATION"
printf 'Cores: %s, CPU ceiling: %s MHz\n\n' "$NCPU" "$((CEIL / 1000))"

printf '%-9s %-5s %-7s %-8s %-8s %-8s %-8s %s\n' \
    TIME GPU% SYSCPU LOVECPU CPU-MHz RSS-MB AVAIL-MB SWAPPING
printf '%.0s-' $(seq 1 74); printf '\n'

TOT0=0; IDLE0=0; PJ0=0; SWIN0=0; SWOUT0=0
gpu_max=0; rss_max=0; syscpu_max=0; lovecpu_max=0
swap_events=0; n=0; busy_n=0
elapsed=0

while [ "$elapsed" -lt "$DURATION" ]; do
    sample="$(adb shell '
P=$(pidof love.aarch64)
GPU=$(sed -n "s/^GPU Utilisation:[[:space:]]*\([0-9]*\)%.*/\1/p" /sys/kernel/debug/pvr/status 2>/dev/null | head -1)
CPU=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
RSS=0; SWP=0; PJ=0
if [ -n "$P" ]; then
  RSS=$(awk "/^VmRSS/{print \$2}" /proc/$P/status 2>/dev/null)
  SWP=$(awk "/^VmSwap/{print \$2}" /proc/$P/status 2>/dev/null)
  PJ=$(awk "{print \$14+\$15}" /proc/$P/stat 2>/dev/null)
fi
AVAIL=$(awk "/^MemAvailable/{print \$2}" /proc/meminfo)
set -- $(awk "/^cpu /{i=\$5+\$6; t=0; for(j=2;j<=NF;j++) t+=\$j; print t, i}" /proc/stat)
IN=$(awk "/^pswpin/{print \$2}" /proc/vmstat)
OUT=$(awk "/^pswpout/{print \$2}" /proc/vmstat)
echo "${GPU:-0} ${CPU:-0} ${RSS:-0} ${SWP:-0} ${AVAIL:-0} ${IN:-0} ${OUT:-0} ${1:-0} ${2:-0} ${PJ:-0} ${P:-none}"
' 2>/dev/null | tr -d '\r')"

    # shellcheck disable=SC2086
    set -- $sample
    gpu="${1:-0}"; cpu="${2:-0}"; rss="${3:-0}"; swp="${4:-0}"; avail="${5:-0}"
    swin="${6:-0}"; swout="${7:-0}"; tot="${8:-0}"; idle="${9:-0}"; pj="${10:-0}"
    pid="${11:-none}"

    if [ "$pid" = none ]; then
        printf '\033[1;33m%-9s love is not running — start the game\033[0m\n' "$(date +%H:%M:%S)"
        TOT0=0
        sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL)); continue
    fi

    syscpu=0; lovecpu=0
    if [ "$TOT0" -gt 0 ] && [ "$tot" -gt "$TOT0" ]; then
        dt=$((tot - TOT0)); di=$((idle - IDLE0))
        syscpu=$(( (dt - di) * 100 / dt ))
        # Normalised to a single core: >100% means genuinely multi-threaded.
        lovecpu=$(( (pj - PJ0) * 100 * NCPU / dt ))
    fi
    TOT0="$tot"; IDLE0="$idle"; PJ0="$pj"

    thrash=""
    if [ "$SWIN0" -gt 0 ]; then
        d_in=$((swin - SWIN0)); d_out=$((swout - SWOUT0))
        if [ "$d_in" -gt 0 ] || [ "$d_out" -gt 0 ]; then
            thrash="in:$d_in out:$d_out"
            swap_events=$((swap_events + 1))
        fi
    fi
    SWIN0="$swin"; SWOUT0="$swout"

    n=$((n + 1))
    [ "$gpu" -gt "$gpu_max" ] && gpu_max="$gpu"
    [ "$rss" -gt "$rss_max" ] && rss_max="$rss"
    [ "$syscpu" -gt "$syscpu_max" ] && syscpu_max="$syscpu"
    [ "$lovecpu" -gt "$lovecpu_max" ] && lovecpu_max="$lovecpu"

    # "Busy" = the game is doing real work, not sitting in a menu. Only these
    # samples inform the verdict; menu idle is what skewed the first run.
    if [ "$gpu" -ge 20 ] || [ "$lovecpu" -ge 50 ]; then
        busy_n=$((busy_n + 1))
        echo "$gpu" >> "$TMP/gpu_busy"
        echo "$syscpu" >> "$TMP/sys_busy"
    fi

    printf '%-9s %-5s %-7s %-8s %-8s %-8s %-8s %s\n' \
        "$(date +%H:%M:%S)" "$gpu" "${syscpu}%" "${lovecpu}%" "$((cpu / 1000))" \
        "$((rss / 1024))" "$((avail / 1024))" "$thrash"

    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

pctl() { # pctl <file> <percentile>
    [ -s "$1" ] || { echo 0; return; }
    local c i
    c=$(wc -l < "$1")
    i=$(( c * $2 / 100 )); [ "$i" -lt 1 ] && i=1
    sort -n "$1" | sed -n "${i}p"
}

gpu_p75=$(pctl "$TMP/gpu_busy" 75)
gpu_med=$(pctl "$TMP/gpu_busy" 50)
sys_p75=$(pctl "$TMP/sys_busy" 75)

printf '\n\033[1mSummary\033[0m\n'
printf '  samples           %s total, %s while busy\n' "$n" "$busy_n"
printf '  GPU (busy only)   median %s%%  p75 %s%%  peak %s%%\n' "$gpu_med" "$gpu_p75" "$gpu_max"
printf '  System CPU        p75 %s%%  peak %s%%\n' "$sys_p75" "$syscpu_max"
printf '  love CPU          peak %s%% (of one core; %s cores available)\n' "$lovecpu_max" "$NCPU"
printf '  love peak RSS     %s MB\n' "$((rss_max / 1024))"
printf '  swap activity     %s of %s samples\n' "$swap_events" "$n"

printf '\n\033[1mVerdict\033[0m\n'
if [ "$busy_n" -lt 3 ]; then
    echo "  Not enough busy samples. Run again and play during the whole window."
elif [ "$swap_events" -gt $((n / 4)) ]; then
    echo "  SWAP THRASHING. The stalls are disk waits, not rendering, and no graphics"
    echo "  setting will touch them. Reduce memory use; more swap only prevents the"
    echo "  OOM kill, it does not make paging fast."
elif [ "$gpu_p75" -ge 85 ]; then
    echo "  GPU-BOUND. The GPU is saturated while rendering and there is no userspace"
    echo "  clock control on this PowerVR part, so the only lever is drawing less:"
    echo "    - cap MAX FPS at 30 (steady 30 reads better than a swinging 40-60)"
    echo "    - lower the voxel mod's quality in OPTIONS"
    echo "    - cheaper VOID FILL"
elif [ "$sys_p75" -ge 85 ]; then
    echo "  CPU-BOUND. Try the PERFORMANCE tier and a cheaper VOID FILL."
else
    echo "  Neither GPU nor CPU is saturated, so the cost is likely frame pacing"
    echo "  rather than throughput. Try capping MAX FPS at 30."
fi
echo
echo "  Put these numbers in the README's voxel section rather than adjectives."
