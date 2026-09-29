# OpenShift Logging + LokiStack (ODF/S3) Kurulum Rehberi

Bu doküman, **OpenShift Logging (Cluster Logging Operator)** + **Loki Operator (LokiStack)** kurup, **application** ve **audit** loglarını Loki'ye yönlendirmeyi anlatır. Depolama (S3) için ayrı bir external S3 yerine cluster'da zaten kurulu olan **ODF (OpenShift Data Foundation)**'ın S3-uyumlu object storage'ı kullanılmıştır. Tüm adımlar bu repodaki cluster'da (OpenShift 4.22) **uçtan uca canlı test edilmiştir** — `trt-ocp-poc` namespace'ine test pod'u ile log basılmış, hem application hem audit tenant'ından gerçekten Loki'ye ulaştığı LokiStack API'siyle doğrulanmıştır.

Senaryo sırası:

1. Ön koşul kontrolü (Loki Operator / Cluster Logging Operator kurulabilir mi, ODF sağlıklı mı)
2. Operatörlerin kurulması
3. LokiStack için S3 object storage hazırlama (ODF)
4. LokiStack oluşturma
5. ClusterLogForwarder ile application + audit loglarını Loki'ye yönlendirme
6. Doğrulama (gerçek test çıktıları)
7. **Gerçek tuzaklar** (canlı ortamda karşılaşılan ve çözülen 3 gerçek sorun)
8. Temizlik

---

## 1. Ön Koşul Kontrolü

**a) Gerekli operatörler katalogda mevcut mu?**

```bash
oc get packagemanifest -n openshift-marketplace | grep -iE "^loki-operator|^cluster-logging"
```

✅ Bu clusterda ikisi de **Red Hat Operators** kataloğunda, `stable-6.6` default channel ile mevcut.

**b) S3 backend için ODF sağlıklı mı?**

LokiStack'in obje depolaması için iki seçenek düşünüldü — ODF'in **iki farklı S3 motoru** var, ve bu clusterda ikisi de kurulu olsa da **sadece biri sağlıklıydı**:

```bash
oc get noobaa -n openshift-storage
oc get cephobjectstore -n openshift-storage
```

- **NooBaa (MCG)** — `Available: False`, `INVALID_SCHEMA_REPLY SERVER system_api#/methods/read_system` hatası veriyordu (bu kuruluma başlamadan haftalar önceden beri süren, önceden var olan bir sorun — bu POC'nin sebep olduğu bir şey değil).
- **Ceph RGW (`CephObjectStore`)** — `PHASE: Ready`, sağlıklı.

**Sonuç:** LokiStack'in S3 backend'i için **NooBaa yerine Ceph RGW** kullanıldı (`ocs-storagecluster-ceph-rgw` storage class). Kendi ortamınızda önce ikisini de kontrol edin, sağlıklı olanı kullanın.

---

## 2. Operatörlerin Kurulması

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat
  namespace: openshift-operators-redhat
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.6
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
    - openshift-logging
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.6
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Kurulumu doğrulayın:

```bash
oc get csv -n openshift-operators-redhat
oc get csv -n openshift-logging
```

✅ **Gerçek çıktı (~1 dakika sonra):** her iki operatör de `PHASE: Succeeded`.

---

## 3. LokiStack İçin S3 Object Storage (ODF/Ceph RGW)

`ObjectBucketClaim` (OBC) ile ODF üzerinden S3-uyumlu bir bucket oluşturun:

```yaml
# loki-bucket-obc.yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: loki-bucket-odf
  namespace: openshift-logging
spec:
  generateBucketName: loki-bucket-odf
  storageClassName: ocs-storagecluster-ceph-rgw   # NooBaa saglıksızsa RGW kullanın
```

```bash
oc apply -f loki-bucket-obc.yaml
oc get obc loki-bucket-odf -n openshift-logging
```

✅ **Gerçek çıktı:** `PHASE: Bound` (birkaç saniye içinde — NooBaa ile denendiğinde saatlerce `Pending` kalmıştı, bkz. Bölüm 7).

OBC, bir ConfigMap (bucket adı/host/port) ve bir Secret (access/secret key) oluşturur. Bunlardan LokiStack'in beklediği formatta yeni bir secret üretin:

```bash
ACCESS_KEY=$(oc get secret loki-bucket-odf -n openshift-logging -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret loki-bucket-odf -n openshift-logging -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
BUCKET=$(oc get cm loki-bucket-odf -n openshift-logging -o jsonpath='{.data.BUCKET_NAME}')

oc create secret generic logging-loki-s3 -n openshift-logging \
  --from-literal=access_key_id="$ACCESS_KEY" \
  --from-literal=access_key_secret="$SECRET_KEY" \
  --from-literal=bucketnames="$BUCKET" \
  --from-literal=endpoint="http://rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc:80" \
  --from-literal=region="us-east-1"
```

> **Not:** Endpoint için **HTTP (port 80)** kullanıldı, HTTPS (443) değil. RGW'nin sertifikası Ceph'in kendi internal CA'sıyla imzalı; LokiStack'e ayrıca CA bundle tanıtmaktansa, bu trafik zaten cluster-internal (ClusterIP, dışarıdan erişilemez) olduğu için POC amaçlı HTTP yeterli ve daha basit. Üretimde CA bundle ile HTTPS tercih edin.

---

## 4. LokiStack Oluşturma

```yaml
# lokistack.yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.demo              # POC/demo boyutu — bkz. Bölüm 7 (üretimde yetersiz kalabilir)
  storage:
    schemas:
      - version: v13
        effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: ocs-storagecluster-ceph-rbd   # WAL/index icin RWO block storage
  tenants:
    mode: openshift-logging   # OpenShift'in kendi RBAC/auth'unu kullanan hazır çok-kiracılı mod
```

```bash
oc apply -f lokistack.yaml
oc get pods -n openshift-logging -l app.kubernetes.io/instance=logging-loki
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions}'
```

✅ **Gerçek çıktı (~90 saniye sonra):** compactor, distributor, gateway (x2), index-gateway, ingester, querier, query-frontend — hepsi `Running`, `status.conditions` içinde `type: Ready, status: "True", reason: ReadyComponents`.

---

## 5. ClusterLogForwarder: Application + Audit → Loki

**a) Collector için ServiceAccount + RBAC** (sadece application + audit toplama izni — infrastructure logs kasıtlı olarak dışarıda bırakıldı):

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: collector
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collector-application-logs
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
roleRef:
  kind: ClusterRole
  name: collect-application-logs
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collector-audit-logs
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
roleRef:
  kind: ClusterRole
  name: collect-audit-logs
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collector-logs-writer
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
roleRef:
  kind: ClusterRole
  name: logging-collector-logs-writer
  apiGroup: rbac.authorization.k8s.io
EOF
```

**b) ClusterLogForwarder:**

```yaml
# clusterlogforwarder.yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  serviceAccount:
    name: collector
  collector:
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
      limits:
        memory: 4Gi          # bkz. Bölüm 7 — varsayılan limit bu clusterda OOMKilled veriyordu
  inputs:
    - name: app-logs
      type: application
      application: {}        # TÜM namespace'ler — production kullanımı; POC testinde daraltıldı, bkz. Bölüm 7
    - name: audit-logs
      type: audit
      audit: {}
  outputs:
    - name: loki-output
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
          namespace: openshift-logging
        authentication:
          token:
            from: serviceAccount
      tls:
        ca:
          key: service-ca.crt
          configMapName: openshift-service-ca.crt
  pipelines:
    - name: app-and-audit-to-loki
      inputRefs:
        - app-logs
        - audit-logs
      outputRefs:
        - loki-output
```

```bash
oc apply -f clusterlogforwarder.yaml
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector
```

✅ **Gerçek çıktı:** her node'da bir `collector-xxxxx` pod'u (DaemonSet), `1/1 Running`.

---

## 6. Doğrulama (gerçek test çıktıları)

**a) Test için log üretimi:**

```bash
oc run log-test-emitter -n trt-ocp-poc --image=busybox:1.36 --restart=Never -- \
  sh -c 'for i in $(seq 1 20); do echo "LOKI_DEMO_MARKER_line_$i $(date)"; sleep 1; done; sleep 180'
```

**b) Loki gateway'ini sorgulamak için okuma yetkisi olan bir token:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: loki-log-reader
rules:
  - apiGroups: [loki.grafana.com]
    resources: [application, audit]
    resourceNames: [logs]
    verbs: [get]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reader
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: log-reader-binding
subjects:
  - kind: ServiceAccount
    name: log-reader
    namespace: openshift-logging
roleRef:
  kind: ClusterRole
  name: loki-log-reader
  apiGroup: rbac.authorization.k8s.io
EOF

TOKEN=$(oc create token log-reader -n openshift-logging --duration=1h)
ROUTE=$(oc get route logging-loki -n openshift-logging -o jsonpath='https://{.spec.host}')
```

**c) Application tenant'ından sorgu:**

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'query={k8s_namespace_name="trt-ocp-poc"} |= "LOKI_DEMO_MARKER"' \
  --data-urlencode "start=$(($(date +%s)-300))000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  "$ROUTE/api/logs/v1/application/loki/api/v1/query_range"
```

✅ **Gerçek çıktı:** `"status":"success"`, stream `k8s_namespace_name=trt-ocp-poc, k8s_pod_name=log-test-emitter`, `values` içinde `LOKI_DEMO_MARKER_line_1..20` satırlarının tamamı, tam JSON log kaydı (`kubernetes.*`, `@timestamp`, `message` alanlarıyla).

**d) Audit tenant'ından sorgu:**

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'query={log_type="audit"}' \
  --data-urlencode "start=$(($(date +%s)-600))000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=3' \
  "$ROUTE/api/logs/v1/audit/loki/api/v1/query_range"
```

✅ **Gerçek çıktı:** `"status":"success"`, `master02`/`master03` node'larından gerçek kube-apiserver audit kayıtları (`annotations."authorization.k8s.io/decision":"allow"`, `"authorization.k8s.io/reason":"RBAC: allowed by ClusterRoleBinding ..."` gibi alanlarla).

**Sonuç: hem application hem audit logları uçtan uca Loki'ye ulaşıyor, gateway üzerinden sorgulanabiliyor.**

---

## 7. Gerçek Tuzaklar (canlı ortamda karşılaşılan)

### 7.1 NooBaa değil, sağlıklı olan S3 motorunu seçin

ODF'te **iki ayrı S3 uyumlu backend** olabilir: NooBaa (MCG) ve Ceph RGW. Bu cluster'da NooBaa günlerdir `INVALID_SCHEMA_REPLY` hatasıyla sağlıksızdı; `storageClassName: openshift-storage.noobaa.io` ile oluşturulan OBC **süresiz `Pending`** kaldı. Kurulumdan önce ikisini de kontrol edip **sağlıklı olanı** seçin (Bölüm 1b).

### 7.2 Collector'ın varsayılan memory limiti, yoğun cluster'larda yetersiz

Bu cluster ~90 namespace barındırıyor. ClusterLogForwarder'ı `spec.collector.resources` belirtmeden oluşturunca collector pod'ları (vector) sürekli **`OOMKilled`** oldu (default limit çok düşük). Çözüm: `spec.collector.resources.limits.memory` değerini yükseltmek (bu POC'de `4Gi`'ye çıkarıldı, o zaman stabil kaldı).

### 7.3 `1x.demo` boyutu, gerçek cluster çapında application log hacmi için yetersiz

LokiStack `1x.demo` boyutu (tek replikalı, demo amaçlı) varsayılan **`ingestionRate: 4MB/sn`** limitine sahip. `application` input'u **tüm namespace'leri** kapsayacak şekilde (`application: {}`, filtre yok) bırakıldığında, cluster'ın gerçek toplam log hacmi bu limiti fazlasıyla aştı — distributor **tüm** application yazmalarını reddetti:

```
level=error ... msg="write operation failed" details="ingestion rate limit exceeded for user
application (limit: 4194304 bytes/sec) ..." org_id=application
```

`spec.limits.global.ingestion.ingestionRate` değerini (bu POC'de `40` MB/sn'ye) yükseltmek hatayı durdurdu, ama tek-repliklı `1x.demo`'nun gerçek üretim hacmini kaldırması yine de garanti değil. **İki pratik seçenek:**

- **Üretimde:** LokiStack boyutunu gerçek log hacmine göre seçin (`1x.small`/`1x.medium`/`1x.large` — Red Hat dokümantasyonundaki ingestion-rate tablosuna bakın), `1x.demo`'yu sadece gerçek demo/test için kullanın.
- **Kapsamı daraltmak isterseniz:** `spec.inputs[].application.includes` ile sadece ilgilendiğiniz namespace'leri toplayın (bu POC'nin canlı testinde yapılan budur — `includes: [{namespace: trt-ocp-poc}]` — hem ingestion limitine takılmadı hem de diğer tenant'ların log hacmini gereksiz yere Loki'ye çekmedi):

```yaml
inputs:
  - name: app-logs
    type: application
    application:
      includes:
        - namespace: trt-ocp-poc
```

---

## 8. Temizlik

```bash
oc delete clusterlogforwarder collector -n openshift-logging
oc delete lokistack logging-loki -n openshift-logging
oc delete secret logging-loki-s3 -n openshift-logging
oc delete obc loki-bucket-odf -n openshift-logging
oc delete clusterrolebinding collector-application-logs collector-audit-logs collector-logs-writer log-reader-binding
oc delete clusterrole loki-log-reader
oc delete subscription loki-operator -n openshift-operators-redhat
oc delete subscription cluster-logging -n openshift-logging
oc delete ns openshift-logging openshift-operators-redhat
```

---

## Özet Tablo

| Bileşen | Namespace | Rolü |
|---|---|---|
| Loki Operator | `openshift-operators-redhat` | LokiStack CRD'sini yönetir |
| Cluster Logging Operator | `openshift-logging` | ClusterLogForwarder CRD'sini yönetir |
| `ObjectBucketClaim` (Ceph RGW) | `openshift-logging` | LokiStack'in S3 backend'i (chunk depolama) |
| `LokiStack` (`logging-loki`) | `openshift-logging` | Loki'nin kendisi (distributor/ingester/querier/gateway vb.) |
| `collector` ServiceAccount | `openshift-logging` | Vector collector pod'larının kimliği — sadece app+audit toplama izinli |
| `ClusterLogForwarder` (`collector`) | `openshift-logging` | Hangi loglar (application, audit) nereye (LokiStack) gidecek |

**Altın kurallar:**
1. ODF'te birden fazla S3 backend'i varsa (NooBaa + RGW), kurulumdan önce **sağlıklı olanı** seçin — sağlıksız NooBaa'yla OBC süresiz `Pending` kalır, hiç hata mesajı vermez.
2. Yoğun cluster'larda collector'a **mutlaka** `spec.collector.resources` ile explicit memory limiti verin — varsayılan limit OOMKilled'e sebep olabilir.
3. `1x.demo` LokiStack boyutu **gerçek üretim log hacmini kaldırmayabilir** — ya boyutu büyütün ya da `application.includes` ile kapsamı daraltın; aksi halde distributor sessizce (sizin loglarınız dahil) veri kaybeder.
4. Doğrulamayı LokiStack gateway API'sine gerçek bir sorgu atarak yapın (`/api/logs/v1/<tenant>/loki/api/v1/query_range`) — pod'ların `Running` olması, verinin gerçekten Loki'ye ulaştığı anlamına gelmez.
