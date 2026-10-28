FROM kindest/node:v1.36.1
# 基础层已含 util-linux(blkid/lsblk)；smartctl 缺失时 Agent 扫描容错回退 Healthy。
COPY hlvm-agent /usr/local/bin/hlvm-agent
RUN chmod +x /usr/local/bin/hlvm-agent
ENTRYPOINT ["/usr/local/bin/hlvm-agent"]
