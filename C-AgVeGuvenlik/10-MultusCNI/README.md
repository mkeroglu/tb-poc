# 10 — Multus CNI — Macvlan Demo Rehberi

> [← 09 — Mikro-Segmentasyon](../09-MicroSegmentation/README.md) · [POC akışı](../../README.md) · [11 — Güvenlik Testleri →](../11-SecurityTests/README.md)

Bu doküman, bir pod'a **ikinci bir ağ arayüzü** (gerçek LAN'dan, node'un fiziksel ağıyla aynı segmentten bir IP alan) eklemek için Multus CNI + macvlan kullanımını anlatır. Tüm adımlar bu repodaki cluster'da (OpenShift 4.22, **OVNKubernetes**, node'lar VMware VM) **`sekom-ocp-poc` namespace'inde, gerçek LAN'da (`10.134.151.0/24`) uçtan uca canlı test edilmiştir** — kullanılan IP bloğu (`10.134.151.241-245`) canlıya geçmeden önce ARP tablosu + `arping` ile taranıp boş olduğu doğrulanmıştır.

Senaryo sırası:

1. Multus/macvlan nedir, ne işe yarar
2. Ön koşul kontrolü (Multus zaten aktif mi, hangi node interface'i kullanılacak)
3. `NetworkAttachmentDefinition` oluşturma (macvlan + whereabouts IPAM)
4. Pod'u ikinci arayüzle çalıştırma
5. Doğrulama
6. Bilinen sınırlamalar / sık yapılan hatalar
7. Temizlik

---

## 1. Multus / Macvlan Nedir?

- **Multus**, bir pod'a birden fazla ağ arayüzü (NIC) bağlamayı sağlayan bir "meta-CNI" eklentisidir. OpenShift'te varsayılan olarak zaten kurulu ve aktiftir — Kubernetes'in standart tek-arayüz (`eth0`, cluster ağı) modelini kırmadan, isteyen pod'lara **ek** arayüz(ler) tanımlamanıza izin verir.
- **Macvlan**, bu ek arayüzlerden biri için kullanılan bir CNI plugin'idir: pod'un ek arayüzüne, node'un **fiziksel** NIC'iyle aynı L2 segmentten (gerçek LAN) kendi MAC + IP adresini verir. Sonuç: pod, cluster'ın SDN'inden (OVN) bağımsız olarak, sanki o fiziksel switch'e doğrudan takılmış bir cihazmış gibi LAN'daki diğer makinelerle doğrudan konuşabilir.
- Tipik kullanım alanları: legacy/on-prem uygulamaların gerçek LAN IP'sine ihtiyaç duyması, VM/NFV benzeri workload'lar, multicast/broadcast gerektiren protokoller, SDN'in NAT'ladığı senaryolarda gerçek kaynak IP'nin görünmesi gereken durumlar.

> **Önemli:** Macvlan, cluster'ın normal `eth0` (OVN) arayüzünün **yerine değil, yanına** eklenir. Pod yine normal Service/Route/NetworkPolicy ile cluster içi trafiğini `eth0` üzerinden yürütmeye devam eder; macvlan sadece ek bir yol açar.

---

## 2. Ön Koşul Kontrolü

**a) Multus / multi-network zaten aktif mi?**

```bash
oc get network.operator cluster -o jsonpath='{.spec.disableMultiNetwork}{"\n"}'
# Beklenen: false (ya da alan hiç yoksa varsayılan zaten false = aktif)
```

OpenShift'te bu **varsayılan olarak açık** gelir — ayrı bir operatör kurulumu gerekmez.

**b) Hangi node interface'i "master" olarak kullanılacak?**

Bu adım kritiktir ve **OVNKubernetes'e özgü bir tuzak** içerir (aşağıda 6. bölümde detaylı). Node'daki fiziksel NIC'i bulun:

```bash
oc debug node/<node-adi> -- chroot /host ip -br link show
```

OVNKubernetes'in yönettiği node'larda birincil fiziksel NIC (örn. `eno1`), **OVS `br-ex` bridge'ine enslave edilmiş** durumdadır — yani doğrudan `eno1`'i macvlan master olarak vermek çoğu zaman beklendiği gibi çalışmaz. Bunun yerine master olarak **`br-ex`** kullanılmalıdır:

```bash
oc debug node/<node-adi> -- chroot /host ip -br addr show br-ex
# br-ex arayüzünün node'un gerçek LAN IP'sini taşıdığını doğrulayın
```

**c) IPAM için whereabouts kurulu mu?**

```bash
oc get crd ippools.whereabouts.cni.cncf.io
```

Bu CRD OpenShift'in Multus paketiyle birlikte gelir; ayrı kurulum gerekmez. `whereabouts`, statik IP çakışmalarını cluster genelinde (birden fazla node'da aynı anda pod başlatılsa bile) önleyen bir IPAM plugin'idir — macvlan gibi "gerçek LAN'dan IP alan" senaryolarda **şiddetle önerilir** (aksi halde iki pod aynı IP'yi alıp LAN'da IP çakışmasına yol açabilir).

---

## 3. NetworkAttachmentDefinition Oluşturma

`NetworkAttachmentDefinition` (NAD), pod'lara referans vereceğiniz ek ağı tanımlayan namespaced bir CRD'dir.

```yaml
# macvlan-nad.yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-lan
  namespace: REPLACE_ME_NAMESPACE
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "br-ex",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "REPLACE_ME_CIDR",
        "range_start": "REPLACE_ME_IP_START",
        "range_end": "REPLACE_ME_IP_END",
        "gateway": "REPLACE_ME_GATEWAY"
      }
    }
```

Doldurulması gerekenler (ağ ekibinden teyit alın — **gerçek LAN'da kullanılmayan** bir bloktur, aksi halde IP çakışması olur). Bu clusterda kullanılan gerçek değerler:

| Placeholder | Bu POC'de kullanılan değer |
|---|---|
| `REPLACE_ME_NAMESPACE` | `sekom-ocp-poc` |
| `REPLACE_ME_CIDR` | `10.134.151.0/24` |
| `REPLACE_ME_IP_START` / `REPLACE_ME_IP_END` | `10.134.151.241` – `10.134.151.245` |
| `REPLACE_ME_GATEWAY` | `10.134.151.1` |

**IP bloğunu canlıya geçmeden önce boş olduğunu doğrulama** (ICMP tek başına yetmez, cihaz kapalı olabilir — L2 seviyesinde ARP tablosu + `arping` daha güvenilir):

```bash
# Node üzerinden mevcut ARP tablosunu kontrol et
oc debug node/<node-adi> -- chroot /host ip neigh show dev br-ex

# Aday aralığı arping ile L2 seviyesinde sorgula (cevap yoksa boş kabul edilir)
oc debug node/<node-adi> -- chroot /host bash -c '
for i in $(seq 241 245); do
  arping -c1 -w1 -I br-ex 10.134.151.$i
done'
```

```bash
oc apply -f macvlan-nad.yaml
```

> **`mode: bridge`** seçildi çünkü aynı fiziksel arayüze bağlı birden fazla macvlan pod'unun **birbiriyle de** konuşabilmesini sağlar. `mode: private`/`vepa` gibi diğer modlar pod-pod iletişimini kısıtlar/switch'e bağımlı kılar — LAN demosu için `bridge` en sorunsuz seçenektir.

---

## 4. Pod'u İkinci Arayüzle Çalıştırma

Pod'un `metadata.annotations` alanında NAD'a referans verilir:

```yaml
# macvlan-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: macvlan-test
  namespace: REPLACE_ME_NAMESPACE
  annotations:
    k8s.v1.cni.cncf.io/networks: macvlan-lan
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sleep", "3600"]
```

```bash
oc apply -f macvlan-test-pod.yaml
oc wait --for=condition=Ready pod/macvlan-test -n REPLACE_ME_NAMESPACE --timeout=60s
```

---

## 5. Doğrulama (gerçek test çıktıları)

**a) Pod'a atanan ek arayüz ve IP:**

```bash
oc exec -n sekom-ocp-poc macvlan-test -- ip addr show net1
```

✅ **Gerçek çıktı:**

```
3: net1@if11: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 ...
    link/ether 8e:bc:bb:b6:d9:47 brd ff:ff:ff:ff:ff:ff
    inet 10.134.151.241/24 brd 10.134.151.255 scope global net1
```

`eth0` cluster (OVN, `10.131.x.x`) IP'sini taşımaya devam ediyor; `net1` whereabouts'tan gelen gerçek LAN IP'sini taşıyor — iki arayüz bir arada, biri diğerinin yerini almıyor.

**b) Aynı NAD'a bağlı iki pod'un (aynı node üzerinde) macvlan üzerinden birbirine ulaşması:**

```bash
oc exec -n sekom-ocp-poc macvlan-test-2 -- sh -c "nc -l -p 5000 > /tmp/out.txt &"
oc exec -n sekom-ocp-poc macvlan-test   -- sh -c "echo hello | nc -w3 10.134.151.242 5000"
oc exec -n sekom-ocp-poc macvlan-test-2 -- cat /tmp/out.txt
```

✅ **Gerçek çıktı:** `hello` — pod1 → pod2 macvlan üzerinden (`10.134.151.241` → `10.134.151.242`) TCP ile başarıyla iletişim kurdu.

> **Not:** busybox'ın `ping`'i bu SCC altında `permission denied (are you root?)` veriyor (ICMP raw socket, restricted SCC'de kapalı) — bağlantı testini `nc` (TCP) ile yapın.

---

## 6. Bilinen Sınırlamalar / Sık Yapılan Hatalar (canlı testte doğrulanmış)

- **`eno1` değil `br-ex` — OVNKubernetes'e özgü tuzak:** Bu cluster'da birincil fiziksel NIC OVS `br-ex` bridge'ine enslave edilmiş durumda. Master olarak doğrudan fiziksel NIC adını (`eno1`) verirseniz NAD **oluşur ama** pod'un macvlan arayüzü ya hiç trafik göremez ya da beklenmedik şekilde davranır. **Her zaman `br-ex`'i master olarak kullanın.**

- **⚠️ Gerçek LAN'dan (farklı subnet/router arkasından) pod'a inbound erişim, varsayılan olarak ÇALIŞMAZ — `rp_filter` tuzağı:** Aynı node üzerindeki iki macvlan pod'u (yukarıdaki gibi aynı subnette) sorunsuz konuşur, ama **farklı bir subnetten** (bu POC'de: bu dokümanı hazırladığımız shell, `10.134.62.0/24`, router arkasından `10.134.151.0/24`'e) pod'un `net1` IP'sine ping/TCP **%100 paket kaybıyla başarısız oldu**. Kök neden canlı doğrulandı:
  - Pod'un `net1` arayüzünde `net.ipv4.conf.net1.rp_filter = 1` (strict reverse-path filtering) varsayılan olarak aktif.
  - Pod'un **default route'u hâlâ `eth0`** (OVN) üzerinden gidiyor; `net1` sadece `10.134.151.0/24`'e özel bir route ekliyor.
  - Farklı bir subnetten (örn. `10.134.62.x`) `net1`'e gelen bir paket için kernel "buna cevap `eth0`'dan giderdi, ama paket `net1`'den geldi" diyip **paketi sessizce düşürüyor** — bu yüzden aynı-subnet (pod-pod) trafiği çalışırken, gerçek dış/routed trafik çalışmıyor.
  - **Standart çözüm olan Multus `tuning` plugin ile `rp_filter`'ı gevşetmeyi denedik — OpenShift bunu admission seviyesinde engelliyor:**
    ```
    plugin type="tuning" failed (add): Sysctl net.ipv4.conf.IFNAME.rp_filter is not allowed.
    Only the following sysctls are allowed: [^net.ipv4.conf.IFNAME.accept_redirects$
    ^net.ipv4.conf.IFNAME.accept_source_route$ ^net.ipv4.conf.IFNAME.arp_accept$
    ^net.ipv4.conf.IFNAME.arp_notify$ ^net.ipv4.conf.IFNAME.disable_policy$
    ^net.ipv4.conf.IFNAME.secure_redirects$ ^net.ipv4.conf.IFNAME.send_redirects$ ...]
    ```
  - Bu NAD ile pod oluşturma **tamamen başarısız oldu** (sandbox create hatası, pod hiç ayağa kalkmadı) — yani bu yolu deneyen pod'lar `ContainerCreating`'de tıkanır.
  - **Gerçek çözüm** (bu repo kapsamında elle uygulanmadı — cluster genelinde node reboot'u tetiklediği için ayrı bir onay/plan gerektirir): `net.ipv4.conf.default.rp_filter=2` (loose mode) değerini bir **MachineConfig** ile ilgili worker node'lara (sysctl dosyası, örn. `/etc/sysctl.d/99-rp-filter.conf`) uygulamak. Bu, MCO'nun node'ları sırayla reboot etmesine yol açan, **cluster/node seviyesinde kalıcı ve paylaşımlı bir değişikliktir** — sadece bu NAD'ı değil, o node'daki tüm pod'ların rp_filter davranışını etkiler. Platform ekibiyle onaylanmadan uygulanmamalıdır.
  - **Pratik sonuç:** Bu haliyle macvlan demosu, **aynı LAN segmentindeki pod-pod / pod-diğer-cihaz** iletişimi için sorunsuz çalışır; **farklı bir subnetten (router arkasından) pod'a inbound erişim** için ek bir node-seviyesi sysctl değişikliği gerekir.

- **Macvlan'ın kendine has host-pod izolasyon kısıtı:** Node'un kendisi (host netns), üzerinde çalışan macvlan pod'una **ping atamaz** — bu da canlı test edildi (`worker02`'nin kendisinden `10.134.151.241`'e ping `%100 kayıp` verdi). Bu, Linux macvlan sürücüsünün tasarımı gereği normal/beklenen davranıştır (parent arayüz, kendi child'larına doğrudan ulaşamaz), bug değildir.
- **IP çakışması riski:** IPAM olarak `whereabouts` yerine sabit/manuel IP (`"ipam": {"type": "static", ...}`) kullanılırsa, birden fazla node'da paralel pod'lar aynı IP'yi alabilir (her node kendi CNI IPAM state'ini tutar, cluster genelinde koordinasyon olmaz) — LAN'da IP çakışmasına yol açar. Bu yüzden macvlan + gerçek LAN kombinasyonunda **whereabouts zorunlu görün**.
- **Promiscuous mode gereksinimi:** Bu cluster'ın node'ları VMware VM'leri (ARP tablosunda `00:50:56:xx` OUI'li MAC'ler görüldü). `ip -d link show br-ex` çıktısında `promiscuity 2` görüldü (Linux/OVS seviyesinde macvlan için gereken promiscuous mode zaten aktif) — ama bu, **hypervisor/ESXi port group** seviyesindeki "MAC Address Changes" / "Forged Transmits" ayarlarının da izin verdiği anlamına gelmez; bu ayar OpenShift'in dışında, sanallaştırma katmanında kontrol edilir.
- **NetworkPolicy macvlan'ı kapsamaz:** Kubernetes `NetworkPolicy` kaynakları sadece cluster'ın birincil (OVN) arayüzünü kapsar; macvlan (`net1`) üzerinden gelen/giden trafiği **kısıtlamaz**. Macvlan pod'ları için erişim kontrolü LAN/switch/firewall seviyesinde ele alınmalıdır.

---

## 7. Temizlik

```bash
oc delete pod macvlan-test macvlan-test-2 -n sekom-ocp-poc
oc delete -f macvlan-nad.yaml
```

---

## Özet Tablo

| Bileşen | Rolü |
|---|---|
| `NetworkAttachmentDefinition` | Ek ağı (hangi CNI plugin, hangi master interface, hangi IPAM) tanımlar |
| `k8s.v1.cni.cncf.io/networks` annotation | Pod'u belirli bir NAD'a bağlar |
| `master: br-ex` | OVNKubernetes node'larında macvlan'ın gerçek fiziksel NIC'e çıkabilmesi için doğru hedef |
| `mode: bridge` | Aynı NAD'a bağlı pod'ların birbiriyle de konuşabilmesini sağlar |
| `whereabouts` IPAM | Cluster genelinde koordineli IP dağıtımı — çakışmayı önler |
| `net1` | Pod içinde macvlan arayüzünün göründüğü isim (`eth0` = cluster/OVN, `net1` = macvlan/LAN) |

**Altın kurallar:**
1. OVNKubernetes cluster'larında macvlan master'ı **fiziksel NIC değil, `br-ex`** olmalı.
2. Gerçek LAN'a çıkan macvlan demolarında IPAM olarak **her zaman whereabouts** kullanın, statik IP'yi elle dağıtmayın.
3. Pod'dan node'un kendisine macvlan üzerinden ping atamamak bir bug değil, kernel'in macvlan tasarımının doğal sonucudur.
4. NetworkPolicy macvlan trafiğini kapsamaz — erişim kontrolünü LAN seviyesinde planlayın.
5. **Farklı bir subnetten pod'a inbound erişim, `rp_filter=1` yüzünden varsayılan olarak çalışmaz** ve OpenShift bunu `tuning` CNI plugin'i ile düzeltmeyi admission seviyesinde engelliyor — tek çözüm cluster-genelinde bir MachineConfig (node reboot gerektirir), bu yüzden bu demoyu "aynı LAN segmenti" senaryosu olarak sunun, farklı subnetten erişim gerekiyorsa önceden platform ekibiyle MachineConfig'i planlayın.
