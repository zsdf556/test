#!/bin/sh
#brief: 模块安装

LOG="/ac/var/log/init.log"
echo ">>>S03_load_mod START..." >>$LOG

/ac/common/app/safe_start>>$LOG &
gwmodecfg="/ac/etc/config/gwmode.conf"
INSMOD_LOG_FILE="/ac/var/log/insmod.log"
GW_MODE=`rwini -s "Custom" -f $gwmodecfg -k GatewayMode`
NICADAPT_LOGFILE="/ac/var/log/supNicAdapt.log"

date >"${NICADAPT_LOGFILE}"
sh /ac/module/hwpatch/new_family/auto_nic/public_script/supNicAdapt.sh &>/dev/null
if [ $? -eq 0 ]; then
	echo "[`date '+%F %X'`] support nic self-adapt, to remove rules" >>"${NICADAPT_LOGFILE}"
	rm -f /etc/udev/rules.d/70-persistent-net.rules &>/dev/null
	# 插入网卡驱动前，删除上次生成的网口顺序后，重新默认的网口配置
	sh /ac/common/scripts/swapnic_inner.sh
fi

. /ac/common/scripts/get_dmimap.sh

mem=`free -m | awk '{if (/^Mem:/) print $2}'`
default_txd=0
default_rxd=0
if [ $mem -gt 4096 ]; then
    default_txd=4096
    default_rxd=4096
else
    default_txd=512
    default_rxd=512
fi

function ac_insmod()
{
	insmod "$@"
	
	local ret=$?
	if [ $ret -ne 0 ]; then
		echo "[`date`] failed to insmod $*" >> "$INSMOD_LOG_FILE"
	fi
	return $ret
}

function get_cpu_deliver_params()
{
	#开启协议剥离时，不设置队列大小，使用默认值
	local proto_strip_ini="/ac/etc/config/proto_strip.ini"
	local proto_strip_open=0
	if [ -f $proto_strip_ini ]; then
		proto_strip_open=`rwini -s  PROTO_STRIP -f $proto_strip_ini -k enabled`
	fi
	if [ $proto_strip_open -ne 0 ]; then
		echo "proto_strip_open=$proto_strip_open" >>$LOG
		return
	fi

	local rx_queue_size=`get_dmimap rx_queue_size`
	local tx_queue_size=`get_dmimap tx_queue_size`
	local alien_queue_size=`get_dmimap alien_queue_size`
	if [ ! -z "${rx_queue_size}" ] && [ ! -z "${tx_queue_size}" ] && [ ! -z "${alien_queue_size}" ];
	then
		echo " s_rx_queue_size=$((1<<$rx_queue_size)) s_tx_queue_size=$((1<<$tx_queue_size)) s_alien_queue_size=$((1<<$alien_queue_size)) "
		return
	fi
}

function get_conn_hold_enable_params()
{
	local hold_all_conn_enable=`get_dmimap hold_all_conn_enable`
	if [ "${hold_all_conn_enable}" == "1" ];
	then
		echo " s_hold_all_conn_enable=1"
		return
	fi	
}

#插入基础驱动
ac_insmod -f /ac/common/ko/klibstd.ko
ac_insmod -f /ac/common/ko/klibtools.ko
ac_insmod -f /ac/module/sys_layer/sys_layer.ko
ac_insmod -f /ac/module/log/logdrv.ko
ac_insmod -f /ac/module/debug/sangfor_debug.ko
ac_insmod -f /ac/module/debug/sangfor_dog.ko verbose=7

#下发系统全局配置，必须在sys_layer.ko之后
/ac/common/scripts/setglobalcfg.sh

ac_insmod -f /ac/module/nic_drv/e1000.ko
ac_insmod -f /ac/module/nic_drv/e1000e.ko 

igb=`get_dmimap igb`
ixgbe=`get_dmimap ixgbe`

ac_insmod -f /ac/module/if_custom/if_custom.ko
ac_insmod -f /ac/module/ip_conntrack/ip_conntrack.ko `get_conn_hold_enable_params`
ac_insmod -f /ac/module/nat/nf_nat.ko 
ac_insmod -f /ac/module/nat/nf_nat_v6.ko
ac_insmod -f /ac/module/nat/nptv6.ko 
ac_insmod -f /ac/module/nat/nat_download.ko
ac_insmod -f /ac/module/cpu_deliver/cpu_deliver.ko `get_cpu_deliver_params`
ac_insmod -f /ac/module/bridge/bridge.ko 
ac_insmod -f /ac/module/bypass/bypass.ko 
#ac_insmod -f /ac/module/if_custom/if_custom.ko
ac_insmod -f /ac/module/debug/dump.ko
ac_insmod -f /ac/module/ip_frag/ip_frag.ko
#ip_gre驱动只有在路由模式加载
if [ "${GW_MODE}" == "0" ]; then
	ac_insmod -f /ac/module/gre/ip_gre.ko
fi
#yhz fixbug 72190,路由模式不加载协议剥离驱动
if [ "${GW_MODE}" != "0" ]; then
	ac_insmod -f /ac/module/protocol_strip/protocol_strip.ko
fi
ac_insmod -f /ac/module/ipctcalls/ipctcalls.ko
ac_insmod -f /ac/module/netcore/switch.ko

# 加载时就搬包，在 NAT 规则下发后，再关闭，以解决 "AC重启后ICMP由于长连接不通" 的问题
# 加载时先关闭CPU繁忙机制，刚开机占用比较高，等S07再打开
ac_insmod -f /ac/module/netcore/netcore.ko g_through_packet=1 check_cpu_enable=0

#src_bit\dst_bit迁移到cpu_deliver.sh脚本中设置
if [ -z ${ixgbe} ]; then
	ac_insmod -f /ac/module/nic_drv/ixgbe.ko default_txd=${default_txd} default_rxd=${default_rxd}
else
	ac_insmod -f ${ixgbe} default_txd=${default_txd} default_rxd=${default_rxd}
fi

if [ -z ${igb} ]; then
	ac_insmod -f /ac/module/nic_drv/igb.ko
else
	ac_insmod -f ${igb}
fi

ac_insmod -f /ac/module/nic_drv/i40e.ko
ac_insmod -f /ac/module/nic_drv/igc.ko

KERNEL_VERSION=`uname -r`
ipmi=`get_dmimap ipmi`
if [ ! -z ${ipmi} ]; then
	#插入ipmi驱动
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/char/ipmi/ipmi_msghandler.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/char/ipmi/ipmi_devintf.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/char/ipmi/ipmi_si.ko
fi

bmc=`get_dmimap bmc`
enable_panic_string="/sys/module/ipmi_msghandler/parameters/send_panic_string"
if [ ! -z "${bmc}" -a "x${bmc}" == "x1" -a -f ${enable_panic_string} ]; then
	# 深信服自研平台才支持发送 panic string
	echo 1 > ${enable_panic_string}
	
	# 从bmc获取宕机信息存到日志目录
	/ac/common/app/bmc_panic_log
fi

#设备启动的时候，在加载网卡驱动之后进行网口交换
[ -f /etc/udev/rules.d/70-persistent-net.rules ] && echo "rules exist" >> $NICADAPT_LOGFILE
sh /ac/module/hwpatch/new_family/auto_nic/public_script/supNicAdapt.sh &>/dev/null
result=$?
if [ $result -eq 0 ]; then
	echo "[`date '+%F %X'`] support nic self-adapt" >> $NICADAPT_LOGFILE
	sh /ac/module/hwpatch/new_family/auto_nic/nicSwapCore.sh
else
	echo "[`date '+%F %X'`] not support nic self-adapt, retcode:${result}" >> $NICADAPT_LOGFILE
	sh /ac/common/scripts/init_swapnic.sh
fi
	
if [ -f /ac/etc/config/bypassinterfacepairs/sinfor_bypasspairs.inf ]; then
	#获取并更新bypass网口对配置信息
	/ac/module/hwpatch/new_family/auto_nic/get_bypasspair
fi
	
sh /ac/common/scripts/rc2setmode.sh 
#ac_insmod -f /ac/module/ipctcalls/ipctcalls.ko
ac_insmod -f /ac/module/debug/watch_reboot.ko
ac_insmod -f /ac/module/debug/packet_filter.ko
ac_insmod -f /ac/module/droplist/droplist.ko   
ac_insmod -f /ac/module/redirect/redirect.ko
ac_insmod -f /ac/module/debug/mpcap.ko


#插入alg相关模块
ac_insmod -f /ac/module/alg/nf_conntrack_proto_gre.ko
ac_insmod -f /ac/module/alg/nf_conntrack_proto_esp.ko
ac_insmod -f /ac/module/alg/nf_conntrack_pptp.ko
ac_insmod -f /ac/module/alg/nf_conntrack_ftp.ko
ac_insmod -f /ac/module/alg/nf_conntrack_tftp.ko
ac_insmod -f /ac/module/alg/nf_conntrack_h323.ko
ac_insmod -f /ac/module/alg/nf_conntrack_sip.ko
ac_insmod -f /ac/module/alg/nf_conntrack_rtsp.ko
ac_insmod -f /ac/module/alg/nf_conntrack_sqlnet.ko
ac_insmod -f /ac/module/alg/nf6_conntrack_ftp.ko
ac_insmod -f /ac/module/alg/nf_nat_proto_gre.ko
ac_insmod -f /ac/module/alg/nf_nat_pptp.ko
ac_insmod -f /ac/module/alg/nf_nat_ftp.ko
ac_insmod -f /ac/module/alg/nf_nat_tftp.ko
ac_insmod -f /ac/module/alg/nf_nat_rtsp.ko
ac_insmod -f /ac/module/alg/nf_nat_h323.ko
ac_insmod -f /ac/module/alg/nf_nat_sip.ko
ac_insmod -f /ac/module/alg/nf_nat_sqlnet.ko

# client_hello重组模块
ac_insmod -f /ac/module/ch_reorg/clienthello_reorg.ko

#插入业务模块
ac_insmod -f /ac/module/ac-auth/usertrackdrv.ko node_size=2000 #代理模块用得比较多，每个用户都需要记录所有代理软件的信息
ac_insmod -f /ac/module/proxyconvert/proxyconvert.ko	
ac_insmod -f /ac/module/country/country_drv.ko
ac_insmod -f /ac/module/netpolicy/netpolicy_drv.ko
#ac_insmod -f /ac/module/punish_user/punish_user_drv.ko
ac_insmod -f /ac/module/identify/contchk/contchkdrv.ko
sh /ac/common/scripts/set_contchkdrv.sh &>/dev/null
ac_insmod -f /ac/module/dns_cache/dns_cache.ko

ac_insmod -f /ac/module/wireless/terminal.ko
ac_insmod -f /ac/module/dyntype/dyntypedrv.ko

ac_insmod -f /ac/module/identify/url_handle/url_handle.ko
ac_insmod -f /ac/module/ac-auth/authdrv.ko

if [ "${GW_MODE}" == "2" -o "${GW_MODE}" == "0" ]; then
	memory=`grep MemTotal /proc/meminfo |awk '{print $2}'`
	if [[ ${memory} -gt 4000000 ]]; then
		#4G内存限制8个，小于4G限制3个
		ac_insmod -f /ac/module/policy_route/proute.ko s_tcp_proxy_cache_count=8
	else
		ac_insmod -f /ac/module/policy_route/proute.ko s_tcp_proxy_cache_count=3
	fi
fi

ac_insmod -f /ac/module/identify/p2p/p2p_be.ko
ac_insmod -f /ac/module/identify/xunlei_identify/xunlei_identify.ko
ac_insmod -f /ac/module/identify/skype/skype_id.ko
ac_insmod -f /ac/module/identify/ssldriver/ssldriver.ko
ac_insmod -f /ac/module/identify/urlmatch/urlmatch_drv.ko
ac_insmod -f /ac/module/check_https/check_https.ko
#actrace.ko 需要放到 p2p_be.ko后面
ac_insmod -f /ac/module/actrace/actrace.ko
ac_insmod -f /ac/module/vline/vline.ko
ac_insmod -f /ac/module/tc/tc.ko
ac_insmod -f /ac/module/fluxlog/fluxlog.ko `/ac/module/fluxlog/country_stats --drv-init-param`
ac_insmod -f /ac/module/proxycheck/proxychk.ko
#np_debug.ko 需要放到 fw_drv.ko前面
ac_insmod -f /ac/module/np_debug/np_debug.ko
ac_insmod -f /ac/module/firewall/fw_drv.ko
ac_insmod -f /ac/module/proxytool/proxytool_drv.ko
ac_insmod -f /ac/module/arpguard/arpguard.ko
ac_insmod -f /ac/module/dosck/dosck.ko
ac_insmod -f /ac/module/proxynat/proxynat.ko
ac_insmod -f /ac/module/saas_ctl/saas_ctl.ko
ac_insmod -f /ac/module/sslproxy/sslproxy_drv.ko
ac_insmod -f /ac/module/ingress/ingressdrv.ko
ac_insmod -f /ac/module/dns_hijack/dns_hijack.ko
ac_insmod -f /ac/module/kv/kv_filter.ko sessupperlimit=500000
ac_insmod -f /ac/module/kv/kv_ftp.ko
ac_insmod -f /ac/module/kv/kv_http.ko
ac_insmod -f /ac/module/log_filter/log_filter_drv.ko
ac_insmod -f /ac/module/qqwhitelist/qqwl_drv.ko
ac_insmod -f /ac/module/qoe/qoe_drv.ko
ac_insmod -f /ac/module/ha/ha_drv.ko
ac_insmod -f /ac/module/tcp_mss/tcp_mss.ko
ac_insmod -f /ac/module/term_redirect/term_redirect.ko

#网桥和路由模式才安装域名应用缓存模块
if [ "${GW_MODE}" == "2" -o "${GW_MODE}" == "0" ]; then
	ac_insmod -f /ac/module/dns_app/dns_app.ko
fi

#网桥模式插入光口bypass驱动
if [ "${GW_MODE}" == "2" ]; then
	ac_insmod /ac/module/fiber_bypass/fiberbp.ko
fi

#加载PPPOE所需要的驱动
KERNEL_VERSION=`uname -r`

#加载vac虚拟网卡驱动
ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/virtio_net.ko

if [ "${GW_MODE}" == "0" ]; then
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/slhc.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/lib/crc-ccitt.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/ppp_generic.ko 
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/ppp_async.ko 
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/ppp_synctty.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/pppox.ko
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/pppoe.ko

	#加载vpn虚拟网卡驱动
	ac_insmod -f /lib/modules/${KERNEL_VERSION}/kernel/drivers/net/tun.ko
	
	#VPN相关模块
	#ac_insmod -f /ac/module/vpn/ipfilter.ko
	ac_insmod -f /ac/module/vpn/mselector.ko
	#ac_insmod -f /ac/module/vpn/rawpacket.ko
	ac_insmod -f /ac/module/sfvpn/modules/dp_ipc.ko
	ac_insmod -f /ac/module/sfvpn/modules/crypto_decoder.ko
	ac_insmod -f /ac/module/sfvpn/modules/crypto_ipc_async.ko
	ac_insmod -f /ac/module/sfvpn/modules/crypto_util.ko
	
	#VPN占用内存过高，使用session_per_mb限制会话总数
	#根据上报的结果优化session_per_mb值（上报结果：2G设备最高25；大于2G设备最高14）
	memory=`grep MemTotal /proc/meminfo |awk '{print $2}'`
	if [[ ${memory} -le 2000000 ]]; then
		# 内存 <= 2GB
		ac_insmod -f /ac/module/sfvpn/modules/sfvpn.ko session_per_mb=25
	else
		ac_insmod -f /ac/module/sfvpn/modules/sfvpn.ko session_per_mb=20
	fi
fi

#设置menulst的isolcpus。此时menu.lst已经根据平台更新了。需要在网卡驱动安装后再执行，否则无法获取到正确的网口信息
/ac/common/scripts/menulst_isolcpus_set.sh
if [ $? -eq 1 ]; then
	echo "menu.lst changed. need reboot"
	echo "menu.lst changed. need reboot" >>$LOG
	retboot
fi

#新增业务系统驱动，目前只在旁路、网桥、路由部署模式下生效
if [ "${GW_MODE}" == "0" -o "${GW_MODE}" == "2" -o "${GW_MODE}" == "3" -o "${GW_MODE}" == "4" ]; then
	ac_insmod -f /ac/module/business_audits/drv/business_drv.ko
fi

#新增无插件规则检测驱动
ac_insmod -f /ac/module/legal_check/lgcheckdrv.ko

ac_insmod -f /ac/module/apt/apt.ko

#DNS代理业务在路由网桥，DNS重定向业务在路由、网桥、旁路
if [ "${GW_MODE}" == "2" -o "${GW_MODE}" == "0" -o "${GW_MODE}" == "3" -o "${GW_MODE}" == "4" ]; then
	ac_insmod -f /ac/module/dns_proxy/dns_proxy.ko
fi

kill -9 `pidof safe_start` >/dev/null 2>&1
/bin/rm -f /tmp/safe_start >/dev/null 2>&1

echo ">>>S03_load_mod END" >>$LOG
