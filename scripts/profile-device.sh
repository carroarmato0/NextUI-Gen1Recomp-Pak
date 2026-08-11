#!/usr/bin/env bash
# Sample what the device is actually doing while the game runs, over ADB.
#
# "It's slow" has at least three different causes here and they need opposite
# fixes, so guessing is expensive. This tells them apart:
#
#   GPU-bound      GPU utilisation pinned near 100%, CPU below its ceiling.
#                  -> lower the voxel mod's quality ladder, or cap FPS at 30 for
#                     consistent pacing rather than a fluctuating 40-60.
#
#   CPU-bound      All cores at max, GPU well under 100%.
#                  -> PERFORMANCE tier, fewer entities, less void fill.
#
#   Swap thrashing pswpin/pswpout climbing while sampling, love's VmSwap growing.
#                  -> memory pressure, not rendering. More swap will not make it
#                     fast, it only stops the OOM kill; the stalls are the disk.
#
# The last one matters most: on a 1 GB device with the voxel mod near 750 MB it is
# entirely possible to be "slow" for reasons no graphics setting will fix.
#
# Usage:
#   scripts/profile-device.sh [seconds]      (default 60)
#
# Start it, then play. It prints a sample every 2s and a verdict at the end.
set -uo pipefail

DURATION="${1:-60}"
INTERVAL=2

command -v adb >/dev/null || { echo "adb is required" >&2; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "no device over adb" >&2; exit 2; }

printf '\033[1mSampling for %ss. Play the game now — move around the overworld.\033[0m\n\n' "$DURATION"

# One shell per sample keeps the parsing simple; the cost is negligible next to
# what we are measuring.
read -r SWPIN0 SWPOUT0 <<EOF
$(adb shell 'awk "/^pswpin/{i=\$2} /^pswpout/{o=\$2} END{print i, o}" /proc/vmstat' 2>/dev/null | tr -d '\r')
EOF

printf '%-8s %-6s %-9s %-9s %-8s %-9s %s\n' TIME GPU% CPU-MHz RSS-MB SWAP-MB MEMAVAIL SWAPPING
printf '%.0s-' {1..72}; printf '\n'

gpu_sum=0; gpu_n=0; gpu_max=0
cpu_max_seen=0
swap_events=0
rss_max=0
elapsed=0

while [ "$elapsed" -lt "$DURATION" ]; do
    sample="$(adb shell '
P=$(pidof love.aarch64)
GPU=$(sed -n "s/^GPU Utilisation:[[:space:]]*\([0-9]*\)%.*/\1/p" /sys/kernel/debug/pvr/status 2>/dev/null | head -1)
CPU=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
if [ -n "$P" ]; then
  RSS=$(awk "/^VmRSS/{print \$2}" /proc/$P/status 2>/dev/null)
  SWP=$(awk "/^VmSwap/{print \$2}" /proc/$P/status 2>/dev/null)
else
  RSS=0; SWP=0
fi
AVAIL=$(awk "/^MemAvailable/{print \$2}" /proc/meminfo)
IN=$(awk "/^pswpin/{print \$2}" /proc/vmstat)
OUT=$(awk "/^pswpout/{print \$2}" /proc/vmstat)
echo "${GPU:-0} ${CPU:-0} ${RSS:-0} ${SWP:-0} ${AVAIL:-0} ${IN:-0} ${OUT:-0} ${P:-none}"
' 2>/dev/null | tr -d '\r')"

    set -- $sample
    gpu="${1:-0}"; cpu="${2:-0}"; rss="${3:-0}"; swp="${4:-0}"
    avail="${5:-0}"; swin="${6:-0}"; swout="${7:-0}"; pid="${8:-none}"

    if [ "$pid" = none ]; then
        printf '\033[1;33m%-8s love is not running — start the game\033[0m\n' "$(date +%H:%M:%S)"
        sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL)); continue
    fi

    d_in=$((swin - SWPIN0)); d_out=$((swout - SWPOUT0))
    SWPIN0="$swin"; SWPOUT0="$swout"
    thrash=""
    if [ "$d_in" -gt 0 ] || [ "$d_out" -gt 0 ]; then
        thrash="in:$d_in out:$d_out"
        swap_events=$((swap_events + 1))
    fi

    gpu_sum=$((gpu_sum + gpu)); gpu_n=$((gpu_n + 1))
    [ "$gpu" -gt "$gpu_max" ] && gpu_max="$gpu"
    [ "$cpu" -gt "$cpu_max_seen" ] && cpu_max_seen="$cpu"
    [ "$rss" -gt "$rss_max" ] && rss_max="$rss"

    printf '%-8s %-6s %-9s %-9s %-8s %-9s %s\n' \
        "$(date +%H:%M:%S)" "$gpu" "$((cpu / 1000))" \
        "$((rss / 1024))" "$((swp / 1024))" "$((avail / 1024))" "$thrash"

    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

CEIL="$(adb shell 'cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq' 2>/dev/null | tr -d '\r')"
gpu_avg=0; [ "$gpu_n" -gt 0 ] && gpu_avg=$((gpu_sum / gpu_n))

printf '\n\033[1mSummary\033[0m\n'
printf '  GPU utilisation   avg %s%%  peak %s%%\n' "$gpu_avg" "$gpu_max"
printf '  CPU peak          %s MHz (ceiling %s MHz)\n' "$((cpu_max_seen / 1000))" "$((${CEIL:-0} / 1000))"
printf '  love peak RSS     %s MB\n' "$((rss_max / 1024))"
printf '  swap activity     %s of %s samples\n' "$swap_events" "$gpu_n"

printf '\n\033[1mVerdict\033[0m\n'
if [ "$swap_events" -gt $((gpu_n / 4)) ]; then
    echo "  SWAP THRASHING. Stalls are disk waits, not rendering. Graphics settings"
    echo "  will not fix this; reduce memory use (disable the voxel mod, or other"
    echo "  background paks) — more swap only prevents the OOM kill."
elif [ "$gpu_avg" -ge 85 ]; then
    echo "  GPU-BOUND. Lower the voxel mod's quality in OPTIONS, and consider capping"
    echo "  FPS at 30: a steady 30 reads far better than a fluctuating 40-60."
elif [ "$cpu_max_seen" -ge $(( ${CEIL:-1} - 50000 )) ] && [ "$gpu_avg" -lt 70 ]; then
    echo "  CPU-BOUND. Try PERFORMANCE tier and a cheaper VOID FILL; the CPU is at its"
    echo "  ceiling already, so there is no clock headroom left to take."
else
    echo "  No single resource is saturated. If it still feels bad, the cost is likely"
    echo "  frame pacing rather than throughput — try capping FPS at 30."
fi
echo
echo "  Record these numbers in the README's voxel section rather than adjectives."
