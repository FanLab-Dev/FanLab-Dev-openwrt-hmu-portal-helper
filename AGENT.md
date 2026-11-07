# 双线聚合：Agent 复现与排障手册

> 这份文档不是给人看的教程，是给 **AI Agent** 执行的操作手册。
> 人只需要看第 1 节，把提示词复制给 Agent；剩下由 Agent 按任务卡执行。
>
> 配套的人类版教程：`README.md`

---

## 0. 怎么用

| 角色 | 做什么 |
|---|---|
| 人类用户 | 复制第 1 节的开场提示词 → 发给 Agent → 按 Agent 要求配合（插线、输密码、确认） |
| Agent | 按第 2 节的 6 个阶段执行；遇到异常查第 3 节决策树；全程遵守第 4 节安全规则 |

**人类需要准备的**：路由器 SSH 权限、两根网线、校园网账号密码。

---

## 1. 开场提示词（复制给 Agent）

````text
你是网络配置助手，要通过 SSH 把一台 OpenWrt 路由器配置成「校园网双线聚合」。

【环境】
- 路由器：<型号>，OpenWrt <版本>，SSH 已开（root / <密码>）
- 墙上有两个可用的校园网网口，已各插一根网线到路由器
- 校园网是「网页 Portal 认证」，账号允许同时在线 2 个终端
- 我有一台电脑（有线连路由器）和一台手机（连路由器 WiFi）

【目标】
1. 两条线各自完成认证，占满账号的 2 个终端名额
2. 用 mwan3 做带宽聚合（多线程下载能叠加）
3. 一条线挂了自动降级单线，不断网
4. 未认证时，把认证页自动推到正确的设备上（有线→电脑名额，无线→移动名额）

【硬性要求，必须遵守】
1. 任何会改变网络连通性的操作前，先执行 `sysupgrade -b` 备份，并把备份拉回我的电脑
2. 已认证的接口，不要改它的 MAC 和 IP —— 认证是绑 MAC+IP 的
3. 每一步都要给出**可验证的证据**（命令 + 实际输出），不允许用「应该」「大概」下结论
4. 需要重启、改 MAC、动防火墙默认策略这类不可逆/高风险操作，先停下来告诉我，等我确认
5. 任何时刻都要保证至少有一条路能上网；改聚合前先把另一条路验证可用
6. 不要猜密码、不要枚举账号、不要做任何可能触发学校风控的扫描

【执行方式】
先做「阶段 0：侦察」，**只读不写**，输出一份现状报告：
- 认证类型是什么（网页 / PPPoE / 802.1X）
- 门户地址、AC 地址、WAN 网段
- 两个墙口是否都可用
- 当前各接口的 MAC / IP / 认证状态
报告我确认后，再进入阶段 1。

【输出格式】
每个阶段结束时输出：
## 阶段 N 结论
- 现状：<客观事实 + 证据>
- 判断：<结论 + 依据>
- 风险：<下一步可能的坑>
- 下一步：<动作> / 或「需要你确认：<具体事项>」
````

---

## 2. 执行流程（6 个阶段）

### 阶段 0：侦察（只读，禁止修改）

**目标**：搞清楚三件事 —— 认证类型、门户地址、两个墙口是否可用。

#### 0.1 收集基础事实

```sh
# 接口与地址
ip -4 -o addr show
ip -d link show | grep -A1 "^[0-9]*:"

# 默认路由
ip route | grep '^default'

# 防火墙 zone
uci show firewall | grep -E "zone\[[0-9]+\]\.(name|network|masq)"

# 认证状态（关键：200=已认证，302=未认证）
curl -s -o /dev/null -w '%{http_code}\n' http://www.msftconnecttest.com/connecttest.txt
```

#### 0.2 判定认证类型

```sh
# 抓 302 响应体，看是不是 WISPr
curl -sS -m 8 -i http://www.msftconnecttest.com/connecttest.txt | head -30
```

| 观察到的现象 | 判定 | 后续动作 |
|---|---|---|
| 返回 `WISPAccessGatewayParam` XML，含 `NextURL` | **网页 Portal（WISPr）** | ✅ 继续 |
| 返回 HTML 登录页 | 网页 Portal（非 WISPr） | ✅ 继续，但门户参数要自己拼 |
| 连接超时 / `Network unreachable` | 可能是链路问题或需要 PPPoE | ❌ 停下来问用户 |
| 能直接拿到内容（200） | 已认证或不需要认证 | ✅ 记录，继续 |

#### 0.3 提取门户参数（从 302 的 NextURL 里）

```
http://<门户IP>?userip=<本机IP>&wlanacname=&nasip=<AC地址>&usermac=<本机MAC>
```

**必须记录**：门户 IP、AC/nasip、userip、usermac。

> ⚠️ 门户 IP 常常**不在**你 DHCP 拿到的网段里（例：你拿到 `10.66.x`，门户在 `10.88.x`）。
> **不要按网段扫描找门户**，扫不到，必须从 302 里读。

#### 0.4 验证第二个墙口（关键，决定方案是否可行）

```sh
# 注意：网口管理性 down 时读不到 carrier，必须先 up
ip link set <第二个口> up
sleep 2
cat /sys/class/net/<第二个口>/carrier      # 1=有链路 0=没插/口不通

# 临时 DHCP 试探（不改 uci）
cat > /tmp/t.sh <<'EOF'
#!/bin/sh
case "$1" in bound|renew) echo "IP=$ip GW=$router" > /tmp/t.txt ;; esac
exit 0
EOF
chmod +x /tmp/t.sh
udhcpc -i <第二个口> -n -q -t 5 -T 3 -s /tmp/t.sh
cat /tmp/t.txt 2>/dev/null || echo "NO LEASE"
ip addr flush dev <第二个口>
```

**判定**：拿到 IP → 口可用，进入阶段 1；拿不到 → 报告用户「第二个墙口不可用」，方案终止（或退化为单线）。

#### 0.5 输出报告模板

```markdown
## 阶段 0 结论
- 认证类型：网页 Portal（WISPr），门户 http://10.88.0.4，AC 10.88.0.1
- WAN 网段：10.66.0.0/16，网关 10.66.0.1
- 接口：
  | 名称 | MAC | IP | 认证 |
  |---|---|---|---|
  | wan | AA:BB:CC:11:22:33 | 10.66.113.81 | 200 已认证 |
- 第二墙口：lan4，carrier=1，DHCP 试探拿到 10.66.48.222 ✅
- 账号名额：用户确认「1 电脑 + 1 移动端」
- 结论：方案可行。下一步需要用户确认是否开始改造。
```

**⛔ 阶段 0 结束必须停下来等用户确认，不要自动进入阶段 1。**

---

### 阶段 1：单线基线

**目标**：先只搞定一条线，确保它是稳的、可回滚的。

#### 1.1 备份（强制）

```sh
sysupgrade -b /tmp/bak-$(date +%H%M).tar.gz
ls -l /tmp/bak-*.tar.gz
```
然后用 scp 拉回用户电脑（Agent 应给出确切命令让用户执行，或直接拉）。

#### 1.2 配置 WAN + LAN

```sh
uci set network.wan.proto='dhcp'
uci set network.wan.ipv6='0'
uci set network.lan.ipaddr='<避开校园网网段的私有地址>'
uci commit network
/etc/init.d/network reload
```

#### 1.3 让用户完成认证

Agent 输出：
> 请用浏览器打开任意 http 网站，会跳到认证页，输入学号密码登录。完成后告诉我。

#### 1.4 验证（必须给证据）

```sh
curl -s -o /dev/null -w 'auth=%{http_code}\n' http://www.msftconnecttest.com/connecttest.txt
# 期望 200
```

**判定**：200 → 进入阶段 2；302 → 认证没成功，重新让用户确认；其它 → 查阶段 3 决策树。

---

### 阶段 2：接第二根线

#### 2.1 创建第二 WAN

```sh
uci set network.<wan2>_dev=device
uci set network.<wan2>_dev.name='<物理口>'
uci set network.<wan2>_dev.macaddr='<手机厂商 OUI + 随机后缀>'

uci set network.<wan2>=interface
uci set network.<wan2>.proto='dhcp'
uci set network.<wan2>.device='<物理口>'
uci set network.<wan2>.metric='30'      # 必须大于 wan，否则抢默认路由
uci set network.<wan2>.ipv6='0'
uci commit network

uci add_list firewall.@zone[1].network='<wan2>'
uci commit firewall
/etc/init.d/network reload
```

**MAC 选择规则**（Agent 必须检查）：
- ✅ 真实手机厂商 OUI：`AA:BB:CC`(vivo) / `64:CC:2E`(小米) / `A4:83:E7`(Apple)
- ❌ 不要用 `02:` 开头（本地管理地址，一看就是虚拟机）
- ❌ 不要和局域网内已有设备重复

#### 2.2 验证拿到独立 IP

```sh
ip -4 addr show <物理口>
# 必须和 wan 的 IP 不同，且在同一个校园网网段
```

#### 2.3 认证第二路（必须先确认走的是第二路）

**这一步是 Agent 最容易做错的地方。**

先建独立路由表强制走第二路：

```sh
ip route replace default via <网关> dev <物理口> src <第二路IP> table 100
ip rule add from <第二路IP> lookup 100 priority 1500
ip route get 8.8.8.8 from <第二路IP>      # 必须显示 dev <物理口>
```

再测试：

```sh
curl -s -o /dev/null -w '%{http_code}\n' --interface <第二路IP> http://www.msftconnecttest.com/connecttest.txt
```

**判定**：
- `302` → 未认证 ✅ 符合预期，需要登录
- `200` → **可疑**：可能流量根本没走第二路（见第 5 节反模式 #1）
- 超时 → 第二路不通，查决策树

**让用户登录第二路**（Agent 配置临时导流）：

```sh
# 把用户手机（假设 10.0.0.145）流量导到第二路
ip rule add from 10.0.0.145 lookup 100 priority 1500   # 若已存在则跳过
```

输出给用户：
> 请用手机连路由器 WiFi，打开浏览器，会跳出认证页，**输入学号密码**登录。
> 注意：用手机登录而不是电脑，因为要占「移动端」名额。

登录完成后清理：

```sh
ip rule del priority 1500
ip route flush table 100
```

#### 2.4 双路验证

```sh
ip route replace default via <网关> dev <物理口> src <第二路IP> table 100
ip rule add from <第二路IP> lookup 100 priority 1500
curl -s -o /dev/null -w 'path2=%{http_code}\n' --interface <第二路IP> http://www.msftconnecttest.com/connecttest.txt
ip rule del priority 1500; ip route flush table 100
```

两条都 200 才能进阶段 3。

---

### 阶段 3：mwan3 聚合

#### 3.1 配置前先检查「必炸条件」

```sh
uci show mwan3 | grep -E "interface|member|use_member|use_policy"
```

**必须确认**：每个 member 指向的 interface 真实存在（`ip -4 addr show` 能看到）。

> 🔴 如果 member 指向一个不存在的接口，mwan3 会把流量标记到黑洞，
> **整屋断网且不报错**。这是本方案最常见的翻车点。

#### 3.2 配置

```sh
# 接口（注意：mwan3 的 section 名必须等于 netifd 接口名）
uci set mwan3.<if1>=interface;  uci set mwan3.<if1>.enabled='1'; uci set mwan3.<if1>.family='ipv4'
uci set mwan3.<if2>=interface;  uci set mwan3.<if2>.enabled='1'; uci set mwan3.<if2>.family='ipv4'

# 成员
uci set mwan3.m1=member; uci set mwan3.m1.interface='<if1>'
uci set mwan3.m1.metric='1'; uci set mwan3.m1.weight='1'
uci set mwan3.m2=member; uci set mwan3.m2.interface='<if2>'
uci set mwan3.m2.metric='1'; uci set mwan3.m2.weight='1'

# 策略（一次只能 add_list 一个值！）
uci -q delete mwan3.balanced.use_member
uci add_list mwan3.balanced.use_member='m1'
uci add_list mwan3.balanced.use_member='m2'

# 默认规则
uci set mwan3.default_rule_v4=rule
uci set mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
uci set mwan3.default_rule_v4.family='ipv4'
uci set mwan3.default_rule_v4.use_policy='balanced'

uci commit mwan3
/etc/init.d/mwan3 enable
/etc/init.d/mwan3 start
```

#### 3.3 验证（三条全过才算成功）

```sh
# ① 策略里两条线都在，各 50%
mwan3 status | sed -n '/policies/,+4p'

# ② 外网通
curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com

# ③ 两条线都有会话
grep -c "dst=<接口1IP>" /proc/net/nf_conntrack
grep -c "dst=<接口2IP>" /proc/net/nf_conntrack
```

**如果两条线显示 `disconnecting` 但手工 ping 通** → 进入决策树 D4（mwan3 内置 tracker bug）。

#### 3.4 处理 tracker bug（若出现）

```sh
# 关掉内置探测
uci -q delete mwan3.<if1>.track_ip
uci -q delete mwan3.<if2>.track_ip
uci commit mwan3

# 加 nft 例外，让探测包绕过 mwan3 标记
cat > /etc/mwan3-pingfix.nft <<'EOF'
table ip mwan3fix {
	chain out {
		type route hook output priority 149; policy accept;
		icmp type echo-request ip daddr 223.5.5.5 counter meta mark set 0x00003f00
	}
}
EOF
nft -f /etc/mwan3-pingfix.nft
sed -i '/^exit 0/i nft -f /etc/mwan3-pingfix.nft 2>/dev/null' /etc/rc.local
```

---

### 阶段 4：自动化（认证状态检测 + 设备导流）

#### 4.1 部署脚本

Agent 应把 `auth-manager.sh`（见人类版附录 A）写入 `/etc/auth-manager.sh` 并：

```sh
chmod +x /etc/auth-manager.sh
grep -q auth-manager /etc/crontabs/root || echo "* * * * * /etc/auth-manager.sh" >> /etc/crontabs/root
/etc/init.d/cron restart

# 关键：加进备份清单，否则恢复后 cron 指向空文件
for f in /etc/auth-manager.sh /etc/mwan3-pingfix.nft; do
  grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
```

#### 4.2 验证状态机

```sh
# 正常态：两条都认证 → 不应有 800/810 规则
/etc/auth-manager.sh; cat /tmp/authmgr.state

# 强制模拟一条未认证（安全：不动真实认证）
echo "WS=UNAUTH" > /tmp/authmgr.force
rm -f /tmp/authmgr.state
/etc/auth-manager.sh
ip rule | grep -E "800|810"          # 应出现导流规则
rm -f /tmp/authmgr.force /tmp/authmgr.state
/etc/auth-manager.sh; /etc/auth-manager.sh    # 防抖需两次
ip rule | grep -E "800|810" || echo "cleared"
```

**Agent 必须验证**：强制态下规则正确生成、恢复后规则被清除、两次之间外网始终 200。

---

### 阶段 5：验收

Agent 必须跑完这三项并给出数据：

#### 5.1 聚合是否真的生效

```sh
URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
# 单连接
curl -sL -m 10 -o /dev/null -w 'single=%{speed_download}\n' "$URL"
# 6 并发
i=0; while [ $i -lt 6 ]; do
  s=$((i*100000000)); e=$((s+99999999))
  curl -sL -m 10 -o /dev/null -r $s-$e -w '%{speed_download}\n' "$URL" &
  i=$((i+1))
done | awk '{t+=$1} END {printf "total=%.0f B/s (%.0f Mbps)\n", t, t*8/1e6}'
```

**判定**：并发 ≥ 单线 × 1.5 → 聚合有效；≈ 单线 → 未生效，查决策树 D5。

#### 5.2 故障切换

```sh
nft insert rule inet fw4 output oifname "<if2物理口>" ip protocol icmp counter drop
sleep 130
mwan3 status | sed -n '/balanced/,+3p'      # 应只剩一条
curl -s -o /dev/null -w 'still=%{http_code}\n' http://www.baidu.com   # 应 200
# 恢复：按 handle 删除
nft -a list chain inet fw4 output | grep 'oifname "<if2物理口>"'
nft delete rule inet fw4 output handle <handle>
```

#### 5.3 重启恢复

```sh
reboot
# 等 60~90 秒后重新连
curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com
mwan3 status | sed -n '/policies/,+4p'
```

**判定**：两条线自动回来、认证不需要重做、策略 50/50。

---

## 3. 诊断决策树

### D1：路由器完全没网，但 WAN 有 IP

```
WAN 有 IP？
├─ 否 → 查物理链路 / DHCP / 端口
└─ 是
   ├─ ip rule 里有 fwmark 规则？
   │  ├─ 有 → 🔴 mwan3 黑洞：检查 member 是否指向不存在的接口
   │  │       修复：uci show mwan3 对比 ip -4 addr show，删掉无效 member 或补上接口
   │  └─ 无
   │     ├─ 单线：curl 302？→ 未认证，去登录
   │     └─ curl 超时 → 查默认路由 / NAT / 网关可达性
   └─ 对比修复前后：curl -s -o /dev/null -w '%{http_code}'
```

### D2：浏览器永远不弹认证页

```
流量真的走了未认证的那条线吗？
└─ ip route get <目标IP> from <客户端IP>
   ├─ 走的是已认证的线 → 需要策略路由把客户端导到未认证的线
   └─ 走的是未认证的线
      ├─ HTTP 被拦成 302？→ curl -i 看有没有 Location
      │  ├─ 有 302 → 系统应该能检测到，检查是不是用了 https / 浏览器缓存
      │  └─ 无 → 学校可能只拦特定目标，让用户手动打开门户地址
      └─ 超时 → 未认证流量被静默丢弃（不是所有学校都做劫持）
```

### D3：第二路拿不到 IP

```
carrier = 1？
├─ 否 → 网口没插好 / 墙口没开通
└─ 是
   ├─ DHCP 试探有响应？
   │  ├─ 有 → 配置问题（device 名写错 / zone 没加）
   │  └─ 无 → 交换机端口做了 MAC 限制，或该口属于另一个 VLAN
   └─ 结论：方案不可行，退化为单线
```

### D4：mwan3 显示 disconnecting / offline，但手工测试通

```
mwan3 运行时 ping -I <设备> 失败，但 ping -I <接口IP> 成功？
├─ 是 → 🔴 mwan3 内置 tracker 的标记冲突 bug
│        修复：去掉 track_ip + 自建 watchdog + nft 例外规则（见 3.4）
└─ 否 → 真的链路问题，查 carrier / 网关可达性
```

### D5：聚合不提速

```
单连接 vs 并发 速度对比
├─ 并发 ≈ 单线
│  ├─ mwan3 里 balanced 显示两条线各 50%？
│  │  ├─ 否 → 策略配置错误（use_member 少写 / 接口没启用）
│  │  └─ 是 → 检查是不是测试方法问题（单线程下载本来就只走一条）
│  └─ conntrack 里两条线的会话数都 > 0？
│     └─ 否 → 分流没生效，检查 nft mark / ip rule
└─ 并发 ≈ 单线 × 2
   └─ ✅ 正常，说明学校没做总带宽限制
```

---

## 4. 硬性安全规则（Agent 不可违反）

| # | 规则 | 原因 |
|---|---|---|
| 1 | 改配置前必须 `sysupgrade -b` 备份并拉回本地 | 路由器是唯一出口，改坏无法远程救 |
| 2 | 不要改已认证接口的 MAC / IP | 认证绑 MAC+IP，一改就得重登 |
| 3 | 改 mwan3 前先确认无「悬空 member」 | 会导致静默全网断 |
| 4 | 任何时刻保证至少一条路可用 | 用户可能正在依赖这条网 |
| 5 | 高风险操作（重启/改 MAC/动防火墙默认策略）先停下等确认 | 不可逆 |
| 6 | 不猜密码、不枚举账号、不做端口扫描 | 可能触发学校风控 |
| 7 | 结论必须附命令输出，不许「应该/大概」 | 这类问题凭推测必错 |
| 8 | 恢复备份前先确认备份里有自定义脚本 | `sysupgrade` 默认只备份 `/etc/config` |

---

## 5. 反模式清单（Agent 最常犯的错）

**#1 「`curl --interface <IP>` 返回 200 就以为第二路通了」**

❌ 错误：源地址绑定**不改变路由选择**，包可能仍从默认路由（第一条线）出去。
✅ 正确：先用 `ip route get <目标> from <源IP>` 确认 `dev`，或用独立路由表强制。

**#2 「`ping -I <设备>` 通了就以为链路健康」**

❌ 当 mwan3 在运行时，它的 output 链可能把包标记到另一条线。
✅ 用 `ping -I <接口IP>` 交叉验证，两者不一致就是 tracker bug。

**#3 「`mwan3 restart` 解决一切」**

❌ 重启前不检查 member 是否悬空 → 重启后全网断。
✅ 重启前 `uci show mwan3` + `ip -4 addr show` 对比。

**#4 「网口 `carrier=0` 就判定没插线」**

❌ 管理性 down 的网口读不到 carrier。
✅ 先 `ip link set <口> up`，再读 `/sys/class/net/<口>/carrier`。

**#5 「用 https 测试认证状态」**

❌ HTTPS 不会被劫持，永远拿到真实结果，看不出认证状态。
✅ 必须用 `http://www.msftconnecttest.com/connecttest.txt` 这类明文 HTTP。

**#6 「按网段扫描找门户」**

❌ 门户常在另一个网段（例：`10.88.x` vs 你的 `10.66.x`）。
✅ 从 302 响应的 `NextURL` 里读。

**#7 「用固定 IP 识别『电脑』」**

❌ DHCP 换地址后识别失效。
✅ 按「有线/无线」动态判定（`iwinfo assoclist` vs `ip neigh`）。

**#8 「改了配置就算完」**

❌ 没有验证步骤。
✅ 每次改动后必须输出「改前值 / 改后值 / 验证证据 / 回滚命令」。

---

## 6. 输出规范（Agent 每个阶段必须遵守）

```markdown
## 阶段 N：<名称>

### 做了什么
1. <命令或配置变更>
2. ...

### 证据
```sh
$ <命令>
<真实输出>
```

### 判断
<结论 + 依据的一句话>

### 回滚方式
```sh
<撤销上一步的确切命令>
```

### 下一步
<动作> / **需要你确认：<具体事项>**
```

**禁止**：
- 只描述不贴输出
- 「应该可以了」「理论上没问题」
- 一次改多项配置而不分开验证

---

## 7. 命令速查（Agent 用）

```sh
# ---------- 事实收集 ----------
ip -4 -o addr show                    # 所有 IPv4
ip -d link show                       # 接口类型（macvlan/bridge）
ip rule                               # 策略路由
ip route show table all | head -50    # 所有路由表
grep -c "dst=<IP>" /proc/net/nf_conntrack   # 某出口的会话数
mwan3 status                          # mwan3 策略与接口状态
iwinfo                                # 无线接口
iwinfo <if> assoclist                 # 当前 WiFi 客户端
ip neigh show dev br-lan              # 局域网 ARP

# ---------- 认证状态 ----------
curl -s -o /dev/null -w '%{http_code}\n' http://www.msftconnecttest.com/connecttest.txt
curl -sS -i http://www.msftconnecttest.com/connecttest.txt | head -20   # 看 302 参数

# ---------- 路径验证 ----------
ip route get <目标> from <源IP>        # 关键：验证真实出口
ip route show table <N>
curl -s -o /dev/null -w '%{http_code}\n' --interface <源IP> <url>

# ---------- 排障 ----------
logread | grep -iE "mwan3|authmgr" | tail -30
nft list ruleset | grep -A5 mwan3
cat /tmp/authmgr.state
```

---

## 8. 已知的环境差异（复现时要注意）

| 差异点 | 影响 | 应对 |
|---|---|---|
| 有的学校**不劫持 HTTP**（静默丢包） | 不会自动弹门户 | 手动打开门户地址 |
| 有的学校按 **UA 识别终端类型** | 第二路登录要用手机 UA | 用手机登录，或改浏览器 UA |
| 有的学校绑 **端口 + MAC** | 换物理口可能掉认证 | 尽量保持 MAC 不变 |
| 有的学校有**单账号流量/时长限制** | 聚合后更快跑完额度 | 先问清楚计费规则 |
| mwan3 版本差异 | 老版本没有 `track_method` 等选项 | 先 `mwan3 status` 看可用字段 |

---

*本文档描述的是「账号本来允许的两个终端名额」的用法，不涉及破解。
使用前请确认学校规定，风险自负。*
