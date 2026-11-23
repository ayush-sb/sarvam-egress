#!/usr/bin/env bash
# Benchmark mode: keep everything else off the measured cores.
#
#   sudo ./bench-mode.sh on     performance governor and turbo off (where the machine allows it), perf
#                               and syscall tracepoints usable without root, the SMT siblings of the
#                               frontend and worker cores offline, all other processes and device
#                               interrupts moved to the housekeeping cores
#   sudo ./bench-mode.sh off    undo all of it (a reboot also does)
#   ./bench-mode.sh status      show the current state
#
# The benchmark scripts then pin the frontend, worker and client to their own cores (config/cpus.local.sh).
set -u
cd "$(dirname "$0")"
source scripts/env.sh
cpu=/sys/devices/system/cpu
state=/run/sarvam-bench-state      # what "on" changed, so that "off" can restore it

status() {
    echo "benchmark mode:   $([ -d $state ] && echo on || echo off)"
    echo "online cpus:      $(cat $cpu/online)"
    echo "governors:        $(cat $cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | xargs)"
    echo "turbo:            $(if [ -e $cpu/intel_pstate/no_turbo ]; then [ "$(cat $cpu/intel_pstate/no_turbo)" = 1 ] && echo off || echo on
                              elif [ -e $cpu/cpufreq/boost ]; then [ "$(cat $cpu/cpufreq/boost)" = 0 ] && echo off || echo on
                              else echo "not controllable on this machine"; fi)"
    echo "perf for users:   $([ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 0 ] && [ -r /sys/kernel/tracing/events ] && echo yes || echo no)"
    echo "cores:            frontend $FRONTEND_CPUS, worker $WORKER_CPUS, client $CLIENT_CPUS, everything else $HOUSEKEEPING_CPUS"
}

case ${1:-status} in
    on)
        [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
        if [ -d $state ]; then echo "benchmark mode is already on"; status; exit 0; fi
        mkdir -p $state/irq
        cat $cpu/cpu0/cpufreq/scaling_governor > $state/governor 2>/dev/null
        cat $cpu/intel_pstate/no_turbo > $state/no_turbo 2>/dev/null
        cat $cpu/cpufreq/boost > $state/boost 2>/dev/null
        echo "$OFFLINE_CPUS" > $state/offline
        cat /proc/sys/kernel/kptr_restrict > $state/kptr_restrict
        cat /proc/sys/kernel/perf_event_paranoid > $state/perf_event_paranoid
        systemctl is-active irqbalance > $state/irqbalance
        # Steady clock speed. Absent in most virtual machines; each control is optional.
        for g in $cpu/cpu*/cpufreq/scaling_governor; do [ -e "$g" ] && echo performance > "$g" 2>/dev/null; done
        if [ -e $cpu/intel_pstate/no_turbo ]; then echo 1 > $cpu/intel_pstate/no_turbo
        elif [ -e $cpu/cpufreq/boost ]; then echo 0 > $cpu/cpufreq/boost; fi
        # perf record, kernel symbols and syscall tracepoints for a normal user.
        echo 0 > /proc/sys/kernel/kptr_restrict
        echo -1 > /proc/sys/kernel/perf_event_paranoid
        mount -o remount,mode=755 /sys/kernel/tracing
        chmod -R o+rX /sys/kernel/tracing/events/syscalls
        for c in $OFFLINE_CPUS; do echo 0 > $cpu/cpu$c/online; done
        # Device interrupts and every existing process to the housekeeping cores (some refuse; that is fine).
        [ "$(cat $state/irqbalance)" = active ] && systemctl stop irqbalance
        for irq in /proc/irq/[0-9]*; do
            cat "$irq/smp_affinity_list" > "$state/irq/${irq##*/}" 2>/dev/null
            echo "$HOUSEKEEPING_CPUS" > "$irq/smp_affinity_list" 2>/dev/null
        done
        for p in /proc/[0-9]*; do taskset -a -c -p "$HOUSEKEEPING_CPUS" "${p##*/}" > /dev/null 2>&1; done
        status ;;
    off)
        [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
        [ -d $state ] || { echo "benchmark mode is already off"; exit 0; }
        for c in $(cat $state/offline); do echo 1 > $cpu/cpu$c/online; done
        for p in /proc/[0-9]*; do taskset -a -c -p "$(cat $cpu/online)" "${p##*/}" > /dev/null 2>&1; done
        for f in $state/irq/*; do cat "$f" > "/proc/irq/${f##*/}/smp_affinity_list" 2>/dev/null; done
        [ "$(cat $state/irqbalance)" = active ] && systemctl start irqbalance
        [ -s $state/governor ] && for g in $cpu/cpu*/cpufreq/scaling_governor; do cat $state/governor > "$g" 2>/dev/null; done
        [ -s $state/no_turbo ] && cat $state/no_turbo > $cpu/intel_pstate/no_turbo
        [ -s $state/boost ] && cat $state/boost > $cpu/cpufreq/boost
        cat $state/kptr_restrict > /proc/sys/kernel/kptr_restrict
        cat $state/perf_event_paranoid > /proc/sys/kernel/perf_event_paranoid
        mount -o remount,mode=700 /sys/kernel/tracing
        rm -rf $state
        status ;;
    status) status ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
esac
