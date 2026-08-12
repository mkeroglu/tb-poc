# OADP (Velero) Backup/Restore Demo Rehberi — ODF S3 Üzerinde

Bu doküman, **OADP (OpenShift API for Data Protection / Velero)** ile bir namespace'in tamamen silinip **backup'tan geri yüklenmesini** anlatır. Depolama için (Logging POC'sindeki gibi) cluster'da zaten kurulu olan **ODF (Ceph RGW, S3-uyumlu)** kullanılmıştır. Tüm adımlar bu repodaki cluster'da (OpenShift 4.22) **uçtan uca canlı test edilmiştir**: `oadp-demo` namespace'i içeriğiyle (Deployment, ConfigMap, Secret, Service) yedeklenmiş, namespace tamamen silinmiş, sonra backup'tan tam olarak (veri içerikleriyle) geri yüklenmiştir.

Senaryo sırası:

1. Ön koşul kontrolü (OADP operatörü, ODF S3 backend)
2. S3 bucket + credentials hazırlama (ODF/Ceph RGW)
3. `DataProtectionApplication` (DPA) oluşturma
4. Test namespace'i ve içinde kaynaklar oluşturma
5. Backup alma
6. Namespace'i silme (felaket simülasyonu)
7. Restore etme ve doğrulama (gerçek test çıktıları)
8. Bilinen uyarılar (zararsız, canlı testte görülen)
9. Temizlik

---

## 1. Ön Koşul Kontrolü

**a) OADP operatörü kurulu mu?**

```bash
oc get csv -n openshift-adp | grep -i oadp
```

Bu cluster'da OADP operatörü (`oadp-operator.v1.6.1`) zaten `openshift-adp` namespace'inde kurulu geldi — sadece `DataProtectionApplication` (DPA) yapılandırması eksikti.

Kurulu değilse:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-adp
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-adp
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.6
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

**b) S3 backend için ODF sağlıklı mı?**

Bu POC'nin [Logging rehberinde](../Logging/README.md) belgelendiği gibi, bu cluster'da **NooBaa sağlıksız** (`INVALID_SCHEMA_REPLY`), **Ceph RGW sağlıklı**. OADP için de aynı sebeple **Ceph RGW** (`ocs-storagecluster-ceph-rgw`) kullanıldı. Kendi ortamınızda önce ikisini de kontrol edin:

```bash
oc get noobaa -n openshift-storage
oc get cephobjectstore -n openshift-storage
```

---

## 2. S3 Bucket + Credentials (ODF/Ceph RGW)

```yaml
# oadp-bucket-obc.yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: oadp-bucket-odf
  namespace: openshift-adp
spec:
  generateBucketName: oadp-bucket-odf
  storageClassName: ocs-storagecluster-ceph-rgw
```

```bash
oc apply -f oadp-bucket-obc.yaml
oc get obc oadp-bucket-odf -n openshift-adp
```

✅ **Gerçek çıktı:** `PHASE: Bound` (birkaç saniye içinde).

Velero'nun beklediği **AWS credentials INI formatında** bir secret üretin:

```bash
ACCESS_KEY=$(oc get secret oadp-bucket-odf -n openshift-adp -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret oadp-bucket-odf -n openshift-adp -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

cat > cloud-credentials <<EOF
[default]
aws_access_key_id=${ACCESS_KEY}
aws_secret_access_key=${SECRET_KEY}
EOF

oc create secret generic cloud-credentials -n openshift-adp --from-file=cloud=cloud-credentials
```

> **Not:** Anahtar dosyanın içindeki key adı **`cloud`** olmalı — DPA'nın `credential.key` alanı bunu referans alır.

---

## 3. DataProtectionApplication (DPA)

```yaml
# dpa.yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-odf
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
    nodeAgent:
      enable: false          # PV dosya-seviyesi (kopia/restic) yedeklemesi kapalı — bkz. Bölüm 8
      uploaderType: kopia     # enable:false olsa da alan zorunlu (CRD validasyonu)
  backupLocations:
    - velero:
        provider: aws
        default: true
        credential:
          name: cloud-credentials
          key: cloud
        objectStorage:
          bucket: REPLACE_ME_BUCKET_NAME   # Bolum 2'deki OBC'nin urettigi gercek bucket adi
          prefix: velero
        config:
          region: us-east-1
          s3Url: http://rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc:80
          s3ForcePathStyle: "true"
```

```bash
BUCKET=$(oc get cm oadp-bucket-odf -n openshift-adp -o jsonpath='{.data.BUCKET_NAME}')
sed "s/REPLACE_ME_BUCKET_NAME/${BUCKET}/" dpa.yaml | oc apply -f -

oc get backupstoragelocation -n openshift-adp
oc get pods -n openshift-adp
```

✅ **Gerçek çıktı:** `backupstoragelocation dpa-odf-1` → `PHASE: Available`, `DEFAULT: true`; `velero-xxxxx` pod'u `1/1 Running`.

> **Not (Logging POC'sindeki gibi):** RGW endpoint'i **HTTP (port 80)** ile verildi, HTTPS değil — trafik cluster-internal (ClusterIP) olduğu için POC'de sertifika/CA karmaşasından kaçınmak amacıyla. Üretimde CA bundle ile HTTPS tercih edin.

---

## 4. Test Namespace'i ve Kaynaklar

```yaml
# demo-workload.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: oadp-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
  namespace: oadp-demo
data:
  greeting: "merhaba-oadp-restore-testi"
  created-at: "2026-08-12"
---
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
  namespace: oadp-demo
type: Opaque
stringData:
  password: "s3cr3t-oadp-demo"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: oadp-demo
  labels:
    app: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo
          image: busybox:1.36
          command: ["sh", "-c", "echo $(GREETING) from $(POD_NAME); sleep 3600"]
          env:
            - name: GREETING
              valueFrom:
                configMapKeyRef:
                  name: demo-config
                  key: greeting
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: oadp-demo
spec:
  selector:
    app: demo-app
  ports:
    - port: 8080
      targetPort: 8080
```

```bash
oc apply -f demo-workload.yaml
oc get deployment,cm,secret,svc -n oadp-demo
```

✅ **Gerçek çıktı:** `deployment.apps/demo-app` → `2/2 READY`.

---

## 5. Backup Alma

```yaml
# backup.yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: oadp-demo-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - oadp-demo
  storageLocation: dpa-odf-1
  ttl: 720h0m0s
```

```bash
oc apply -f backup.yaml
oc get backup.velero.io oadp-demo-backup -n openshift-adp -o jsonpath='{.status}'
```

> **Dikkat:** `oc get backup` (tam kaynak adı vermeden) bu cluster'da **`backups.postgresql.cnpg.noobaa.io`** (CloudNativePG operatörünün kaynak tipi) ile çakışıp yanlış kaynağı sorgulayabilir — kısa isim çakışması. Her zaman **`oc get backup.velero.io`** kullanın.

✅ **Gerçek çıktı:**

```json
{"completionTimestamp":"...","phase":"Completed","progress":{"itemsBackedUp":58,"totalItems":58},...}
```

---

## 6. Namespace'i Silme (Felaket Simülasyonu)

```bash
oc delete namespace oadp-demo --wait=true
oc get ns oadp-demo
```

✅ **Gerçek çıktı:** `Error from server (NotFound): namespaces "oadp-demo" not found` — namespace, içindeki Deployment/ConfigMap/Secret/Service ile birlikte **tamamen silindi**.

---

## 7. Restore ve Doğrulama (gerçek test çıktıları)

```yaml
# restore.yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: oadp-demo-restore
  namespace: openshift-adp
spec:
  backupName: oadp-demo-backup
```

```bash
oc apply -f restore.yaml
oc get restore.velero.io oadp-demo-restore -n openshift-adp -o jsonpath='{.status}'
```

✅ **Gerçek çıktı:**

```json
{"completionTimestamp":"...","phase":"Completed","progress":{"itemsRestored":44,"totalItems":44},"warnings":10}
```

**Kaynakların ve verilerin gerçekten geri geldiğini doğrulama:**

```bash
oc get deployment,cm,secret,svc -n oadp-demo
oc get cm demo-config -n oadp-demo -o jsonpath='{.data}'
oc get secret demo-secret -n oadp-demo -o jsonpath='{.data.password}' | base64 -d
```

✅ **Gerçek çıktı:**

```
deployment.apps/demo-app   2/2 READY   (yeniden hiç müdahale etmeden Running'e geçti)

{"created-at":"2026-08-12","greeting":"merhaba-oadp-restore-testi"}   <-- ConfigMap verisi birebir geri geldi

s3cr3t-oadp-demo   <-- Secret icerigi birebir geri geldi
```

**Sonuç: namespace, Deployment (replikalarıyla), ConfigMap ve Secret — hepsi içerikleriyle birebir restore edildi.**

---

## 8. Bilinen Uyarılar (canlı testte görülen, zararsız)

Restore `Completed` oldu ama **10 uyarı** verdi. `velero restore describe --details` ile incelendi:

```bash
POD=$(oc get pods -n openshift-adp -l app.kubernetes.io/name=velero -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-adp "$POD" -c velero -- ./velero restore describe oadp-demo-restore --details
```

Tüm uyarılar şu iki kategoriden:

1. **Cluster-scoped kaynaklar zaten mevcut** (`CustomResourceDefinition:clusterserviceversions.operators.coreos.com`, `SecurityContextConstraints:restricted-v2`) — bunlar cluster genelinde paylaşılan kaynaklar, backup'taki haliyle üzerine yazılmadı (**doğru davranış**, aksi halde cluster'ın geri kalanını etkilerdi).
2. **Namespace içinde otomatik üretilen kaynaklar zaten mevcut** (`pipeline-dockercfg-xxxxx` secret, `istio-ca-crl`/`istio-ca-root-cert`/`kube-root-ca.crt`/`openshift-service-ca.crt` ConfigMap'leri, `openshift-pipelines-edit`/`pipelines-scc-rolebinding` RoleBinding'leri) — namespace yeniden oluşturulur oluşturulmaz OpenShift'in kendi controller'ları (service account controller, CA injector, OpenShift Pipelines operatörü vb.) bunları **zaten otomatik olarak yeniden üretiyor**; Velero restore çalıştığında bunlar zaten mevcut olduğu için "already exists" uyarısı veriyor. **Gerçek bir veri kaybı değil.**

**Pratik sonuç:** Bu tür uyarıları görmek normal ve beklenen — asıl kontrol edilmesi gereken, **sizin uygulamanıza ait** kaynakların (Deployment, ConfigMap, Secret, kendi RoleBinding'leriniz vb.) içerikleriyle geri gelip gelmediğidir (Bölüm 7'de doğrulandı).

---

## 9. Temizlik

```bash
oc delete restore.velero.io oadp-demo-restore -n openshift-adp
oc delete backup.velero.io oadp-demo-backup -n openshift-adp
oc delete ns oadp-demo
oc delete dpa dpa-odf -n openshift-adp
oc delete secret cloud-credentials -n openshift-adp
oc delete obc oadp-bucket-odf -n openshift-adp
```

---

## Özet Tablo

| Bileşen | Namespace | Rolü |
|---|---|---|
| OADP Operator | `openshift-adp` | Velero'yu ve `DataProtectionApplication` CRD'sini yönetir |
| `ObjectBucketClaim` (Ceph RGW) | `openshift-adp` | Backup'ların yazılacağı S3 bucket'ı sağlar |
| `DataProtectionApplication` (`dpa-odf`) | `openshift-adp` | Velero'nun hangi S3'e, hangi credential'la yazacağını tanımlar |
| `Backup` (`velero.io`) | `openshift-adp` | Belirtilen namespace'in tüm Kubernetes kaynaklarını S3'e yedekler |
| `Restore` (`velero.io`) | `openshift-adp` | Bir backup'tan namespace + kaynakları geri yükler |

**Altın kurallar:**
1. `oc get backup` yerine her zaman **`oc get backup.velero.io`** kullanın — bu cluster'da CloudNativePG'nin `backups` kaynağıyla isim çakışması var.
2. NooBaa sağlıksızsa (bkz. [Logging README](../Logging/README.md)) **Ceph RGW**'ye geçin — OADP için de aynı S3 backend mantığı geçerli.
3. Restore'daki "already exists" uyarıları çoğunlukla **zararsızdır** — asıl doğrulama, kendi uygulama kaynaklarınızın **içerikleriyle** (ConfigMap/Secret verisi, replika sayısı vb.) geri geldiğini kontrol etmektir, sadece `phase: Completed`'e güvenmeyin.
4. Bu POC'de PV/dosya-seviyesi yedekleme (`nodeAgent`/kopia) **kapalı bırakıldı** — sadece Kubernetes API kaynakları (Deployment, ConfigMap, Secret, Service vb.) test edildi. Kalıcı disk verisi olan (PVC bağlı) uygulamalar için `nodeAgent.enable: true` yapıp Backup'a `defaultVolumesToFsBackup: true` eklemeniz gerekir — bu POC kapsamı dışında bırakıldı.
