
### keepalived 配置文件示例
#### 10.18.1.27
sder@sder:/etc/keepalived$ cat keepalived.conf
global_defs {
    route_id 1b01
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens3 # 请根据实际情况修改网卡
    virtual_router_id 51
    priority 150
    advert_int 1
    nopreempt
    unicast_src_ip 10.18.1.27   # 本机IP
    unicast_peer {
        10.18.1.28             # 对端IP
    }
    authentication {
        auth_type PASS
        auth_pass 1111
    }
    virtual_ipaddress {
        10.18.1.30
    }
}


#### 10.18.1.28  

sder@sder:/etc/keepalived$ cat keepalived.conf
global_defs {
    route_id 1b01
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens3
    virtual_router_id 51
    priority 100
    advert_int 1
    nopreempt
    unicast_src_ip 10.18.1.28   # 本机IP
    unicast_peer {
        10.18.1.27             # 对端IP
    }
    authentication {
        auth_type PASS
        auth_pass 1111
    }
    virtual_ipaddress {
        10.18.1.30
    }
}

sder@sder:/etc/keepalived$ sudo tcpdump -i ens3 -n vrrp
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on ens3, link-type EN10MB (Ethernet), snapshot length 262144 bytes
11:54:26.377859 IP 10.18.1.27 > 10.18.1.28: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20
11:54:27.378129 IP 10.18.1.27 > 10.18.1.28: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20


### Mysql
mysql -uroot -p's<9!Own1z4'

SHOW MASTER STATUS\G
SHOW SLAVE STATUS\G

STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
MASTER_HOST='10.18.1.27',
MASTER_USER='root',
MASTER_PASSWORD='s<9!Own1z4',
MASTER_AUTO_POSITION=1;
START SLAVE;

