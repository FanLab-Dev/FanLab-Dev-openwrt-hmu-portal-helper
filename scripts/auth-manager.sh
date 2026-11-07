#!/bin/sh
# auth-manager v2
#   wan  (WAN口)  = 电脑名额  <- 所有"有线"设备
#   lan4 (LAN口)  = 移动端名额 <- 所有"无线"设备
# 两条都认证 -> mwan3 聚合
# 有任一条未认证 -> 摘出 mwan3，按有线/无线把流量导到对应线，让门户自动弹

LAN=10.0.0.0/24
GW=10.66.0.1

TB_PC=300
TB_OTH=301
TB_PW=310
TB_PL=311
STF=/tmp/authmgr.state

log() { logger -t authmgr "$*"; }
getip() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

setup_probe() {
	WIP=$(getip wan)
	LIP=$(getip lan4)
	ip rule del priority 900 2>/dev/null
	ip rule del priority 901 2>/dev/null
	if [ -n "$WIP" ]; then
		ip route replace default via $GW dev wan src $WIP table $TB_PW
		ip route replace $LAN dev br-lan table $TB_PW
		ip rule add from $WIP lookup $TB_PW priority 900
	fi
	if [ -n "$LIP" ]; then
		ip route replace default via $GW dev lan4 src $LIP table $TB_PL
		ip route replace $LAN dev br-lan table $TB_PL
		ip rule add from $LIP lookup $TB_PL priority 901
	fi
}

probe() {
	dev=$1
	ip=$(getip $dev)
	if [ -z "$ip" ]; then echo DEAD; return; fi
	c=$(curl -s -m 8 --interface $ip -o /dev/null -w '%{http_code}' http://www.msftconnecttest.com/connecttest.txt 2>/dev/null)
	case "$c" in
		200) echo OK ;;
		30*) echo UNAUTH ;;
		*)   echo DEAD ;;
	esac
}

# 当前连在 WiFi 上的 MAC 列表
wifi_macs() {
	for i in $(iwinfo 2>/dev/null | grep ESSID | awk '{print $1}'); do
		iwinfo $i assoclist 2>/dev/null | awk '{print tolower($1)}'
	done
}

# 有线设备（ARP 可见、且不在 WiFi 关联列表里）
wired_ips() {
	WIFI=$(wifi_macs | tr '\n' ' ')
	for pair in $(ip neigh show dev br-lan 2>/dev/null | awk '{print $1"|"tolower($5)}'); do
		ip=${pair%%|*}
		mac=${pair##*|}
		case "$ip" in 10.0.0.*) ;; *) continue ;; esac
		case " $WIFI " in *" $mac "*) continue ;; esac
		echo "$ip"
	done
}

clear_rules() {
	for p in 800 801 802 803 804; do ip rule del priority $p 2>/dev/null; done
	ip rule del priority 810 2>/dev/null
	ip route flush table $TB_PC 2>/dev/null
	ip route flush table $TB_OTH 2>/dev/null
}

steer() {
	dev_pc=$1
	dev_oth=$2

	pip=$(getip $dev_pc)
	if [ -n "$pip" ]; then
		ip route replace default via $GW dev $dev_pc src $pip table $TB_PC
		ip route replace $LAN dev br-lan table $TB_PC
		prio=800
		W=$(wired_ips)
		[ -z "$W" ] && W="10.0.0.147"
		for w in $W; do
			ip rule add from $w lookup $TB_PC priority $prio 2>/dev/null
			prio=$((prio+1))
			[ $prio -gt 804 ] && break
		done
	else
		W=""
	fi

	oip=$(getip $dev_oth)
	if [ -n "$oip" ]; then
		ip route replace default via $GW dev $dev_oth src $oip table $TB_OTH
		ip route replace $LAN dev br-lan table $TB_OTH
		ip rule add from $LAN lookup $TB_OTH priority 810 2>/dev/null
	fi
}

# ---------------- main ----------------
setup_probe
WS=$(probe wan)
LS=$(probe lan4)

[ -f /tmp/authmgr.force ] && . /tmp/authmgr.force

CUR="$WS-$LS"
PREV=$(cat $STF 2>/dev/null)
PENDF=/tmp/authmgr.pend

if [ ! -f /tmp/authmgr.force ]; then
	if [ "$CUR" = "$PREV" ]; then
		rm -f $PENDF
		exit 0
	fi
	PEND=$(cat $PENDF 2>/dev/null)
	if [ "$CUR" != "$PEND" ]; then
		echo "$CUR" > $PENDF
		log "pending $CUR (prev $PREV), waiting confirmation"
		exit 0
	fi
fi
rm -f $PENDF
log "state change: $PREV -> $CUR (wan=$WS lan4=$LS)"

if [ "$WS" = "OK" ] && [ "$LS" = "OK" ]; then
	clear_rules
	mwan3 ifup wan  >/dev/null 2>&1
	mwan3 ifup wan3 >/dev/null 2>&1
	log "both OK -> mwan3 balancing enabled"
else
	if [ "$WS" = "OK" ]; then
		mwan3 ifup wan >/dev/null 2>&1
		dev_pc=wan
	else
		mwan3 ifdown wan >/dev/null 2>&1
		if [ "$WS" = "UNAUTH" ]; then dev_pc=wan; else dev_pc=lan4; fi
	fi
	if [ "$LS" = "OK" ]; then
		mwan3 ifup wan3 >/dev/null 2>&1
		dev_oth=lan4
	else
		mwan3 ifdown wan3 >/dev/null 2>&1
		if [ "$LS" = "UNAUTH" ]; then dev_oth=lan4; else dev_oth=wan; fi
	fi
	steer $dev_pc $dev_oth
	log "auth mode: wired->$dev_pc wifi->$dev_oth"
fi

echo "$CUR" > $STF
