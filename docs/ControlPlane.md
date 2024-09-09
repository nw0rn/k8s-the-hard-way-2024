# Control Plane Installation steps 

1. Install ETCD 

More information here: https://github.com/etcd-io/etcd/releases/

```
ETCD_VER=v3.5.15

# choose either URL
GOOGLE_URL=https://storage.googleapis.com/etcd
GITHUB_URL=https://github.com/etcd-io/etcd/releases/download
DOWNLOAD_URL=${GOOGLE_URL}

rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test && mkdir -p /tmp/etcd-download-test

curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1
rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz

sudo cp /tmp/etcd-download-test/etcd /usr/local/bin/etcd
sudo cp /tmp/etcd-download-test/etcdctl /usr/local/bin/etcdctl
sudo cp /tmp/etcd-download-test/etcdutl /usr/local/bin/etcdutl

sudo cat > /etc/systemd/system/etcd.service << EOF
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \
  --name controller \
  --listen-client-urls http://127.0.0.1:2379 \
  --advertise-client-urls http://127.0.0.1:2379 \
  --initial-cluster-state new 
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

```

Start with: 

```
systemctl daemon-reload
systemctl enable etcd.service
systemctl start etcd.service
journalctl -u etcd.service -f
```

2. Download k8s binaries 

```
cat > $HOME/downloads.txt << EOF
https://dl.k8s.io/v1.31.0/bin/linux/amd64/kube-apiserver
https://dl.k8s.io/v1.31.0/bin/linux/amd64/kube-controller-manager
https://dl.k8s.io/v1.31.0/bin/linux/amd64/kube-scheduler
EOF

mkdir -p $HOME/downloads

wget -q --show-progress   --https-only   --timestamping   -P downloads   -i downloads.txt

mkdir -p /etc/kubernetes/config #needed for scheduler.yaml
cp $HOME/downloads/kube-apiserver /usr/local/bin/kube-apiserver
chmod +x /usr/local/bin/kube-apiserver
cp $HOME/downloads/kube-controller-manager /usr/local/bin/kube-controller-manager
chmod +x /usr/local/bin/kube-controller-manager
cp $HOME/downloads/kube-scheduler /usr/local/bin/kube-scheduler
chmod +x /usr/local/bin/kube-scheduler
```

3. Configure and start the kube-api-server

```
cat > /etc/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \
  --allow-privileged=true \
  --apiserver-count=1 \
  --audit-log-maxage=30 \
  --audit-log-maxbackup=3 \
  --audit-log-maxsize=100 \
  --audit-log-path=/var/log/audit.log \
  --client-ca-file=/etc/kubernetes/pki/ca-chain.crt \
  --etcd-servers=http://127.0.0.1:2379 \
  --encryption-provider-config=/etc/kubernetes/pki/encryption-config.yaml \
  --kubelet-certificate-authority=/etc/kubernetes/pki/ca-chain.crt \
  --kubelet-client-certificate=/etc/kubernetes/pki/kube-apiserver-kubelet-client.crt \
  --kubelet-client-key=/etc/kubernetes/pki/kube-apiserver-kubelet-client.key \
  --runtime-config='api/all=true' \
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
  --service-account-issuer=https://127.0.0.1:6443 \
  --service-cluster-ip-range=10.96.0.0/24 \
  --tls-cert-file=/etc/kubernetes/pki/kube-apiserver.crt \
  --tls-private-key-file=/etc/kubernetes/pki/kube-apiserver.key \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Start the kube-apiserver with: 

```
systemctl daemon-reload
systemctl enable kube-apiserver
systemctl start kube-apiserver
journalctl -u kube-apiserver -f
```

4. Configure and start the kube-controller-manager

```
cat > /etc/systemd/system/kube-controller-manager.service << EOF 
[Unit]
Description=Kubernetes Controller Manager
Documentation=https:/github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
  --allocate-node-cidrs \
  --cluster-cidr=10.200.0.0/16 \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt \
  --cluster-signing-key-file=/etc/kubernetes/pki/ca.key \
  --kubeconfig=/etc/kubernetes/controller-manager.conf \
  --root-ca-file=/etc/kubernetes/pki/ca-chain.crt \
  --service-account-private-key-file=/etc/kubernetes/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/24 \ #k8s control plane service will be 1st IP of this range (i.e 10.96.0.1)
  --use-service-account-credentials=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Start the kube-controller-manager with: 

```
systemctl daemon-reload
systemctl enable kube-controller-manager
systemctl start kube-controller-manager
journalctl -u kube-controller-manager -f
```

5. Configure and start the kube-scheduler

```
cat > /etc/kubernetes/config/kube-scheduler.yaml << EOF 
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/etc/kubernetes/scheduler.conf"
leaderElection:
  leaderElect: true
EOF

cat > /etc/systemd/system/kube-scheduler.service << EOF 
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --config=/etc/kubernetes/config/kube-scheduler.yaml \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Start the kube-scheduler with: 

```
systemctl daemon-reload
systemctl enable kube-scheduler
systemctl start kube-scheduler
journalctl -u kube-scheduler -f
```