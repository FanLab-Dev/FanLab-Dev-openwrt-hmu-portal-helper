# scripts

| 文件 | 用途 | 部署位置 |
|---|---|---|
| `auth-manager.sh` | 认证状态检测 + 有线/无线导流 | `/etc/auth-manager.sh` |
| `mwan3-pingfix.nft` | 让 mwan3 探测包绕过自身标记 | `/etc/mwan3-pingfix.nft` |

## 部署

```sh
cp auth-manager.sh /etc/auth-manager.sh
cp mwan3-pingfix.nft /etc/mwan3-pingfix.nft
chmod +x /etc/auth-manager.sh

echo "* * * * * /etc/auth-manager.sh" >> /etc/crontabs/root
/etc/init.d/cron restart

nft -f /etc/mwan3-pingfix.nft
sed -i '/^exit 0/i nft -f /etc/mwan3-pingfix.nft 2>/dev/null' /etc/rc.local

for f in /etc/auth-manager.sh /etc/mwan3-pingfix.nft; do
  grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
```

> 脚本里的 `LAN`、`GW`、接口名需要按你的环境改。