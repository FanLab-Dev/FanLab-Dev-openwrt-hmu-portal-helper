# 校园网双线聚合复现指南

**openwrt-hmu-portal-helper** · OpenWrt 双 WAN 负载均衡 + 校园网 Portal 自动导流

> 用两根网线、一台 OpenWrt 路由器，把一个「单账号限 2 终端」的校园网账号
> 变成两条独立出口并做带宽聚合，同时保留网页认证能力。
>
> 参考实现：小米 AX3000T + Kwrt（OpenWrt 24.x / kernel 6.12 / fw4-nftables）
> 实测效果：单线 135 Mbps → 双线并发 290~340 Mbps

---

## 目录

- [0. 方案能做什么、不能做什么](#0-方案能做什么不能做什么)
- [1. 前置条件](#1-前置条件逐项确认缺一不可)
- [2. 准备清单](#2-准备清单)
- [3. 架构总览](#3-架构总览)
- [4. 阶段一：侦察](#4-阶段一先搞清楚三件事侦察)
- [5. 阶段二：单线跑通](#5-阶段二单线先跑通)
- [6. 阶段三：接第二根线](#6-阶段三接第二根线)
- [7. 阶段四：配置聚合](#7-阶段四配置聚合mwan3)
- [8. 阶段五：自动认证导流](#8-阶段五自动认证导流)
- [9. 阶段六：验收清单](#9-阶段六验收清单)
- [10. 排错手册](#10-排错手册)
- [11. 用 DeepSeek Harness 加速](#11-用-deepseek-harness-加速这一过程)
- [12. 风险与合规提示](#12-风险与合规提示)
- [附录 A：完整脚本](#附录-aetchauth-managersh-完整脚本)
- [附录 B：关键文件清单](#附录-b关键文件清单)
- [附录 C：参数速查](#附录-c本方案的参数速查)

---

## 0. 方案能做什么、不能做什么

| 能做 | 不能做 |
|---|---|
| 把一个账号的两个终端名额都用来上网 | 让**单条 TCP 连接**提速（分流是「按连接」的） |
| 两条线带宽叠加（多线程下载有效） | 自动完成门户登录（仍需人工输一次密码） |
| 一条线挂了自动降级单线，不断网 | 绕过学校的终端数限制（名额还是 2 个） |
| 未认证时自动把认证页推到对应设备 | 规避流量特征检测（有合规风险，见第 12 节） |

**前提**：你的校园网是**网页 Portal 认证**（不是 PPPoE 拨号，也不是必须装客户端的 802.1X）。

---

## 1. 前置条件（逐项确认，缺一不可）

- [ ] **账号允许 2 个终端**（常见是「1 电脑 + 1 移动端」，问学校或看认证页说明）
- [ ] **墙上有两个可用网口**（都要能通，见阶段一的自测方法）
- [ ] **路由器至少还有 1 个空闲网口**能改成第二个 WAN
- [ ] 路由器已刷 **OpenWrt 21.02+**（需要 `mwan3`、`nftables/fw4`、`macvlan` 支持）
- [ ] 能 SSH 登录路由器（`dropbear` 已开）
- [ ] **两根网线**

---

## 2. 准备清单

| 物品 | 说明 |
|---|---|
| OpenWrt 路由器 | 本例小米 AX3000T，Kwrt 固件。任意有 ≥2 个千兆口的路由器均可 |
| 网线 × 2 | 一根接 WAN 口，一根接第二个 WAN 口 |
| 一台电脑 | 用来在浏览器里做认证 |
| 手机/平板 | 用来占「移动端」名额 |
| （可选）DeepSeek Harness | 用于自动化排查，见第 11 节 |

---

## 3. 架构总览

```
                  ┌── wan 口 ── 墙上网口 A ─┐
   墙上的两个网口 ─┤                          ├── 校园网网关 ── 互联网
                  └── lan4 口 ─ 墙上网口 B ─┘
                            │
                      mwan3 50/50 聚合
                            │
                  ┌─────────┴─────────┐
             有线设备              无线设备
           （电脑名额）          （移动端名额）
```

**核心思路**

1. 两个物理口各自 DHCP，各拿一个校园网 IP
2. 两个口用不同的 MAC，让 AC 认为是「两台不同设备」
3. 两条线各自完成一次网页认证，占满账号的两个名额
4. mwan3 按连接把流量分到两条线上
5. 用脚本监控认证状态，未认证时把对应设备的流量导到对应线，让门户自动弹出

---

## 4. 阶段一：先搞清楚三件事（侦察）

> 这一步最关键，跳过必踩坑。

### 4.1 确认认证类型

用一台电脑直连墙口，浏览器打开 `http://1.1.1.1` 或 `http://neverssl.com`（**必须 http，不能 https**）：

| 现象 | 认证类型 | 本方案适用性 |
|---|---|---|
| 跳到某个登录页 | **网页 Portal** ✅ | 适用 |
| 没反应，但能拿下 `10.x`/`172.x` 地址 | 可能需要专用客户端或 802.1X | 不适用 |
| 拨号界面 / 需要宽带账号 | PPPoE | 不适用（改用 mwan3 多拨） |

### 4.2 抓到门户地址和参数

关键技巧：**在路由器上**（不是电脑上）请求一个外网 HTTP 地址，看它返回的 302：

```sh
ssh root@192.168.1.1
curl -sS -m 8 -i http://www.msftconnecttest.com/connecttest.txt | head -20
```

未认证时会返回类似：

```xml
<WISPAccessGatewayParam>
  <MessageType>110</MessageType>
  <NextURL>http://10.88.0.4?userip=10.66.113.81&wlanacname=&nasip=10.88.0.1&usermac=AA-BB-CC-11-22-33</NextURL>
</WISPAccessGatewayParam>
```

记下三样东西：

| 参数 | 含义 | 本例 |
|---|---|---|
| `NextURL` 的域名部分 | **门户地址** | `http://10.88.0.4` |
| `nasip` | AC 地址 | `10.88.0.1` |
| `userip` / `usermac` | 认证时绑定的 IP / MAC | `10.66.113.81` / `58-ea-1f…` |

> ⚠️ 门户地址**经常不在你拿到的网段里**（本例 `10.88.x` vs `10.66.x`），
> 按网段扫描是扫不到的，必须靠 302 抓。

### 4.3 自测第二个墙口是否可用

**不需要动任何配置**，在路由器上临时试探：

```sh
# 先把待测网口 up 起来（重要：管理性 down 时读不到 link 状态）
ip link set lan4 up
sleep 2
cat /sys/class/net/lan4/carrier    # 1 = 有线，0 = 没插/口不通

# 临时发一次 DHCP（不改 uci）
cat > /tmp/udhcpc_test.sh <<'EOF'
#!/bin/sh
case "$1" in
  bound|renew) echo "IP=$ip GW=$router" > /tmp/lease_test.txt ;;
esac
exit 0
EOF
chmod +x /tmp/udhcpc_test.sh
udhcpc -i lan4 -n -q -t 5 -T 3 -s /tmp/udhcpc_test.sh
cat /tmp/lease_test.txt
ip addr flush dev lan4          # 清理
```

拿到 IP → 这个口可用；拿不到 → 口没开通，方案到此为止。

---

## 5. 阶段二：单线先跑通

### 5.1 基础配置（LuCI 或 uci）

```sh
# WAN：DHCP
uci set network.wan.proto='dhcp'
uci set network.wan.ipv6='0'

# LAN：静态，避开校园网网段
uci set network.lan.ipaddr='10.0.0.1'
uci set network.lan.netmask='255.255.255.0'

# 硬件加速 + 全锥 NAT（可选但推荐）
uci set turboacc.config.fastpath='flow_offloading'
uci set turboacc.config.fullcone='1'

uci commit network
/etc/init.d/network reload
```

### 5.2 完成认证

浏览器打开任意 http 网站 → 跳门户 → 输学号密码。

> **重要：这一步会让 AC 记住 `MAC + IP`。后面所有操作都要保住这两个值。**

### 5.3 验证

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://www.msftconnecttest.com/connecttest.txt
# 200 = 已认证，302 = 还没认证
```

---

## 6. 阶段三：接第二根线

### 6.1 把 `lan4` 改成第二个 WAN

```sh
# 创建 wan3 接口，设备是物理口 lan4
uci set network.wan3_dev=device
uci set network.wan3_dev.name='lan4'
uci set network.wan3_dev.macaddr='AA:BB:CC:44:55:66'   # 用手机厂商 OUI，见下

uci set network.wan3=interface
uci set network.wan3.proto='dhcp'
uci set network.wan3.device='lan4'
uci set network.wan3.metric='30'      # 比 wan 高，保证默认路由仍是 wan
uci set network.wan3.ipv6='0'
uci commit network

# 防火墙 zone 里加上它
uci add_list firewall.@zone[1].network='wan3'
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
```

### 6.2 关于 MAC 的选择

学校的终端识别通常看 **MAC 厂商段 + User-Agent**。第二路要「像手机」，所以：

- 用真实手机厂商 OUI，例如 vivo `AA:BB:CC`、小米 `64:CC:2E`、Apple `A4:83:E7`
- **不要用** `02:` 开头的本地管理地址（一看就是虚拟机）
- 后 3 字节随便填，避免和真实设备冲突

### 6.3 第二路认证

第二路要占「移动端」名额，所以**登录请求必须带手机 UA**。两种做法：

**做法 A（推荐）**：用手机/平板登录

```sh
# 把手机流量临时导到 wan3（假设手机 IP 是 10.0.0.145）
ip rule add from 10.0.0.145 lookup 100 priority 1500
ip route add default via <AC网关> dev lan4 table 100
ip route add 10.0.0.0/24 dev br-lan table 100

# 手机连 WiFi，打开浏览器，会弹出门户，输密码
# 认证成功后清理
ip rule del priority 1500
ip route flush table 100
```

**做法 B**：用电脑改 UA 后登录（Edge 支持 `--user-agent`）

```sh
msedge.exe --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) \
AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" \
http://<门户地址>
```

### 6.4 验证两条线都通

```sh
# 必须用「按源地址 + 独立路由表」测试，不能用 --interface 直接绑设备
curl -s -o /dev/null -w 'wan : %{http_code}\n' --interface 10.66.113.81 http://www.msftconnecttest.com/connecttest.txt
curl -s -o /dev/null -w 'wan3: %{http_code}\n' --interface 10.66.32.252 http://www.msftconnecttest.com/connecttest.txt
```

> ⚠️ **常见误判**：直接 `curl --interface 10.66.32.252` 会走默认路由（可能是 wan），
> 得到的 200 是假象。必须在独立路由表里指定 `dev lan4` 再测。

---

## 7. 阶段四：配置聚合（mwan3）

### 7.1 配置

```sh
# 接口
uci set mwan3.wan=interface
uci set mwan3.wan.enabled='1'
uci set mwan3.wan.family='ipv4'

uci set mwan3.wan3=interface
uci set mwan3.wan3.enabled='1'
uci set mwan3.wan3.family='ipv4'

# 成员
uci set mwan3.wan_m1_w1=member
uci set mwan3.wan_m1_w1.interface='wan'
uci set mwan3.wan_m1_w1.metric='1'
uci set mwan3.wan_m1_w1.weight='1'

uci set mwan3.wan3_m1_w1=member
uci set mwan3.wan3_m1_w1.interface='wan3'
uci set mwan3.wan3_m1_w1.metric='1'
uci set mwan3.wan3_m1_w1.weight='1'

# 策略（注意：一次只能 add_list 一个值，不能 uci set 写多个）
uci -q delete mwan3.balanced.use_member
uci add_list mwan3.balanced.use_member='wan_m1_w1'
uci add_list mwan3.balanced.use_member='wan3_m1_w1'

# 默认规则走均衡
uci set mwan3.default_rule_v4=rule
uci set mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
uci set mwan3.default_rule_v4.family='ipv4'
uci set mwan3.default_rule_v4.use_policy='balanced'

uci commit mwan3
/etc/init.d/mwan3 enable
/etc/init.d/mwan3 start
```

### 7.2 ⚠️ 最常见的「全屋断网」原因

**mwan3 的规则如果指向一个不存在的接口，会把所有流量丢进黑洞。**

```sh
mwan3 status | sed -n '/policies/,+5p'
```

如果看到某个 policy 只有一条线、或者出现 `unreachable`，先查：

```sh
uci show mwan3 | grep -E "interface|member|use_member"
# 确认每个 member 指向的 interface 真实存在
ip -4 addr show | grep -E "wan"
```

修好后再 `mwan3 restart`。**改之前一定先备份**：

```sh
sysupgrade -b /tmp/backup.tar.gz && scp root@路由器:/tmp/backup.tar.gz .
```

### 7.3 ⚠️ mwan3 内置健康检查在物理口上有 bug

**现象**：`mwan3 status` 里某条线一直显示 `disconnecting` / `offline`，但手工测试是通的。

**原因**：`mwan3track` 用 `LD_PRELOAD` 包装库给探测包绑定设备，
但 mwan3 自己在 `output` 链也会打 fwmark，两者冲突导致探测包被路由到另一条线后丢弃。

**验证方法**（mwan3 运行时）：

```sh
ping -I wan3设备名 -c 2 223.5.5.5     # 失败
ping -I <该接口IP> -c 2 223.5.5.5     # 成功  ← 说明是绑定方式的问题
```

**解决方案**（本方案采用）：

1. **关掉内置探测**（去掉 `track_ip`）
2. **自己写守护脚本**做健康检查（见阶段五）
3. **加一条 nft 规则**让探测包绕过 mwan3 打标记：

```sh
cat > /etc/mwan3-pingfix.nft <<'EOF'
table ip mwan3fix {
	chain out {
		type route hook output priority 149; policy accept;
		icmp type echo-request ip daddr 223.5.5.5 counter meta mark set 0x00003f00
	}
}
EOF

# 开机自动加载（写进 /etc/rc.local 的 exit 0 之前）
sed -i '/^exit 0/i nft -f /etc/mwan3-pingfix.nft 2>/dev/null' /etc/rc.local
```

> 优先级 `149` 必须小于 mwan3 的 `150`（mangle），否则不生效。
> 标记 `0x3f00` 是 mwan3 的「默认/不处理」值，会让包回落到 main 路由表。

---

## 8. 阶段五：自动认证导流

### 8.1 脚本

保存为 `/etc/auth-manager.sh`（完整内容见附录 A），核心逻辑：

```
每分钟探测两条线（各自用自己的源 IP 发 HTTP）
  200 → 已认证    302 → 未认证    其它 → 链路坏

两条都认证 → 清空导流规则，交回 mwan3 聚合
否则      → 摘出未认证的那条，按「有线/无线」把流量导到对应线
            有线设备   → wan   （电脑名额）
            无线设备   → lan4  （移动名额）
```

### 8.2 安装

```sh
chmod +x /etc/auth-manager.sh

# 每分钟跑一次
grep -q auth-manager /etc/crontabs/root || \
  echo "* * * * * /etc/auth-manager.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

### 8.3 加入备份清单（很容易漏）

```sh
for f in /etc/auth-manager.sh /etc/mwan3-pingfix.nft; do
  grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
```

> `sysupgrade -b` 默认只备份 `/etc/config`，**自定义脚本必须手动加**，
> 否则恢复后 cron 会指向一个不存在的文件。

---

## 9. 阶段六：验收清单

### 9.1 单线 vs 并发

```sh
URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"

# 单连接
curl -sL -m 10 -o /dev/null -w 'single: %{speed_download}\n' "$URL"

# 6 并发（每次取不同的 Range，强制建立独立连接）
i=0
while [ $i -lt 6 ]; do
  s=$((i*100000000)); e=$((s+99999999))
  curl -sL -m 10 -o /dev/null -r $s-$e -w '%{speed_download}\n' "$URL" &
  i=$((i+1))
done | awk '{t+=$1} END {printf "total: %.1f Mbps\n", t*8/1e6}'
```

> 也可以直接用 **aria2**（`-x16 -s16`）或 **IDM** 多线程下载来验证，
> 效果等价且更直观。

预期：并发速度 ≈ 单线的 **1.8~2.2 倍**。若等于单线，说明没分流成功。

### 9.2 故障切换

```sh
# 注入故障：丢弃某条线的 ICMP
nft insert rule inet fw4 output oifname "lan4" ip protocol icmp counter drop
sleep 130        # 等两轮检测
mwan3 status | sed -n '/balanced/,+3p'   # 应该只剩一条线
curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com   # 仍应 200

# 恢复
nft -a list chain inet fw4 output | grep 'oifname "lan4"'    # 拿 handle
nft delete rule inet fw4 output handle <handle>
```

### 9.3 重启恢复

```sh
reboot
# 等 60 秒，重新登录
curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com
mwan3 status | sed -n '/policies/,+4p'
```

预期：两条线自动回来，认证不需要重做（MAC+IP 没变）。

---

## 10. 排错手册

| 症状 | 可能原因 | 排查 |
|---|---|---|
| 路由器完全没网，但 WAN 有 IP | mwan3 规则指向不存在的接口 → 黑洞 | `mwan3 status`，`uci show mwan3` |
| 浏览器永远不弹认证页 | 流量走了已认证的那条线 | `ip route get <目标> from <源IP>` |
| 第二路拿不到 IP | 墙口没开通 / 端口 MAC 限制 | 阶段一 4.3 的 DHCP 试探 |
| 第二路有 IP 但 302 循环 | 认证没绑到正确的 IP | 检查 `--interface` 测试是否真的走了那条线 |
| `mwan3 status` 一直 `disconnecting` | 内置 tracker 的 bug | 见 7.3 |
| 聚合速度等于单线 | 规则没生效 / 只有一条线在策略里 | `mwan3 status` 看 balanced 百分比 |
| 恢复备份后 cron 报错 | 自定义脚本没进备份 | 检查 `/etc/sysupgrade.conf` |
| 时钟慢很多小时 | 没认证 → NTP 不通 | 认证后自动恢复 |

### 关键诊断命令

```sh
# 认证状态
curl -s -o /dev/null -w '%{http_code}\n' http://www.msftconnecttest.com/connecttest.txt

# 某条线上有多少会话（NAT 后）
grep -c "dst=<该接口IP>" /proc/net/nf_conntrack

# 路由决策
ip route get 8.8.8.8 from <源IP>
ip rule
ip route show table all | head -40

# mwan3 内部状态
mwan3 status
logread | grep -iE "mwan3|authmgr" | tail -20
```

---

## 11. 用 DeepSeek Harness 加速这一过程

整个流程里最容易卡住的是**侦察阶段**（找门户地址、判断认证类型、排查路由）。这些都可以交给 AI 代理做：

**给它的最小权限**

- 路由器 SSH（只读优先，改配置前先备份）
- 本机 shell（用于测速、抓包、看浏览器历史）

**有效的提问方式**

```
1. "路由器 WAN 有 IP 但没网，帮我在路由器上探测一下是哪种认证方式"
2. "把这个 302 响应里的门户地址和参数提取出来：<贴 curl 输出>"
3. "我在 lan4 上做了 DHCP 试探但拿不到地址，帮我看是哪一层的问题"
4. "mwan3 显示 wan3 一直 disconnecting，但手工 ping 是通的，帮我定位"
5. "帮我验证两条线是不是真的独立带宽，做单连接 vs 并发的对比测试"
```

**AI 特别擅长的三件事**

| 场景 | 人工成本 | AI 成本 |
|---|---|---|
| 从 302 响应里解析 WISPr 参数 | 容易看漏 | 一次搞定 |
| 判断「200 是真通还是假象」 | 极容易误判 | 会主动查 `ip route get` |
| 逐层剥 mwan3 的路由问题 | 要翻很多文档 | 直接看 `ip rule` + conntrack |

> ⚠️ 但**改配置、重启、动 MAC** 这类操作，建议人在旁边看着，
> 并且每次改动前 `sysupgrade -b` 备份。

---

## 12. 风险与合规提示

1. **这是「一账号两终端」的合规用法**，不是破解。
   你用的是账号本来就允许的两个名额，只是把「移动端」那个名额给路由器用了。

2. **但如果学校做终端类型校验**（比如要求移动端必须是手机），
   路由器伪装成手机可能被判定为**私接**。常见处理：断网、通报学院。
   **用之前先想清楚值不值。**

3. **不要把方案分享到公开渠道时带上你的学号和 MAC。**

4. **别动 WAN 的 MAC 和 DHCP 配置** —— 免认证是绑 `MAC + IP` 的，
   一变就得重新登录。

5. 本项目只在**单账号、双终端**的场景下测试过。
   多账号、802.1X、PPPoE 环境需要另行适配。

---

## 附录 A：`/etc/auth-manager.sh` 完整脚本

```sh
#!/bin/sh
# auth-manager
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

wifi_macs() {
	for i in $(iwinfo 2>/dev/null | grep ESSID | awk '{print $1}'); do
		iwinfo $i assoclist 2>/dev/null | awk '{print tolower($1)}'
	done
}

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
```

## 附录 B：关键文件清单

| 路径 | 作用 |
|---|---|
| `/etc/config/network` | `wan` + `wan3`(设备 `lan4`) 双 WAN |
| `/etc/config/mwan3` | 聚合策略（balanced 50/50） |
| `/etc/config/firewall` | `wan` zone 包含 `wan` / `wan3`，`masq=1` |
| `/etc/config/dhcp` | 电脑静态租约（可选） |
| `/etc/auth-manager.sh` | 认证状态检测 + 设备导流 |
| `/etc/crontabs/root` | 每分钟调用 auth-manager |
| `/etc/mwan3-pingfix.nft` | 探测包绕过 mwan3 标记 |
| `/etc/rc.local` | 开机加载上面的 nft 规则 |
| `/etc/sysupgrade.conf` | 让备份包含自定义脚本 |

## 附录 C：本方案的参数速查

| 项 | 值 |
|---|---|
| 校园网网关 / AC | `10.66.0.1` / `10.88.0.1` |
| 门户地址 | `http://10.88.0.4` |
| 网段 | `10.66.0.0/16` |
| WAN（电脑名额） | `10.66.113.81` / MAC `AA:BB:CC:11:22:33` |
| WAN3（移动名额） | `10.66.32.252` / MAC `AA:BB:CC:44:55:66` |
| 内网 | `10.0.0.0/24`，WiFi `Kwrt_5G` WPA2-PSK |
| 分流粒度 | 按连接（conntrack 五元组哈希） |
| 检测周期 | 60 秒，防抖 2 次 |
