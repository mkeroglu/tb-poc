# 15 — ODF Performans Testi — fio ile IOPS / Throughput / Latency

> [← 14 — MultiCluster Observability](../14-MultiClusterObservability/README.md) · [POC akışı](../../README.md) · [16 — OADP Backup/Restore →](../16-OADP/README.md)

Bu doküman, ODF (OpenShift Data Foundation) üzerinde **fio** ile performans testinin **nasıl yapılacağını** anlatır. Komutlar, `ocs-storagecluster-ceph-rbd` (varsayılan, RWO block) storage class'ı ile sağlanan bir PVC üzerinde, bu repodaki cluster'da (OpenShift 4.22) **canlı çalıştırılıp doğrulanmıştır**.

---

## 1. Test Ortamını Kurma

```bash
oc create ns odf-perf-test

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fio-test-pvc
  namespace: odf-perf-test
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ocs-storagecluster-ceph-rbd   # test etmek istediğiniz storage class
  resources:
    requests:
      storage: 20Gi
EOF

oc run fio-bench -n odf-perf-test --image=docker.io/ljishen/fio:latest \
  --overrides='{"spec":{"containers":[{"name":"fio","image":"docker.io/ljishen/fio:latest","command":["sh","-c","sleep 3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"fio-test-pvc"}}]}}'

oc wait --for=condition=Ready pod/fio-bench -n odf-perf-test --timeout=60s
```

`docker.io/ljishen/fio` — sadece `fio` yüklü, hazır kullanılabilir bir image (public, bu clusterda test edildi, ekstra kurulum gerekmez).

---

## 2. IOPS Testi (Rastgele Okuma/Yazma)

```bash
oc exec fio-bench -n odf-perf-test -- fio --name=iops-test --directory=/data --size=2G \
  --rw=randrw --rwmixread=70 --bs=4k --ioengine=libaio --direct=1 --iodepth=32 --numjobs=4 \
  --runtime=30 --time_based --group_reporting
```

Çıktıda bakılacak alanlar:
- `read: IOPS=...` / `write: IOPS=...` — saniyedeki G/Ç işlem sayısı.
- `Disk stats: util=...` — **%90'ın altındaysa** disk doygunlaşmamış demektir, sonuç depolamanın gerçek tavanını yansıtmıyor olabilir; daha yüksek `--iodepth`/`--numjobs` ile tekrar deneyin.

---

## 3. Throughput Testi (Ardışık Okuma/Yazma, MB/s)

```bash
oc exec fio-bench -n odf-perf-test -- fio --name=throughput-test --directory=/data --size=2G \
  --rw=rw --rwmixread=50 --bs=1M --ioengine=libaio --direct=1 --iodepth=16 --numjobs=2 \
  --runtime=30 --time_based --group_reporting
```

Çıktıda bakılacak alanlar:
- `READ: bw=...` / `WRITE: bw=...` (Run status bölümünde, MB/s cinsinden) — bant genişliği.
- IOPS testinden **farklı amaç**: burada büyük blok (`1M`) + yüksek `iodepth` bilinçli olarak throughput'u maksimize eder, bu da latency'yi yükseltir (bu normal — throughput ve latency aynı testte ikisi birden optimize edilemez).

---

## 4. Latency Testi (Saf G/Ç Gecikmesi)

```bash
oc exec fio-bench -n odf-perf-test -- fio --name=latency-test --directory=/data --size=1G \
  --rw=randrw --rwmixread=70 --bs=4k --ioengine=libaio --direct=1 --iodepth=1 --numjobs=1 \
  --runtime=30 --time_based --group_reporting
```

`--iodepth=1` **kasıtlı** — kuyruklama olmadan tek bir G/Ç'nin gerçek round-trip süresini ölçer (IOPS testindeki `iodepth=32` ile latency ölçerseniz, kuyrukta bekleme süresi de gecikmeye karışır, yanıltıcı olur).

Çıktıda bakılacak alanlar:
- `clat (usec/msec): avg=...` — ortalama tamamlanma gecikmesi.
- `clat percentiles` satırındaki `50.00th` (medyan), `99.00th`, `99.99th` — **sadece ortalamaya bakmayın**, tail latency (p99/p99.9) gerçek kullanıcı deneyimini/SLA riskini ortalamadan çok daha iyi yansıtır.

---

## 5. Dikkat Edilecek Noktalar

- **Cluster paylaşımlıysa** (bu ortamdaki gibi, birden fazla namespace/tenant varsa), ölçümler diğer tenant'ların eşzamanlı yükünden etkilenir — sonuçlar "izole laboratuvar" sayıları değildir. Kararlı/karşılaştırılabilir sonuç istiyorsanız testi düşük yük saatinde veya dedike bir test cluster'ında tekrarlayın.
- **Aynı testi birkaç kez çalıştırıp** sonuçları karşılaştırın — tek bir çalıştırma, o anki arka plan yüküne bağlı olarak yanıltıcı olabilir.
- **`--direct=1`** kullanmayı unutmayın — bu, OS page cache'ini bypass eder, gerçekten diske gidildiğini garanti eder (aksi halde yüksek "IOPS" ölçüp aslında RAM'i test etmiş olabilirsiniz).
- Storage class'ı değiştirerek (`ocs-storagecluster-cephfs`, farklı bir storage class vb.) aynı testleri tekrarlayıp karşılaştırabilirsiniz.

---

## 6. Temizlik

```bash
oc delete namespace odf-perf-test
```
