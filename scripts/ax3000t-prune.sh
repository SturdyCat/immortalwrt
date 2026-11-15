#!/usr/bin/env bash
# AX3000T 专属构建：构建时剪裁源码树。
#
# 仓库本体保持与 ImmortalWrt 上游同源（不产生几千个删除文件，可随时同步上游），
# 真正的减法在每次 GHA 构建前由本脚本完成。
# 调用顺序：feeds update -a  ->  本脚本  ->  feeds install -a  ->  make defconfig
#
# 注意：本脚本会删除工作区目录，仅供一次性 CI 构建环境执行，请勿在本地开发工作区运行。
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOPDIR"

step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1) 只保留 generic（各架构共用）与 mediatek
# ---------------------------------------------------------------------------
step "剪裁 target/linux：仅保留 generic + mediatek"
removed_targets=0
for d in target/linux/*/; do
    case "$(basename "$d")" in
        generic|mediatek) ;;
        *) rm -rf -- "$d"; removed_targets=$((removed_targets + 1)) ;;
    esac
done
echo "    移除其它架构目录：${removed_targets} 个"

# ---------------------------------------------------------------------------
# 2) mediatek 只保留 filogic subtarget（AX3000T 属于 MT7981 / Filogic 820）
#    image/Makefile 通过 include $(SUBTARGET).mk 加载，删掉其它 subtarget 的
#    定义文件不影响 filogic.mk。
# ---------------------------------------------------------------------------
step "剪裁 mediatek：仅保留 filogic"
rm -rf -- target/linux/mediatek/mt7622 \
           target/linux/mediatek/mt7623 \
           target/linux/mediatek/mt7629
rm -f -- target/linux/mediatek/image/mt7622.mk \
          target/linux/mediatek/image/mt7623.mk \
          target/linux/mediatek/image/mt7629.mk
sed -i 's/^SUBTARGETS:=.*/SUBTARGETS:=filogic/' target/linux/mediatek/Makefile
grep '^SUBTARGETS' target/linux/mediatek/Makefile
# 具体机型镜像由 ax3000t.config 只勾选 xiaomi_mi-router-ax3000t 控制；
# filogic.mk 里其它机型的定义不会参与镜像生成，保留它以降低维护成本。

# ---------------------------------------------------------------------------
# 3) LuCI 主题：只保留当前在用的 argon
# ---------------------------------------------------------------------------
step "剪裁 LuCI 主题：仅保留 argon"
if [ ! -d feeds/luci/themes ]; then
    echo "错误：feeds/luci/themes 不存在，请先执行 ./scripts/feeds update -a" >&2
    exit 1
fi
for t in feeds/luci/themes/luci-theme-*; do
    [ -d "$t" ] || continue
    case "$(basename "$t")" in
        luci-theme-argon) ;;
        *) echo "    移除 $(basename "$t")"; rm -rf -- "$t" ;;
    esac
done
# default-settings 依赖 +luci -> luci-light -> +luci-theme-bootstrap。
# 把该强依赖改指向 argon，确保任何间接引入都只带 argon，不会把已删主题拉回来。
if [ -f feeds/luci/collections/luci-light/Makefile ]; then
    sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g' \
        feeds/luci/collections/luci-light/Makefile
    echo "    luci-light 主题依赖已改为 argon"
fi
echo "    保留主题：$(ls feeds/luci/themes | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4) 首次开机把 argon 设为默认主题，并清掉旧配置里残留的 bootstrap 选项。
#    这里放的是主题可用性所需的最小设置，不含任何个人网络 / 代理配置。
#    files/ 是 OpenWrt 标准的 rootfs 覆盖目录，仅在构建期生成。
# ---------------------------------------------------------------------------
step "生成 uci-defaults：默认 argon 主题"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-ax3000t-theme <<'EOF'
#!/bin/sh
uci -q delete luci.themes.Bootstrap 2>/dev/null || true
uci -q delete luci.themes.BootstrapDark 2>/dev/null || true
uci -q delete luci.themes.BootstrapLight 2>/dev/null || true
uci -q set luci.themes.Argon=/luci-static/argon
uci -q set luci.main.mediaurlbase=/luci-static/argon
uci -q commit luci
exit 0
EOF
chmod 0755 files/etc/uci-defaults/99-ax3000t-theme

# 固件编译 lz4 + zstd 两个 zram 后端，但默认压缩器是 lz4。
# 设备侧 UCI 残留的是 zram_comp_algo='zstd'，新固件里 zstd 后端已可用，
# 若不改 UCI，开机反而会真的切到 zstd（CPU 更重），所以这里统一写回 lz4。
# 注意：sysupgrade 保留配置时 uci-defaults 可能不会重跑，需手工执行同样的命令，
#       并用 cat /sys/block/zram0/comp_algorithm 确认方括号内是 lz4。
cat > files/etc/uci-defaults/99-ax3000t-zram <<'EOF'
#!/bin/sh
# 默认压缩器取 CPU 最轻的 lz4；需要 zstd 时改成 'zstd' 并重启。
uci -q set system.@system[0].zram_comp_algo='lz4'
uci -q commit system
exit 0
EOF
chmod 0755 files/etc/uci-defaults/99-ax3000t-zram

# ---------------------------------------------------------------------------
# 5) 内核配置剪裁：移除这台机器上根本不存在的硬件子系统
#
#    实机依据（ssh root@192.168.99.1，Xiaomi Mi Router AX3000T / mt7981）：
#      - 设备树一级节点里没有 usb / pcie / mmc / sdhci / sata 任何一个；
#        /sys/bus/usb 不存在，/dev 下只有 ubiblock0_0，没有 sd* / mmcblk* / nvme*
#      - 无线是 SoC 内置 mt798x-wmac（mt7915e 驱动），交换芯片是 MDIO 上的
#        MT7531，都不走 PCIe；根文件系统是 squashfs + UBIFS + overlay
#      - 内核里 USB/PCI/MMC/SCSI/EXT4/F2FS 却是 built-in (=y)，常驻内核内存
#        （实测内核 10496K code + 7268K rodata），且开机白白发一遍初始化
#     generic/config-* 里这些总开关本来就是关的，只要把 filogic/config-* 里
#     的 =y 改回 "# CONFIG_X is not set"，Kconfig 依赖门会自动摘掉所有子项。
#
#     明确保留（不要因为"不用容器"就误剪）：
#       SWIOTLB                         MT7981 DMA bounce buffer，实测 1MB
#       MTD_UBI / UBIFS_FS / OVERLAY_FS  squashfs+UBI 根文件系统必需
#       CGROUPS / NAMESPACES / SECCOMP   procd ujail 服务隔离要用，非 Docker 专属
#       CRYPTO_DEV_SAFEXCEL             硬件加密加速
#       NFT_* / TUN / TPROXY / INET_DIAG firewall4 + OpenClash
#       PPP / PPPOE                     WAN 是 PPPoE
#       MT76 / MT7915E / MT7530 DSA     WiFi + 交换芯片
#       ZRAM / ZSMALLOC / SWAP          zram-swap
# ---------------------------------------------------------------------------
step "剪裁内核配置：移除 AX3000T 不存在的硬件子系统与调试代码"

KCONFIG_FILES="target/linux/mediatek/filogic/config-* target/linux/generic/config-*"

kopt_off() {
    local name="$1" sym="CONFIG_${1}" f n=0
    for f in $KCONFIG_FILES; do
        [ -f "$f" ] || continue
        # 精确匹配整行，避免误伤 CONFIG_PCI 与 CONFIG_PCI_MSI 这类同前缀符号
        if grep -q "^${sym}=" "$f"; then
            sed -i "s|^${sym}=.*$|# ${sym} is not set|" "$f"
            n=$((n + 1))
        fi
    done
    [ "$n" -gt 0 ] && printf '    %-28s -> 关闭（%d 处）\n' "$name" "$n"
    return 0
}

for sym in \
    USB_SUPPORT \
    PCI PCIEAER PCIEASPM PCIEASPM_PERFORMANCE PCIEPORTBUS PCIE_MEDIATEK_GEN3 \
    PCIE_PME PCI_DEBUG PCI_DOMAINS PCI_DOMAINS_GENERIC PCI_MSI \
    MMC MMC_BLOCK MMC_CQHCI MMC_HSQ MMC_MTK \
    SCSI SCSI_COMMON BLK_DEV_SD BLK_DEV_LOOP \
    EXT4_FS F2FS_FS \
    DEBUG_INFO DEBUG_MISC DEBUG_KERNEL DEBUG_FS DEBUG_FS_ALLOW_ALL \
    MAGIC_SYSRQ PRINTK_TIME
do
    kopt_off "$sym"
done

# generic/config-* 里还散落着 USB/PCI/SCSI 子项的 savedefconfig 残留（=y）。
# 总开关关闭后内核 Kconfig 本就会忽略它们，这里显式清掉，让配置干净且可校验。
for f in $KCONFIG_FILES; do
    [ -f "$f" ] || continue
    for sym in $(grep -oE '^CONFIG_(USB|USBIP|PCI|PCIE|MMC|SCSI)[A-Z0-9_]*=' "$f" \
                 | sed 's/^CONFIG_//; s/=$//' | sort -u); do
        kopt_off "$sym"
    done
done

# 自检：确认该关的已关、该留的还在，避免上游 config 结构变化导致剪裁静默失效
step "自检内核剪裁结果"
for s in USB_SUPPORT PCI MMC SCSI EXT4_FS F2FS_FS DEBUG_KERNEL DEBUG_FS; do
    if grep -q "^CONFIG_${s}=y" $KCONFIG_FILES 2>/dev/null; then
        echo "错误：CONFIG_${s} 仍为 y，剪裁未生效" >&2
        exit 1
    fi
done
for s in SWIOTLB MTD_UBI UBIFS_FS OVERLAY_FS; do
    if ! grep -q "^CONFIG_${s}=y" $KCONFIG_FILES 2>/dev/null; then
        echo "错误：必需内核符号 CONFIG_${s} 丢失，固件可能无法启动" >&2
        exit 1
    fi
done
if grep -qE '^CONFIG_(USB|USBIP|PCI|PCIE|MMC|SCSI)[A-Z0-9_]*=(y|m)$' $KCONFIG_FILES 2>/dev/null; then
    echo "错误：仍残留无用总线的 =y/=m 符号" >&2
    exit 1
fi
echo "    自检通过：无用子系统已关闭，根文件系统 / DMA / 加速相关符号保持 y"

# ---------------------------------------------------------------------------
# 6) zram 场景的内存调优
#    设备实测：sysctl 还是机械盘默认值 vm.page-cluster=3（换入预读 8 页），
#    而 zram 是压缩内存、随机访问，预读只会造成读放大；swappiness=60 也偏保守。
#    写进 /etc/sysctl.d/，S11sysctl 会按字典序加载（99 最后，覆盖 10-default）。
#    注意：这是"让 zram 更高效"的调参，不是减少开机占用；数值可按需改回。
# ---------------------------------------------------------------------------
step "生成 zram 内存调优 sysctl"
mkdir -p files/etc/sysctl.d
cat > files/etc/sysctl.d/99-ax3000t-memory.conf <<'EOF'
# AX3000T / 256MB RAM + zram swap（lz4 + zstd 后端，默认 lz4）
vm.page-cluster=0
vm.swappiness=100
vm.vfs_cache_pressure=200
EOF
chmod 0644 files/etc/sysctl.d/99-ax3000t-memory.conf

step "剪裁完成"
echo "    target/linux : $(ls target/linux | tr '\n' ' ')"
echo "    feeds        : packages / luci（见 feeds.conf.default）"
echo "    设备         : xiaomi_mi-router-ax3000t（由 ax3000t.config 唯一勾选）"
echo "    内核         : 无 USB/PCI/MMC/SCSI/EXT4/F2FS；zram 后端 lz4 + zstd，默认 lz4"
echo "    禁用服务包   : Docker / Tailscale / ZeroTier / mwan3（见 ax3000t.config + workflow 守卫）"
echo "    首次开机     : uci-defaults 设 argon 主题 + zram 算法 lz4；sysctl.d 调 zram"
