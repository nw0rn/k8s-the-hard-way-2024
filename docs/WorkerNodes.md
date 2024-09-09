# Worker Node Installation steps 

1. Download k8s binaries 

```
cat > $HOME/downloads.txt << EOF
https://dl.k8s.io/v1.31.0/bin/linux/amd64/kubelet
https://dl.k8s.io/v1.31.0/bin/linux/amd64/kube-proxy
https://github.com/containerd/containerd/releases/download/v1.7.20/containerd-1.7.20-linux-amd64.tar.gz
https://github.com/opencontainers/runc/releases/download/v1.2.0-rc.2/runc.amd64
EOF

mkdir -p $HOME/downloads
wget -q --show-progress   --https-only   --timestamping   -P downloads   -i downloads.txt

sudo cp ./downloads/kubelet /usr/local/bin/kubelet 
sudo cp ./downloads/kube-proxy /usr/local/bin/kube-proxy 

sudo chmod +x /usr/local/bin/kubelet
sudo chmod +x /usr/local/bin/kube-proxy 
```

2. Setup containerd
https://github.com/containerd/containerd/blob/main/docs/getting-started.md

```
sudo tar Cxzvf /usr/local ./downloads/containerd-1.7.20-linux-amd64.tar.gz

sudo mkdir -p /usr/local/lib/systemd/system
sudo sh -c 'curl https://raw.githubusercontent.com/containerd/containerd/main/containerd.service > /usr/local/lib/systemd/system/containerd.service'
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

sudo install -m 755 ./downloads/runc.amd64 /usr/local/sbin/runc

sudo mkdir -p /etc/containerd/
sudo chmod 777 /etc/containerd/
sudo containerd config default > /etc/containerd/config.toml
```

To use the systemd cgroup driver in /etc/containerd/config.toml with runc, set: 

```
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  ...
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true

sudo systemctl restart containerd
```  

3. Configure and start the kubelet 

This needs to be done on **all** worker nodes. 

```
sudo mkdir -p /etc/kubernetes/config

sudo cat > /etc/kubernetes/config/kubelet-config.yaml << EOF 
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
      enabled: false
  webhook:
      enabled: true
  x509:
      clientCAFile: "/etc/kubernetes/pki/ca-chain.crt"
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
cgroupDriver: systemd
containerRuntimeEndpoint: "unix:///var/run/containerd/containerd.sock"
resolvConf: "/run/systemd/resolve/resolv.conf"
tlsCertFile: "/etc/kubernetes/pki/node-{i}.crt" #update the value here
tlsPrivateKeyFile: "/etc/kubernetes/pki/node-{i}.key" #update the value here
EOF

sudo cat > /etc/systemd/system/kubelet.service << EOF 
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/etc/kubernetes/config/kubelet-config.yaml \
  --kubeconfig=/etc/kubernetes/node-{i}.conf \ #update the value here
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Start the kubelet with: 

```
systemctl daemon-reload
systemctl enable kubelet.service
systemctl start kubelet.service
journalctl -u kubelet.service -f 
```

4. Install a CNI Plugin (Cilium)

Use "Kubernetes" as feature for IP-Adress management. 

```
helm upgrade -i cilium cilium/cilium --version 1.16.1 \
  --set ipam.mode=kubernetes \
  --set k8sServiceHost=10.0.0.4 \
  --set k8sServicePort=6443 \
  --reuse-values \
  --namespace kube-system
```

Confirm with ```cilium status --wait``` that cilium works as expected. 

5. Install CoreDNS

```
helm --namespace=kube-system upgrade -i coredns coredns/coredns --set service.clusterIP=10.96.0.10
```