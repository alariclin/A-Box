# A-Box 待问 Argon4 问题汇总

**基线**: main@2a20941 (2026-10-16)
**CI**: 通过 (#74)
**已修复**: P1-01签名, P2-02 pin, P3-01, P2-01基础, P1-02部分, P2-03, P2-05

---

## 问题一：白名单回滚的顺序语义（P1-02 深修）

### 现状代码

**回滚函数** (`install.sh:4413`):
```bash
_ss_wl_rollback_to_snapshot() {
    local ipt snap cur line failed=0
    [[ "${_SS_WL_SNAP_TAKEN:-0}" == 1 ]] || return 1
    [[ -n "${_SS_WL_SNAP_PORT:-}" ]] || return 1
    for ipt in "$IPT" "$IPT6"; do
        # ... 删除新增、补回删除 ...
        # Verify final state matches snapshot.
        local final
        final_out="$("$ipt" -w -S INPUT 2>/dev/null)"; final_rc=$?
        if (( final_rc != 0 )); then failed=1; continue; fi
        final="$(printf '%s\n' "$final_out" | grep -F "A-Box-${_SS_WL_SNAP_PORT}-" | sed 's/^-A INPUT //' | sort)"
        local expected
        expected="$(printf '%s\n' "$snap" | grep -v '^$' | sort || true)"
        if [[ "$final" != "$expected" ]]; then
            failed=1
        fi
    done
    # ...
}
```

**关键缺陷**: 最终比较时用了 `sort`，只验证规则**集合**一致，不验证**顺序**。

### 为什么顺序重要

防火墙按顺序匹配：
```
-A INPUT -s 1.2.3.4 -j ACCEPT   # 白名单
-A INPUT -j DROP                  # 拒绝其他
```
如果顺序反了：
```
-A INPUT -j DROP                  # 先DROP，白名单永远匹配不到
-A INPUT -s 1.2.3.4 -j ACCEPT
```
白名单用户会被误杀。

### 问 Argon4

1. ~~回滚时是否应该记录并恢复规则的精确行号？~~ **[已否决]** 严禁使用绝对行号（`-I INPUT 3`）：
   iptables 行号在增删循环中动态偏移，Docker/Fail2ban/UFW 随时可能在头部插入规则，
   基于绝对行号回滚会导致插错位置甚至误删系统规则。**已采用"清空专属规则+按快照顺序重放"方案**。
2. `enforce_ss_whitelist_order()` 负责排序，如果回滚后顺序不对，应该由谁负责修复？
3. 外部手动改 iptables 导致快照冲突时，是强行覆盖还是报错退出？

---

## 问题二：选项4的事务完整性

> **⚠️ 前提纠偏**：`allowPort` 生成的规则未必携带 `A-Box-<port>-` 注释（ufw/firewalld 后端规则格式不同）。
> 一旦 `save_firewall_rules` 失败，当前回滚函数无法清理 `allowPort` 新增的放行规则。
> 且原回滚函数用 `sort` 忽略顺序，会导致放行与丢弃规则错位。**已按"清空重放+保序"重写回滚函数**。

### 现状代码

**选项4** (`install.sh:9460`, 已加本轮修复):
```bash
4)
    _ss_wl_snapshot_rules || die '无法快照...'
    remove_ss_source_whitelist_rules || { _ss_wl_rollback_to_snapshot; die '...'; }
    for proto in tcp udp; do
        # 删除IPv4 DROP（失败时回滚）
        # 删除IPv6 DROP（失败时回滚）
        allowPort "$SS_PORT" "$proto"    # <-- 这里失败没有回滚！
    done
    save_firewall_rules || { _ss_wl_rollback_to_snapshot; die '...'; }
```

### 问 Argon4

1. `allowPort` 失败时（第9479行）没有回滚，是否需要补？
2. 如果 `allowPort` 成功但 `save_firewall_rules` 失败，回滚能恢复 `allowPort` 加的规则吗？（快照只抓 `A-Box-<port>-` 注释的规则，`allowPort` 加的可能没有这个注释）

---

## 问题三：i18n 六语言缺口（P2-04）

### 实测数据

| 指标 | 数值 |
|---|---|
| `tr_msg` 字典 key | 22 个 × 6 语言 = 132 条 ✅ |
| `tr_msg` 实际调用 key | 8 个 |
| `case "${ABOX_LANG` 块 | 66 个 |
| `ja)` 分支 | **0 处** |
| `zh-tw)` 分支 | **0 处** |
| `fa)` 分支 | 52 处 |
| `ru)` 分支 | 52 处 |
| 缺 `en)` 分支 | 0（CI 检查通过） |

### 结论

日语和繁中用户在几乎所有界面看到的都是**简体中文兜底**，不是真正的六语言支持。

### 问 Argon4

1. README 写"支持六种语言"是否属于过度承诺？应该改成"部分支持"还是补翻译？
2. ~~缺翻译时兜底到英文还是中文？~~ **[已否决改英文]**
   66 处 `case` 块的 `*)` 分支承担 `zh`/`zh-cn` 默认输出职责，若直接改为英文会导致简体中文界面全面瘫痪。
   **决策：保持中文兜底不动**，README 改为"完整支持中/英，部分支持俄/波斯语"，不夸大六语言。
3. 安全警告（远程脚本执行、Wallos HTTP暴露）的日语/波斯语翻译，机器翻译初稿能接受吗？还是必须人工审？

---

## 问题四：test-tools 签名消费端

### 现状

- 发布端：`update-mirrors.yml` 已加 `SHA256SUMS.sig` 生成和上传 ✅
- 消费端：`install.sh` 的测试工具下载函数**还没有验签逻辑** ❌

### 相关代码

`install.sh` 约14700行，`fetch_test_tool()` 函数：
1. 从 `test-tools-mirror` Release 下载 `SHA256SUMS`
2. 用 SHA256 校验脚本
3. **没有验证 `SHA256SUMS.sig`**

### 问 Argon4

1. 消费端验签应该做到什么程度？是 `ENFORCE=1` 时强制验签，还是始终验签？
2. 如果 `SHA256SUMS.sig` 缺失或无效，是拒绝执行还是回退到纯 SHA256 校验？

---

## 问题五：签名信任边界

### 现状

- 公钥硬编码在 `install.sh:114`：`release-2026:7V4PBUUVpnfYhKu5LBxA...`
- `install.sh` 本身从 `raw.githubusercontent.com` 拉取
- 公钥也在 `install.sh` 里面

### 问 Argon4

这个设计防的是：
- ✅ Release 资产被篡改
- ✅ Actions Secret 以外的投毒

但防不了：
- ❌ 仓库写权限被拿走（攻击者连公钥一起换）

README 应该怎么写才不算过度承诺？ "供应链签名" vs "端到端可信" 的措辞边界在哪？

---

## 附：已修复清单（不用再问）

| ID | 问题 | 修复 |
|---|---|---|
| P1-01 | 测试公钥+ENFORCE=0 | 真实公钥+ENFORCE=1+Secret已配 |
| P2-01 | 快照`\|\| true`掩盖 | 区分读取失败与空规则 |
| P1-02 | 选项3三处未回滚 | 已补 |
| P1-02 | 选项4无快照 | 已加 |
| P2-03 | 上游无钉扎回退 | 默认拒绝，需`ABOX_ALLOW_UNVERIFIED_UPSTREAM=1` |
| P2-05 | README镜像优先级 | 6份已修正 |
| P3-01 | .lang识别 | 支持6语言 |
| CI | 无en分支检查 | 已加 |
