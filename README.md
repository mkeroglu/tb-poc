# Sekom OpenShift POC

Bu repo, Sekom'un müşteri ortamlarında uyguladığı OpenShift POC senaryolarını içerir. Klasörler **uygulama sırasına göre** gruplanmış (A–E) ve numaralandırılmıştır (01–19). Sıra, rehberler arasındaki bağımlılıklara göre belirlendi: platform temeli → uygulama teslimi → ağ ve güvenlik → operasyon → sanallaştırma. Bir rehberin kurduğu kaynak (namespace, DPA, Loki vb.) sonraki rehberlerde kullanılıyor; bu yüzden sırayla gidilmesi önerilir.

## Akış

| # | Rehber | Konu | Ön koşul / bağımlılık |
|---|---|---|---|
| **A** | **[Platform Temeli](A-PlatformTemeli)** | | |
| 01 | [Kimlik ve Yetki](A-PlatformTemeli/01-KimlikVeYetki/README.md) | LDAP/AD ve HTPasswd kimlik sağlayıcıları, grup senkronizasyonu, RBAC (dev/prod, rol bazlı yetki) | cluster-admin |
| 02 | [Container Yönetimi](A-PlatformTemeli/02-ContainerYonetimi/README.md) | Namespace/Project, rollout/rollback, HPA, ResourceQuota, LimitRange | — (`sekom-ocp-poc` namespace'ini **bu rehber oluşturur**; 03, 04, 10, 12 bunu kullanır) |
| 03 | [Uygulama Senaryoları](A-PlatformTemeli/03-UygulamaSenaryolari/README.md) | Stateless, stateful (ODF), API/microservice | 02 (02'nin kotası kaldırılmış olmalı) |
| 04 | [Image Yönetimi](A-PlatformTemeli/04-ImageYonetimi/README.md) | Internal/external registry, private pull secret, ACS ile zafiyet taraması | 02, RHACS |
| **B** | **[Uygulama Teslimi](B-UygulamaTeslimi)** | | |
| 05 | [CI/CD](B-UygulamaTeslimi/05-Ci-Cd/README.md) | OpenShift Pipelines + GitOps (Argo CD) | OpenShift Pipelines, OpenShift GitOps, bu repoya erişim |
| 06 | [Blue/Green Deployment](B-UygulamaTeslimi/06-BlueGreenDeployment/README.md) | İki Deployment + tek Route ile anlık geçiş | 05 (kavramsal devamı) |
| 07 | [Canary Deployment](B-UygulamaTeslimi/07-CanaryDeployment/README.md) | Ağırlıklı Route ile kademeli geçiş | 06 |
| **C** | **[Ağ ve Güvenlik](C-AgVeGuvenlik)** | | |
| 08 | [NetworkPolicy](C-AgVeGuvenlik/08-NetworkPolicy/README.md) | Default deny, namespace/pod bazlı izin, egress | — |
| 09 | [Mikro-Segmentasyon](C-AgVeGuvenlik/09-MicroSegmentation/README.md) | Katman/rol bazlı izolasyon | 08 |
| 10 | [Multus CNI](C-AgVeGuvenlik/10-MultusCNI/README.md) | Pod'a ikinci ağ arayüzü (macvlan) | 02 |
| 11 | [Güvenlik Testleri](C-AgVeGuvenlik/11-SecurityTests/README.md) | SCC/PSA, image signing | ⚠️ Image signing node reboot'u tetikleyebilir, aşağıdaki nota bakın |
| **D** | **[Operasyon](D-Operasyon)** | | |
| 12 | [Logging + LokiStack](D-Operasyon/12-Logging/README.md) | Application/audit logları → Loki (ODF S3) | ODF (Ceph RGW), 02 |
| 13 | [East-West Trafik Kontrolü](D-Operasyon/13-EastWestTrafficControl/README.md) | NetworkPolicy + OVN ACL logging | 08, 09, 12 |
| 14 | [MultiCluster Observability](D-Operasyon/14-MultiClusterObservability/README.md) | ACM Observability (Thanos, ODF S3) | ACM (MultiClusterHub), ODF |
| 15 | [ODF Performans Testi](D-Operasyon/15-ODFPerformanceTest/README.md) | fio ile IOPS / throughput / latency | ODF |
| 16 | [OADP Backup/Restore](D-Operasyon/16-OADP/README.md) | Velero ile namespace yedekleme/geri yükleme (ODF S3) | ODF (Ceph RGW). `dpa-odf`'i **bu rehber kurar**; 17 kullanır |
| **E** | **[Virtualization](E-Virtualization)** | | |
| 17 | [OpenShift Virtualization](E-Virtualization/17-Virtualization/README.md) | Template, ISO, golden image, live migration, snapshot, Multus VLAN, affinity, VM yedekleme | OpenShift Virtualization, ODF, NMState, 16 |
| 17.1 | ↳ [Windows Boot Source](E-Virtualization/17-Virtualization/windows/README.md) | Windows template'leri için imaj sağlamanın 4 yolu | 17, (yöntem 3 için) OpenShift Pipelines |
| 18 | [MTV ile Taşıma](E-Virtualization/18-MTV/README.md) | VMware vSphere / OVA'dan VM taşıma (provider, haritalar, plan) | Migration Toolkit for Virtualization, 17 |
| 19 | [Node Kaybında Otomatik Kurtarma](E-Virtualization/19-NodeHealthCheck/README.md) | NodeHealthCheck + Self Node Remediation: çöken node'u fence edip VM'leri başka node'da açma | 17; worker node'ları (control plane hariç) |

## POC Öncesi Kontrol

Gün başında cluster'ın ve kullanılacak operatörlerin hazır olduğunu doğrulayın:

```bash
oc get clusterversion
oc get nodes
oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'   # sorunlu ClusterOperator'lar
oc get storagecluster -n openshift-storage                               # ODF: Ready
oc get csv -A --no-headers -o custom-columns=CSV:.metadata.name,PHASE:.status.phase \
  | grep -iE '^(openshift-pipelines|openshift-gitops|rhacs|loki|cluster-logging|advanced-cluster|oadp|kubevirt|kubernetes-nmstate)' | sort -u
```

## Planlama Notları

- **Uzun sürenleri önceden başlatın:** LokiStack (12), MultiCluster Observability (14) kurulumları ve Windows imaj pipeline'ı (17.1, ~31 dk) arka planda kendiliğinden ilerler. Gün başında başlatılırsa sırası geldiğinde hazır olurlar. Windows ISO'su (~5 GB) önceden indirilmelidir.
- **Image signing (11) ayrı planlanmalı:** Rehberde belirtildiği gibi ilk adım test cluster'ında **tüm node'larda reboot rollout'u tetikledi**. Canlı ortamda bakım penceresi ve onayla yapılmalı; POC akışında sadece anlatılması önerilir.
- **Paylaşımlı kaynaklar:** 16 ve 17, cluster genelindeki bazı kaynakları (DPA, `openshift-cnv`, `openshift-virtualization-os-images`) etkileyebilir. Rehberlerde bu adımlar ayrıca işaretlenmiştir.
- **Temizlik:** Her rehberin sonunda kendi temizlik bölümü vardır.
