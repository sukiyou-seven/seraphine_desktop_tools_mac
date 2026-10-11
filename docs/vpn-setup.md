# IKEv2 VPN 手工配置步骤

> 服务器：`8.216.15.143`　证书：ECDSA P-256（服务器证书 660B / CA 639B）　服务：`active`

## 为什么需要这些步骤

自动化能做的都做完了（服务器安装、签证书、生成描述文件），剩下两步**必须由你手工完成** ——
这是 macOS/iOS 的安全设计，不是工具缺失：

1. **信任自签 CA** —— 系统不会自动信任任何非官方 CA，必须明确授权
2. **安装描述文件** —— macOS 27 已移除 `profiles install`，只能走系统设置界面

---

## 第 1 步：信任 CA 证书（关键，不做这步会一直报"未能验证此证书"）

在终端执行（会要求输入你的登录密码）：

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/Documents/code/db-manager/build/vpn-ecdsa-ca.crt
```

**预期**：无输出即成功。

**不想用命令行**的话，等价做法：
1. 双击 `~/Documents/code/db-manager/build/vpn-ca.cer`
2. 钥匙串访问弹窗 → 选「**登录**」钥匙串 → 添加
3. 在钥匙串访问里找到 **IKEv2 VPN CA** → 双击
4. 展开「**信任**」→ 把「使用此证书时」改成「**始终信任**」
5. 关窗口（输密码）

**验证是否生效**：

```bash
security find-certificate -a -c "IKEv2 VPN CA" /Library/Keychains/System.keychain
# 能打印出证书信息就说明装进去了
```

---

## 第 2 步：安装描述文件

```bash
open ~/Documents/code/db-manager/build/vpnclient-ecdsa.mobileconfig
```

屏幕会弹出安装向导 → 点「**安装**」→ 输入登录密码。

**如果之前装过旧的**（服务器地址相同的老描述文件），先删掉：
`系统设置 → 通用 → 设备管理` → 找到旧的那个 → 「移除描述文件」

**验证**：

```bash
profiles list -type=configuration | grep vpn.managed
scutil --nc list
```

---

## 第 3 步：连接并验证（这一步才是真正的成功判据）

1. **系统设置 → VPN** → 找到 `8.216.15.143` → 点「连接」
2. 用 Safari 打开 **`ipinfo.io/ip`**
3. **应该显示 `8.216.15.143`**，而不是你自己的 IP

> ⚠️ **别看界面图标下结论** —— 只看 `ipinfo.io/ip` 显示的 IP。这是唯一可靠的判据。

**命令行验证出口 IP**：

```bash
curl -s https://ipinfo.io/ip
```

---

## 第 4 步：iPhone

1. 描述文件已经在 **iCloud 云盘 → 文稿** 里：
   `seraphine-vpn-8.216.15.143.mobileconfig`
   手机「文件」App → iCloud 云盘 → 文稿 → 点它安装

2. ⚠️ **iOS 还多一步**（很多人漏掉，漏了就连不上）：
   ```
   设置 → 通用 → 关于本机 → 证书信任设置
   → 把「IKEv2 VPN CA」开关打开
   ```

3. 然后 `设置 → 通用 → VPN与设备管理 → VPN` → 点连接
4. 用 Safari 访问 `ipinfo.io/ip` 验证

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 「未能验证此证书（认证错误）」 | CA 未被系统信任 | 执行**第 1 步** |
| 一直转圈后失败 | 认证响应被切成多个 UDP 分片，移动网络丢片 | 已通过换 ECDSA 证书解决（2017B → ~1000B） |
| 显示已连接但上不了网 | 隧道没接管流量 | 检查描述文件里 `IPv4.OverridePrimary = 1` |
| 服务端完全没收到包 | 云安全组没放行 | 阿里云安全组入方向放行 **UDP 500/4500** |

---

## 服务器端现状（供排查参考）

```bash
# 服务状态
ssh root@8.216.15.143 'systemctl is-active ipsec && ipsec whack --status | head -20'

# 当前连接与流量
ssh root@8.216.15.143 'ipsec whack --trafficstatus'

# 配置文件
ssh root@8.216.15.143 'cat /etc/ipsec.d/ikev2.conf'

# 证书列表（NSS 库）
ssh root@8.216.15.143 'certutil -d sql:/etc/ipsec.d -L'
```

**关键配置项**（`/etc/ipsec.d/ikev2.conf`）：

```
conn ikev2-cp
  leftcert=8.216.15.143     # 证书昵称，必须和 NSS 库里的完全一致
  leftsendcert=always
  leftsubnet=0.0.0.0/0      # 全隧道
  rightaddresspool=192.168.43.10-192.168.43.250
  sendca=ca                 # 服务器主动发 CA，客户端才能构建完整链
  mtu=1280
  auto=add
```

> ⚠️ **改这个文件要注意**：写错关键字（例如 `ike-frag` 这种不存在的项）会让 `ipsec`
> **直接起不来**。改完务必确认 `systemctl is-active ipsec` 返回 `active`。
