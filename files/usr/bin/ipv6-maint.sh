#!/bin/sh
# IPv6 单 /64 共享维护：SLAAC 前缀落地、回程路由、镜像 LuCI IPv4 端口转发。
# 适用无 PD 的单 WAN/单 LAN 场景；不是通用 NDP proxy / 多 WAN 管理器。
# 不写 UCI。cron 定期自愈，hotplug 在接口/地址变化后触发。
# 用法：ipv6-maint.sh [--resolve <IPv4>]
# 可用环境变量覆盖：WAN_NETWORK（默认自动找默认路由）、LAN_NETWORK（默认 lan）、
# WAN_IF/LAN_IF（默认取 netifd l3_device）、STATE_DIR、ROUTE_METRIC。
# 依赖 OpenWrt functions/network/jshn、BusyBox flock、ip、nft、ubus。

LAN_NETWORK=${LAN_NETWORK:-lan}
STATE_DIR=${STATE_DIR:-/var/run/ipv6-maint}
ROUTE_METRIC=${ROUTE_METRIC:-64}
TABLE=ipv6fwd
MARK=ipv6-maint

log() { logger -t ipv6-maint -- "$*"; }

identifier() {
	case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
}

device_name() {
	case "$1" in ''|*[!a-zA-Z0-9_.:@-]*) return 1 ;; esac
}

# 所有地址先展开为小写、补零的八组，避免 :: 压缩形式和前导零造成误判。
# 模式分别读取 ip addr、ip neigh、ip route 和已结构化提取的 DHCPv6 租约。
ipv6_records() {
	awk -v mode="$1" -v pfx="$PFX" -v hosts="$WORK/neighbors" -v leases="$WORK/leases" '
	BEGIN {
		if(mode=="routes") {
			while((getline row < hosts)>0) {split(row,fields," "); lan_host[fields[2]]=1}
			while((getline row < leases)>0) {split(row,fields," "); lan_host[fields[2]]=1}
		}
	}
	function expand(s,    n,a,b,i,k,t,x,out) {
		s=tolower(s); sub(/\/.*/, "", s)
		if (s !~ /^[0-9a-f:]+$/) return ""
		k=index(s,"::"); n=0
		if (k) {
			x=substr(s,k+2)
			if (index(x,"::")) return ""
			t=substr(s,1,k-1)
			if (t!="") n=split(t,a,":")
			b=0; if (x!="") b=split(x,two,":")
			if (n+b>=8) return ""
			for(i=n+1;i<=8-b;i++) a[i]="0"
			for(i=1;i<=b;i++) a[8-b+i]=two[i]
			n=8
		} else n=split(s,a,":")
		if(n!=8) return ""
		out=""
		for(i=1;i<=8;i++) {
			if(a[i]=="" || length(a[i])>4) return ""
			while(length(a[i])<4) a[i]="0" a[i]
			out=out (i==1 ? "" : ":") a[i]
		}
		return out
	}
	function prefix(a) { return substr(a,1,19) }
	function mac_ok(m,    n,a,i) {
		n=split(m,a,":"); if(n!=6) return 0
		for(i=1;i<=6;i++) if(a[i]!~/^[0-9a-f][0-9a-f]$/) return 0
		return 1
	}
	mode=="wan" && $1=="inet6" && $2~/\/64$/ {
		if($0~/(tentative|dadfailed|deprecated)/) next
		a=expand($2)
		if(a~/^[23]/) { print prefix(a); exit }
	}
	mode=="addresses" && $1=="inet6" {
		a=expand($2); split($2,cidr,"/")
		if(a!="" && $0!~/(tentative|dadfailed)/) print a "/" cidr[2]
	}
	mode=="neighbors" {
		if($0~/(FAILED|INCOMPLETE)/) next
		a=expand($1); m=""
		for(i=2;i<NF;i++) if($i=="lladdr") m=tolower($(i+1))
		if(a!="" && prefix(a)==pfx && mac_ok(m)) print m, a
	}
	mode=="routes" {
		# 仅清理已确认 LAN 主机的反向直连 /128，不猜测其他静态路由的用途。
		if($1~/\// && $1!~/\/128$/) next
		if($0~/ via / || $0~/ proto kernel /) next
		a=expand($1)
		if(a!="" && prefix(a)==pfx && (a in lan_host)) print $1
	}
	mode=="leases" {
		d=tolower($1); gsub(/:/,"",d); m=""
		# 标准 Ethernet DUID-LLT / DUID-LL；不把二进制 DUID 当 ASCII 解码。
		if(d~/^00010001/ && length(d)==28) m=substr(d,17)
		if(d~/^00030001/ && length(d)==20) m=substr(d,9)
		if(m!~/^[0-9a-f]+$/ || length(m)!=12) next
		a=expand($2)
		if(a=="" || prefix(a)!=pfx) next
		out=""; for(i=1;i<=12;i+=2) out=out (i==1 ? "" : ":") substr(m,i,2)
		print out, a
	}'
}

# 用 shell 内建拆 MAC，U/L 位翻转后按四个 hextet 输出（不启动十多个 cut）。
eui64_of() {
	local m="$1" a b c d e f first
	a=${m%%:*}; m=${m#*:}; b=${m%%:*}; m=${m#*:}
	c=${m%%:*}; m=${m#*:}; d=${m%%:*}; m=${m#*:}
	e=${m%%:*}; f=${m#*:}
	first=$((0x$a ^ 2))
	printf '%02x%s:%sff:fe%s:%s%s\n' "$first" "$b" "$c" "$d" "$e" "$f"
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1}'
}

# 返回 nft 数字端口表达式；允许源端口列表/范围，目标只允许单端口/单范围。
ports() {
	printf '%s\n' "$1" | awk -v single="$2" '
	{ for(i=1;i<=NF;i++) {
		n=split($i,a,/[:-]/)
		if(n<1 || n>2) exit 1
		for(j=1;j<=n;j++) if(a[j]!~/^[0-9]+$/ || length(a[j])>5 || a[j]+0<1 || a[j]+0>65535) exit 1
		if(n==2 && a[1]+0>a[2]+0) exit 1
		if(single && ++count>1) exit 1
		out=out (out=="" ? "" : ", ") sprintf("%d",a[1]) (n==2 ? "-" sprintf("%d",a[2]) : "")
	} }
	END { if(out=="") exit 1; if(!single) out="{ " out " }"; print out }'
}

lease_file() {
	local path
	config_get path "$1" leasefile /tmp/dhcp.leases
	[ ! -r "$path" ] || awk -v now="$NOW" '
		($1==0 || $1>now) {m=tolower($2); n=split(m,a,":"); ok=(n==6)
		for(i=1;i<=n;i++) if(a[i]!~/^[0-9a-f][0-9a-f]$/) ok=0
		if(ok) print $3, m}' "$path" >> "$WORK/mac"
}

# 一次 ubus 查询，使用 jshn 按对象关联 DUID 和地址，不依赖 JSON 排版/字段顺序。
load_dhcp6() {
	local data leases lease duid addrs item address preferred valid
	data=$(ubus -t 5 call dhcp ipv6leases 2>/dev/null) || return 0
	json_load "$data" || return 0
	json_select device && json_select "$LAN_IF" && json_select leases || return 0
	json_get_keys leases
	for lease in $leases; do
		json_select "$lease" || continue
		json_get_var duid duid
		if json_select ipv6-addr; then
			json_get_keys addrs
			for item in $addrs; do
				json_select "$item" || continue
				json_get_var address address
				json_get_var preferred preferred-lifetime
				json_get_var valid valid-lifetime
				if [ "$preferred" != 0 ] && [ "$valid" != 0 ]; then
					printf '%s %s\n' "$duid" "$address"
				fi
				json_select ..
			done
			json_select ..
		fi
		json_select ..
	done
}

snapshot_hosts() {
	: > "$WORK/mac"
	config_load dhcp || return 1
	config_foreach lease_file dnsmasq
	ip -4 neigh show dev "$LAN_IF" > "$WORK/arp" 2>/dev/null || return 1
	awk '$0!~/(FAILED|INCOMPLETE)/ {for(i=2;i<NF;i++) if($i=="lladdr") print $1,tolower($(i+1))}' \
		"$WORK/arp" >> "$WORK/mac"
	ip -6 neigh show dev "$LAN_IF" > "$WORK/ndp" 2>/dev/null || return 1
	ipv6_records neighbors < "$WORK/ndp" > "$WORK/neighbors" || return 1
	load_dhcp6 | ipv6_records leases > "$WORK/leases" || return 1
	: > "$WORK/results"
	if [ -r "$STATE_DIR/map" ]; then
		cp "$STATE_DIR/map" "$WORK/map" || return 1
	else
		: > "$WORK/map"
	fi
}

resolve_gua() {
	local ip="$1" mac eui seen addr result
	valid_ipv4 "$ip" || return 1
	result=$(awk -v ip="$ip" '$1==ip{print $2; exit}' "$WORK/results")
	if [ -n "$result" ]; then
		[ "$result" != - ] || return 1
		printf '%s\n' "$result"
		return 0
	fi
	mac=$(awk -v ip="$ip" '$1==ip{print $2; exit}' "$WORK/mac")
	case "$mac" in
		[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
		*) printf '%s -\n' "$ip" >> "$WORK/results"; return 1 ;;
	esac
	eui=$(eui64_of "$mac")
	seen=$(awk -v m="$mac" '$1==m{print $2; exit}' "$WORK/map")
	addr=$(awk -v m="$mac" -v e="$PFX:$eui" -v seen="$seen" '
		$1==m {if($2==e) stable=$2; if($2==seen) old=$2}
		END{if(stable!="") print stable; else if(old!="") print old}' "$WORK/neighbors")
	# 租约可先于邻居发现存在，不能因无邻居而提前返回。
	[ -n "$addr" ] || addr=$(awk -v m="$mac" '$1==m{print $2; exit}' "$WORK/leases")
	[ -n "$addr" ] || addr=$(awk -v m="$mac" '$1==m{print $2; exit}' "$WORK/neighbors")
	printf '%s %s\n' "$ip" "${addr:--}" >> "$WORK/results"
	[ -n "$addr" ] || return 1
	awk -v m="$mac" '$1!=m' "$WORK/map" > "$WORK/map.new" || return 1
	printf '%s %s\n' "$mac" "$addr" >> "$WORK/map.new"
	mv "$WORK/map.new" "$WORK/map" || return 1
	printf '%s\n' "$addr"
}

find_zones() {
	local name nets net dev
	config_get name "$1" name
	identifier "$name" || return 0
	config_get nets "$1" network
	for net in $nets; do
		[ "$net" != "$LAN_NETWORK" ] || LAN_ZONE=$name
		if [ -n "$WAN_NETWORK" ] && [ "$net" = "$WAN_NETWORK" ]; then
			WAN_ZONE=$name
		elif [ -n "$WAN_IF" ] && network_get_device dev "$net" && [ "$dev" = "$WAN_IF" ]; then
			# PPPoE 的动态 wan_6 子接口可能仍归属于父接口的 zone。
			WAN_ZONE=$name
		fi
	done
}

do_relay() {
	local old old_dev old_metric addr found=0
	old=; old_dev=; old_metric=
	[ ! -r "$STATE_DIR/relay" ] || read -r old old_dev old_metric < "$STATE_DIR/relay"
	if [ -n "$PFX" ]; then
		ip -6 addr show dev "$LAN_IF" > "$WORK/lan" 2>/dev/null || return 1
		for addr in $(ipv6_records addresses < "$WORK/lan"); do
			[ "$addr" != "$PFX:0000:0000:0000:0001/64" ] || found=1
		done
		if [ "$found" = 0 ]; then
			ip -6 addr replace "$PFX::1/64" dev "$LAN_IF" || return 1
		fi
		ip -6 route replace "$PFX::/64" dev "$LAN_IF" metric "$ROUTE_METRIC" || return 1
	fi
	# 新配置成功后才清理旧配置；记录设备和 metric，支持配置变化后的精确撤销。
	if [ -n "$old" ] && { [ "$old" != "$PFX" ] || [ "$old_dev" != "$LAN_IF" ]; }; then
		ip -6 addr del "$old::1/64" dev "$old_dev" 2>/dev/null
		ip -6 route del "$old::/64" dev "$old_dev" metric "$old_metric" 2>/dev/null
	elif [ -n "$old" ] && [ "$old_metric" != "$ROUTE_METRIC" ]; then
		ip -6 route del "$old::/64" dev "$old_dev" metric "$old_metric" 2>/dev/null
	fi
	if [ -z "$PFX" ]; then
		rm -f "$STATE_DIR/relay"
		[ -z "$old" ] || log "relay: WAN 无可用 /64，已撤销旧前缀 $old"
		return 0
	fi
	printf '%s %s %s\n' "$PFX" "$LAN_IF" "$ROUTE_METRIC" > "$WORK/relay"
	if ! cmp -s "$WORK/relay" "$STATE_DIR/relay"; then
		mv "$WORK/relay" "$STATE_DIR/relay" || return 1
		log "relay: $PFX::1/64 -> $LAN_IF (metric $ROUTE_METRIC)"
	fi
	ip -6 route show dev "$WAN_IF" > "$WORK/routes" 2>/dev/null || return 1
	for addr in $(ipv6_records routes < "$WORK/routes"); do
		ip -6 route del "$addr" dev "$WAN_IF" && log "relay: 清理反向主机路由 $addr"
	done
	return 0
}

append_redirect() {
	local section="$1" enabled src dest target name dip dpub dport protos p gua local_target=0
	local raw_pub raw_port restriction value accept_chain seen=""
	config_get_bool enabled "$section" enabled 1
	[ "$enabled" = 1 ] || return 0
	config_get src "$section" src
	[ "$src" = "$WAN_ZONE" ] || return 0
	config_get target "$section" target DNAT
	[ "$target" = DNAT ] || return 0
	config_get name "$section" name "$section"
	# 不把带访问限制的 IPv4 规则悄悄扩大为不受限 IPv6 放行。
	for restriction in src_ip src_mac src_dip src_port ipset mark limit extra start_time stop_time start_date stop_date weekdays monthdays; do
		config_get value "$section" "$restriction"
		if [ -n "$value" ]; then
			printf '%s: 跳过（暂不支持限制项 %s）\n' "$section" "$restriction" >> "$WORK/state"
			return 0
		fi
	done
	config_get dip "$section" dest_ip
	config_get dest "$section" dest
	if [ -z "$dip" ]; then
		local_target=1
	else
		for value in $LOCAL_IPS; do
			[ "$dip" != "$value" ] || local_target=1
		done
	fi
	[ "$local_target" = 1 ] || [ "$dest" = "$LAN_ZONE" ] || return 0
	config_get raw_pub "$section" src_dport
	config_get raw_port "$section" dest_port "$raw_pub"
	dpub=$(ports "$raw_pub") && dport=$(ports "$raw_port" 1) || {
		printf '%s: 跳过（端口无效或目标不是单端口/范围）\n' "$section" >> "$WORK/state"
		return 0
	}
	config_get protos "$section" proto 'tcp udp'
	[ "$protos" != tcpudp ] || protos='tcp udp'
	for p in $protos; do
		case "$p" in tcp|udp) ;; *)
			printf '%s: 跳过（仅支持 TCP/UDP）\n' "$section" >> "$WORK/state"; return 0 ;;
		esac
	done
	[ -n "$protos" ] || return 0
	accept_chain=input
	if [ "$local_target" = 1 ]; then
		# 本机端口改变时也要 DNAT，不能仅放行尚未翻译的公网端口。
		gua="$PFX::1"
	else
		accept_chain=forward
		gua=$(resolve_gua "$dip") || {
			printf '%s: %s 无法解析当前前缀 GUA\n' "$section" "$dip" >> "$WORK/state"
			return 0
		}
	fi
	for p in $protos; do
		case " $seen " in *" $p "*) continue ;; esac
		seen="$seen $p"
		if [ "$local_target" = 1 ] && [ "$dpub" = "{ $dport }" ]; then
			printf 'insert rule inet fw4 input_%s meta nfproto ipv6 fib daddr type local ip6 daddr %s::/64 %s dport %s accept comment "%s"\n' \
				"$WAN_ZONE" "$PFX" "$p" "$dpub" "$MARK" >> "$WORK/batch"
		else
			printf 'ip6 daddr %s::/64 fib daddr type local %s dport %s dnat ip6 to [%s]:%s\n' \
				"$PFX" "$p" "$dpub" "$gua" "$dport" >> "$WORK/dnat"
			printf 'insert rule inet fw4 %s_%s ip6 daddr %s %s dport { %s } ct status dnat accept comment "%s"\n' \
				"$accept_chain" "$WAN_ZONE" "$gua" "$p" "$dport" "$MARK" >> "$WORK/batch"
		fi
	done
	printf '%s: %s %s/%s -> %s:%s\n' "$name" "${dip:-本机}" "$protos" "$raw_pub" "${gua:-本机}" "$raw_port" >> "$WORK/state"
}

do_portfwd() {
	local chain handle line
	# fw4 不可用时保留现有规则，避免把查询失败当作“没有规则”。
	nft -a list table inet fw4 > "$WORK/fw4" 2> "$WORK/error" || return 1
	: > "$WORK/batch"; : > "$WORK/dnat"; : > "$WORK/state"
	# 扫描整个 fw4 表，旧 zone 改名后也能清理；只匹配本服务的精确 comment。
	awk -v mark="$MARK" '
		$1=="chain" {chain=$2; gsub(/"/,"",chain)}
		index($0,"comment \"" mark "\"") {
			for(i=1;i<NF;i++) if($i=="handle" && $(i+1)~/^[0-9]+$/)
				print chain, $(i+1)
		}' "$WORK/fw4" > "$WORK/handles"
	while read -r chain handle; do
		identifier "$chain" || return 1
		printf 'delete rule inet fw4 %s handle %s\n' "$chain" "$handle" >> "$WORK/batch"
	done < "$WORK/handles"
	if [ -n "$PFX" ]; then
		[ -n "$WAN_ZONE" ] && [ -n "$LAN_ZONE" ] || return 1
		config_foreach append_redirect redirect
	fi
	{
		# add 已存在的表不报错；flush 和所有 fw4 删增在同一事务，无规则空窗。
		printf 'add table inet %s\nflush table inet %s\ntable inet %s {\n' "$TABLE" "$TABLE" "$TABLE"
		printf 'chain dstnat { type nat hook prerouting priority dstnat; policy accept;\n'
		while IFS= read -r line; do
			printf 'iifname "%s" %s\n' "$WAN_IF" "$line"
		done < "$WORK/dnat"
		printf '}\nchain dstnat_out { type nat hook output priority dstnat; policy accept;\n'
		while IFS= read -r line; do printf '%s\n' "$line"; done < "$WORK/dnat"
		printf '}\n}\n'
	} >> "$WORK/batch"
	if ! nft -f "$WORK/batch" 2> "$WORK/error"; then
		log 'portfwd: nft 事务失败，保留原规则和已应用状态'
		while IFS= read -r line; do log "$line"; done < "$WORK/error"
		return 1
	fi
	if ! cmp -s "$WORK/state" "$STATE_DIR/state"; then
		mv "$WORK/state" "$STATE_DIR/state" || return 1
		log 'portfwd: 已应用新状态'
		while IFS= read -r line; do log "  $line"; done < "$STATE_DIR/state"
	fi
	[ ! -f "$WORK/map" ] || mv "$WORK/map" "$STATE_DIR/map"
}

cleanup() {
	# WORK 仅来自本进程 mktemp；不删除锁文件，否则会产生多个 flock 锁 inode。
	[ -z "$WORK" ] || { rm -f "$WORK"/*; rmdir "$WORK"; }
}

main() {
	local mode="${1:-}" NOW PFX WAN_ZONE LAN_ZONE LOCAL_IPS rc=0
	case "$mode" in
		'') [ "$#" = 0 ] || return 2 ;;
		--resolve) [ "$#" = 2 ] && valid_ipv4 "$2" || { printf '用法: %s --resolve <IPv4>\n' "$0" >&2; return 2; } ;;
		*) printf '用法: %s [--resolve <IPv4>]\n' "$0" >&2; return 2 ;;
	esac
	case "$ROUTE_METRIC" in ''|*[!0-9]*) return 2 ;; esac
	[ "$ROUTE_METRIC" -gt 0 ] && [ "$ROUTE_METRIC" -le 4294967295 ] || return 2
	. /lib/functions.sh
	. /lib/functions/network.sh
	. /usr/share/libubox/jshn.sh
	umask 077
	[ ! -L "$STATE_DIR" ] && mkdir -p "$STATE_DIR" || return 1
	[ ! -L "$STATE_DIR/lock" ] || return 1
	exec 9> "$STATE_DIR/lock" || return 1
	# 内核锁在退出、信号、SIGKILL 后自动释放；调试解析也必须持锁。
	command -v flock >/dev/null 2>&1 || { log '缺少 flock，拒绝无锁运行'; return 1; }
	flock -n 9 || { [ "$mode" != --resolve ]; return; }
	WORK=$(mktemp -d "$STATE_DIR/run.XXXXXX") || return 1
	trap cleanup EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	NOW=$(date +%s)
	# 显式取得一次 netifd 快照：查询失败不等于接口离线，不能据此撤销规则。
	__NETWORK_CACHE=$(ubus -t 5 call network.interface dump 2>/dev/null) || {
		log 'netifd 查询失败，保留原配置'; return 1
	}
	[ -n "$__NETWORK_CACHE" ] || return 1
	if [ -z "$WAN_NETWORK" ]; then
		network_find_wan6 WAN_NETWORK || network_find_wan WAN_NETWORK || WAN_NETWORK=
	fi
	if [ -z "$WAN_IF" ] && [ -n "$WAN_NETWORK" ]; then
		network_get_device WAN_IF "$WAN_NETWORK" || return 1
	fi
	[ -n "$LAN_IF" ] || network_get_device LAN_IF "$LAN_NETWORK" || return 1
	device_name "$LAN_IF" || return 1
	PFX=
	if [ -n "$WAN_IF" ]; then
		device_name "$WAN_IF" || return 1
		[ "$WAN_IF" != "$LAN_IF" ] || return 1
		ip -6 addr show dev "$WAN_IF" scope global > "$WORK/wan" 2>/dev/null || return 1
		PFX=$(ipv6_records wan < "$WORK/wan") || return 1
	fi
	if [ "$mode" = --resolve ]; then
		[ -n "$PFX" ] && snapshot_hosts || return 1
		resolve_gua "$2" || return 1
		mv "$WORK/map" "$STATE_DIR/map"
		return
	fi
	if [ -n "$PFX" ]; then
		network_get_ipaddrs LOCAL_IPS "$LAN_NETWORK" || LOCAL_IPS=
		snapshot_hosts || { log '主机快照失败，保留原配置'; return 1; }
	fi
	config_load firewall || return 1
	config_foreach find_zones zone
	do_relay || { log 'relay: 维护失败，未更新端口转发'; return 1; }
	do_portfwd || { log 'portfwd: 维护失败'; rc=1; }
	return "$rc"
}

main "$@"
