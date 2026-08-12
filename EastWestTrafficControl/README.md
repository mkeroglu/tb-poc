# East-West Trafik Kontrolü Demo Rehberi (Kısıtlama + Gözlemleme)

Bu doküman, cluster **içindeki servisler arası (east-west/yatay) trafiğin** hem **NetworkPolicy ile kısıtlanmasını** hem de **OVN ACL Logging** ile bu kararların (izin/red) **gerçek log kaydına düşerek gözlemlenmesini** anlatır. [NetworkPolicy](../NetworkPolicy/README.md) ve [MicroSegmentation](../MicroSegmentation/README.md) rehberleri sadece **kısıtlamayı** kanıtlıyordu (bağlantı geçti/geçmedi); burada ayrıca **her bağlantı kararının (allow/drop) kimin tarafından, hangi policy yüzünden, hangi IP/port için verildiğinin** ham log satırı olarak görünür olduğu canlı olarak gösterilmiştir.

Tüm adımlar bu repodaki cluster'da (OpenShift 4.22, **OVNKubernetes**) **`eastwest-demo` namespace'inde canlı test edilmiştir** — gerçek OVN ACL audit log satırları, gerçek pod IP'leriyle birebir eşleştirilerek doğrulanmıştır.

Senaryo sırası:

1. Kavram — east-west trafik ve neden gözlemlemek gerekir
2. Demo ortamının kurulması (izinli kaynak, engellenecek kaynak, korunan hedef)
3. NetworkPolicy ile kısıtlama + ACL logging'i etkinleştirme
4. Trafik üretme ve doğrulama (bağlantı seviyesi)
5. **Gözlemleme**: gerçek OVN ACL audit log kayıtları
6. Gerçek tuzak: annotation'ın doğru yere yazılması
7. Temizlik

---

## 1. Kavram

- **North-south trafik**: cluster dışından içeri (Route/Ingress/LoadBalancer) veya içeriden dışarı giden trafik.
- **East-west trafik**: cluster **içindeki pod'lar arasındaki** (servisten servise, aynı veya farklı namespace) yatay trafik. Modern mikroservis mimarilerinde trafiğin büyük çoğunluğu buradadır — ve klasik "perimeter firewall" (sadece dış sınırı koru) yaklaşımı bunu görmez.
- **Kısıtlama** (NetworkPolicy — bkz. [NetworkPolicy](../NetworkPolicy/README.md), [MicroSegmentation](../MicroSegmentation/README.md)): hangi pod'un hangi pod'a erişebileceğini tanımlar.
- **Gözlemleme** (bu doküman): kısıtlamanın **gerçekten çalıştığını**, **kimin denediğini** ve **ne zaman reddedildiğini** kanıtlayan audit iziydir. OVNKubernetes'te bu, **ACL Logging** özelliğiyle sağlanır — NetworkPolicy'nin ürettiği her OVN ACL kuralına (`allow`/`drop`) bir log seviyesi atanır, eşleşen her paket için node'da bir log satırı üretilir.

---

## 2. Demo Ortamının Kurulması

Üç pod: **izin verilen kaynak** (`app-a`), **engellenecek kaynak** (`app-c`), **korunan hedef** (`app-b`).

```yaml
# eastwest-demo.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: eastwest-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-a-allowed
  namespace: eastwest-demo
  labels: { role: allowed-source }
spec:
  replicas: 1
  selector: { matchLabels: { role: allowed-source } }
  template:
    metadata: { labels: { role: allowed-source } }
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-c-blocked
  namespace: eastwest-demo
  labels: { role: blocked-source }
spec:
  replicas: 1
  selector: { matchLabels: { role: blocked-source } }
  template:
    metadata: { labels: { role: blocked-source } }
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-b-protected
  namespace: eastwest-demo
  labels: { role: protected-target }
spec:
  replicas: 1
  selector: { matchLabels: { role: protected-target } }
  template:
    metadata: { labels: { role: protected-target } }
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /tmp/www && echo APP-B-OK > /tmp/www/index.html && httpd -f -p 8080 -h /tmp/www"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: app-b, namespace: eastwest-demo }
spec: { selector: { role: protected-target }, ports: [{ port: 8080 }] }
```

```bash
oc apply -f eastwest-demo.yaml
```

---

## 3. NetworkPolicy ile Kısıtlama + ACL Logging

```yaml
# allow-only-app-a.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-only-app-a
  namespace: eastwest-demo
spec:
  podSelector:
    matchLabels: { role: protected-target }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { role: allowed-source }
      ports:
        - protocol: TCP
          port: 8080
```

```bash
oc apply -f allow-only-app-a.yaml
```

ACL logging'i **namespace** seviyesinde etkinleştirin (bkz. Bölüm 6 — kritik detay: annotation NetworkPolicy'ye değil, **Namespace**'e yazılır):

```bash
oc annotate namespace eastwest-demo \
  'k8s.ovn.org/acl-logging={"deny":"alert","allow":"notice"}' --overwrite
```

- `deny` seviyesi: reddedilen bağlantılar için log severity'si (`alert`, `warning`, `notice`, `info`, `debug`).
- `allow` seviyesi: izin verilen bağlantılar için log severity'si.
- Namespace'teki **tüm** NetworkPolicy'ler ve EgressFirewall kuralları bu ayardan etkilenir.

---

## 4. Trafik Üretme ve Doğrulama (Bağlantı Seviyesi)

```bash
A_POD=$(oc get pod -n eastwest-demo -l role=allowed-source -o jsonpath='{.items[0].metadata.name}')
C_POD=$(oc get pod -n eastwest-demo -l role=blocked-source -o jsonpath='{.items[0].metadata.name}')

echo "app-a -> app-b (izinli olmali):"
oc exec "$A_POD" -n eastwest-demo -- wget -qO- --timeout=3 app-b.eastwest-demo.svc.cluster.local:8080

echo "app-c -> app-b (engellenmeli):"
oc exec "$C_POD" -n eastwest-demo -- wget -qO- --timeout=3 app-b.eastwest-demo.svc.cluster.local:8080
```

✅ **Gerçek çıktı:**

```
app-a -> app-b (izinli olmali):
APP-B-OK

app-c -> app-b (engellenmeli):
wget: download timed out
command terminated with exit code 1
```

Buraya kadar [NetworkPolicy](../NetworkPolicy/README.md)/[MicroSegmentation](../MicroSegmentation/README.md) demolarıyla aynı — kısıtlama çalışıyor. Asıl fark bir sonraki bölümde.

---

## 5. Gözlemleme: Gerçek OVN ACL Audit Log Kayıtları

Kararların gerçekten **loglandığını** node üzerinde doğrulayın (`app-b`'nin çalıştığı node'da):

```bash
NODE=$(oc get pod -n eastwest-demo -l role=protected-target -o jsonpath='{.items[0].spec.nodeName}')
oc debug node/$NODE -- chroot /host tail -n 20 /var/log/ovn/acl-audit-log.log
```

✅ **Gerçek çıktı** (pod IP'leriyle birebir eşleşiyor — `app-a=10.131.3.96`, `app-c=10.131.3.97`, `app-b=10.131.3.98`):

```
...|INFO|name="NP:eastwest-demo:allow-only-app-a:Ingress:0", verdict=allow, severity=notice, direction=to-lport:
    tcp,...,nw_src=10.131.3.96,nw_dst=10.131.3.98,...,tp_src=39036,tp_dst=8080,tcp_flags=syn
...|INFO|name="NP:eastwest-demo:allow-only-app-a:Ingress:0", verdict=allow, severity=notice, direction=to-lport:
    tcp,...,nw_src=10.131.3.96,nw_dst=10.131.3.98,...,tcp_flags=ack
...|INFO|name="NP:eastwest-demo:allow-only-app-a:Ingress:0", verdict=allow, severity=notice, direction=to-lport:
    tcp,...,nw_src=10.131.3.96,nw_dst=10.131.3.98,...,tcp_flags=psh|ack
...
...|INFO|name="NP:eastwest-demo:Ingress", verdict=drop, severity=alert, direction=to-lport:
    tcp,...,nw_src=10.131.3.97,nw_dst=10.131.3.98,...,tp_src=60386,tp_dst=8080,tcp_flags=syn
...|INFO|name="NP:eastwest-demo:Ingress", verdict=drop, severity=alert, direction=to-lport:
    tcp,...,nw_src=10.131.3.97,nw_dst=10.131.3.98,...,tcp_flags=syn
```

**Yorumu:**

- İlk grup (`verdict=allow`, `severity=notice`, ACL adı `NP:eastwest-demo:allow-only-app-a:Ingress:0`): `app-a`'nın (`.96`) `app-b`'ye (`.98`) TCP handshake'inin **tamamı** (syn → ack → psh|ack → ack → fin|ack) — hangi NetworkPolicy'nin izin verdiği isimle birlikte görünüyor.
- İkinci grup (`verdict=drop`, `severity=alert`, ACL adı `NP:eastwest-demo:Ingress` — genel/implicit default-deny): `app-c`'nin (`.97`) `app-b`'ye ulaşmaya çalışan **her SYN paketi tek tek reddedilip loglanıyor** (istemcinin tekrar tekrar denemesi TCP retransmisyonu olarak görünüyor).

**Bu, "gözlemlenir" gereksinimini tam olarak karşılıyor:** sadece "bağlantı koptu" demiyoruz, **kimin (kaynak IP), ne zamandan beri, hangi policy'ye takıldığını** ham log satırından okuyabiliyoruz.

> **İleri adım (bu POC'de canlı bağlanmadı):** Bu log dosyası (`/var/log/ovn/acl-audit-log.log`) OpenShift Logging'in **`infrastructure`** log tipi kapsamındadır. [Logging](../Logging/README.md) rehberinde kurduğumuz `ClusterLogForwarder`'a bir `infrastructure` input eklenirse, bu ACL kayıtları da merkezi olarak Loki'ye akıp orada sorgulanabilir/alarm kurulabilir hale gelir — node'a tek tek `oc debug` ile bakmak yerine.

---

## 6. Gerçek Tuzak: Annotation'ın Doğru Yere Yazılması

İlk denemede `k8s.ovn.org/acl-logging` annotation'ını **NetworkPolicy** objesinin üzerine yazdık — bu **sessizce hiçbir etki yapmadı**, log dosyası `0` satır olarak kaldı (hata mesajı yok, sadece hiçbir şey loglanmadı). Doğrusu: annotation **Namespace** objesine yazılmalı:

```bash
# YANLIŞ (etkisiz, hata da vermez):
oc annotate networkpolicy allow-only-app-a -n eastwest-demo 'k8s.ovn.org/acl-logging=...'

# DOĞRU:
oc annotate namespace eastwest-demo 'k8s.ovn.org/acl-logging=...'
```

Bu, sessizce hiçbir uyarı vermediği için tespit edilmesi zor bir tuzak — dosyanın gerçekten dolduğunu (`wc -l`) doğrulamadan "loglama açık" varsaymayın.

---

## 7. Temizlik

```bash
oc delete namespace eastwest-demo
```

---

## Özet Tablo

| Bileşen | Rolü |
|---|---|
| `NetworkPolicy` | East-west trafiği **kısıtlar** (izin/red kararı) |
| `Namespace` annotation `k8s.ovn.org/acl-logging` | O namespace'teki tüm NetworkPolicy/EgressFirewall kararlarının **loglanmasını** açar |
| `/var/log/ovn/acl-audit-log.log` (node üzerinde) | Her allow/drop kararının ham kaydı — kaynak/hedef IP, port, TCP bayrağı, hangi policy |
| *(opsiyonel, bu POC'de bağlanmadı)* `ClusterLogForwarder` infrastructure input | Bu logları merkezi Loki'ye taşır — bkz. [Logging](../Logging/README.md) |

**Altın kurallar:**
1. ACL logging annotation'ı **Namespace**'e yazılır, NetworkPolicy'ye değil — yanlış yere yazmak sessizce hiçbir şey yapmaz.
2. `deny`/`allow` severity'leri **ayrı ayrı** ayarlanır — genelde `deny: alert` (dikkat çekmesi gereken, beklenmedik reddedilen trafik) + `allow: notice`/`info` (normal, hacimli trafik için daha düşük öncelik) mantıklı bir varsayılan.
3. Loglar node'un yerel dosya sistemindedir (`/var/log/ovn/acl-audit-log.log`) — merkezi/sorgulanabilir gözlem için bunları [Logging](../Logging/README.md)'deki `infrastructure` log tipiyle Loki'ye yönlendirmek gerekir.
4. Kısıtlama (NetworkPolicy) ile gözlemleme (ACL logging) **birbirinden bağımsız** açılıp kapatılan iki ayrı mekanizmadır — biri diğerini otomatik getirmez.
