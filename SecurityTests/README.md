# Güvenlik Testleri (6.2)

Bu doküman iki ayrı güvenlik konusunu kapsar:

1. **[SCC / PSA Politikaları](#1-scc--psa-politikaları)** — `psa-scc-test` namespace'inde **canlı test edilmiştir**.
2. **[Image Signing](#2-image-signing)** — **canlı test edilmemiştir**. Sebebi aşağıda açıklanıyor: bu POC kapsamında denenen ilk adım, bu clusterda **beklenmedik şekilde tüm node'larda (master+worker) bir reboot rollout'u tetikledi**. O yüzden burada sadece **nasıl yapılacağı**, gerçek komutlarla ve bu riskle birlikte anlatılıyor — kararı ve zamanlamayı siz vermelisiniz.

---

## 1. SCC / PSA Politikaları

### Kavram: İki Bağımsız Kapı

OpenShift'te bir pod'un ayrıcalıklı bir şey yapabilmesi (root çalışmak, privileged mod, hostPath vb.) için **iki ayrı, birbirinden bağımsız** admission kapısından geçmesi gerekir:

1. **PSA (Pod Security Admission)** — upstream Kubernetes standardı. Namespace'in `pod-security.kubernetes.io/enforce` label'ına göre (`restricted` / `baseline` / `privileged`) pod **spec**'ini statik olarak kontrol eder. **Kim çalıştırıyor olursa olsun**, sadece pod tanımına bakar.
2. **SCC (SecurityContextConstraints)** — OpenShift'e özgü. Pod'u **kimin oluşturduğuna ve/veya hangi ServiceAccount ile çalışacağına** bakarak, o kimliğin **kullanmaya yetkili olduğu** SCC'ler arasından pod spec'ine uyanı arar.

**İkisi de "evet" demeden pod çalışmaz.** Aşağıdaki testler bunu üç senaryoyla kanıtlıyor.

> **⚠️ Kritik metodoloji notu (canlı testte keşfedildi):** SCC admission, isteği yapan **kullanıcının/service account'ın** yetkisine bakar — pod'un `spec.serviceAccountName`'i değil, **`oc apply`/`oc create`'i kimin çalıştırdığı** da devreye girer. Bu POC'de `system:admin` (cluster-admin) ile test ederken, cluster-admin'in **her SCC'yi** kullanma yetkisi olduğu için testler yanlışlıkla "izin verildi" sonucu üretti — namespace'in gerçek (admin olmayan) bir kullanıcısının/SA'sının göreceği kısıtlamayı yansıtmıyordu. **Doğru test için `oc create --as=system:serviceaccount:<ns>:<sa>` ile impersonation şart** — aksi halde kendi admin yetkiniz test ettiğiniz kısıtlamayı sessizce by-pass eder.

### Test Ortamı

```bash
oc create ns psa-scc-test
oc label namespace psa-scc-test pod-security.kubernetes.io/enforce=restricted --overwrite

# Cluster-admin OLMAYAN, gerçekçi bir kimlik: sadece "edit" yetkili bir SA
oc create sa tester-sa -n psa-scc-test
oc create rolebinding tester-edit -n psa-scc-test --clusterrole=edit --serviceaccount=psa-scc-test:tester-sa
```

Test edilen pod (hepsinde aynı, sadece namespace label'ı ve SCC izni değişiyor):

```yaml
# root-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: root-test
  namespace: psa-scc-test
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["id"]
      securityContext:
        runAsUser: 0
```

### Test 1: Hiçbir ek SCC izni yok, PSA = `restricted` → SCC katmanında reddedilmeli

```bash
oc create -f root-pod.yaml --as=system:serviceaccount:psa-scc-test:tester-sa
```

✅ **Gerçek çıktı (kısaltılmış):**

```
Error from server (Forbidden): ... pods "root-test" is forbidden: unable to validate against any security context constraint:
[... "anyuid": Forbidden: not usable by user or serviceaccount ...
 provider restricted-v2: .containers[0].runAsUser: Invalid value: 0: must be in the ranges: [1001570000, 1001579999]
 provider restricted-v3: .containers[0].runAsUser: Invalid value: 0: must be in the ranges: [1000, 65534]
 ... "privileged": Forbidden: not usable by user or serviceaccount]
```

`tester-sa`'nın erişebildiği tek uygun SCC'ler (`restricted-v2`/`v3`) namespace'in ayrılmış UID aralığını zorluyor, `0` bu aralıkta olmadığı için reddediliyor. Diğer tüm SCC'ler (`anyuid`, `privileged` vb.) zaten "not usable by user or serviceaccount" — yani bu SA'nın onları kullanma **yetkisi** hiç yok.

### Test 2: SCC izni verildi (`anyuid`), ama PSA hâlâ `restricted` → PSA katmanında reddedilmeli

```bash
oc adm policy add-scc-to-user anyuid -z tester-sa -n psa-scc-test

oc create -f root-pod.yaml --as=system:serviceaccount:psa-scc-test:tester-sa
```

✅ **Gerçek çıktı:**

```
Error from server (Forbidden): ... violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true,
runAsUser=0 (container "test" must not set runAsUser=0), seccompProfile ...
```

**Bu, iki katmanın gerçekten bağımsız olduğunun kanıtı:** SCC artık izin veriyor (`anyuid` atandı), ama PSA hâlâ **kendi başına** reddediyor — SCC'nin "evet" demesi PSA'yı atlatmıyor.

### Test 3: İkisi de izin veriyor → gerçekten root olarak çalışmalı

```bash
oc label namespace psa-scc-test pod-security.kubernetes.io/enforce=baseline --overwrite

oc create -f root-pod.yaml --as=system:serviceaccount:psa-scc-test:tester-sa
```

✅ **Gerçek çıktı:**

```bash
oc logs root-test -n psa-scc-test
# uid=0(root) gid=0(root) groups=0(root),10(wheel)

oc get pod root-test -n psa-scc-test -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
# anyuid
```

**Gerçekten root olarak çalıştı** — hem PSA (`baseline`, root'a izin verir) hem SCC (`anyuid`, açıkça verildi) aynı anda "evet" dediğinde.

### Özet

| # | PSA (`enforce`) | SCC izni (`tester-sa`) | Sonuç |
|---|---|---|---|
| 1 | `restricted` | yok (sadece `restricted-v2/v3`) | ❌ SCC reddetti |
| 2 | `restricted` | `anyuid` verildi | ❌ PSA reddetti |
| 3 | `baseline` | `anyuid` verildi | ✅ Çalıştı, gerçekten `uid=0` |

**Altın kural:** Bu iki katmandan sadece birini gevşetmek yetmez, güvenlik testlerinde ikisini de ayrı ayrı doğrulayın — ve **asla cluster-admin kimliğiyle test etmeyin**, `--as=system:serviceaccount:<ns>:<sa>` ile gerçek çalışma zamanı kimliğini impersonate edin.

### Temizlik

```bash
oc delete namespace psa-scc-test
```

---

## 2. Image Signing

### Kavram

OpenShift 4.14+'ta, `ClusterImagePolicy` (cluster geneli) ve `ImagePolicy` (namespace bazlı) kaynakları (`config.openshift.io/v1`) ile **sigstore tabanlı imaj imza doğrulaması** yapılabilir: belirli bir registry/repository scope'undan (`spec.scopes`) çekilen imajların, tanımlı bir **root of trust** (bir public key, Fulcio+Rekor, veya kendi PKI'nız) ile imzalanmış olması **zorunlu kılınabilir**. İmza doğrulanamayan imajların **pull edilmesi CRI-O seviyesinde engellenir** — pod `ImagePullBackOff`'ta kalır.

### ⚠️ Canlı Test Edilmedi — Gerçek Risk Bulgusu

Bu POC kapsamında bir `ClusterImagePolicy` oluşturmayı denedik (test amaçlı, gerçek bir imzayla eşleşmeyen bir public key ile, `quay.io/prometheus/busybox` scope'unda). Sonuç:

```bash
oc get mcp
# NAME     ...  UPDATED   UPDATING   ...
# master   ...  False     True       ...   <-- 3 master node reboot rollout'una girdi
# worker   ...  False     True       ...   <-- 3 worker node reboot rollout'una girdi
```

**`ClusterImagePolicy` oluşturmak, arka planda bir `MachineConfig` üretir ve bu, cluster'daki TÜM node'larda (control plane dahil) bir rolling reboot/drain döngüsünü tetikler.** Bu, namespace-scope'lu, düşük riskli bir değişiklik değil — **cluster genelinde, üretim etkisi olan bir bakım penceresi işlemidir**. Bu POC'de policy hemen silindi ve cluster ~10-15 dakika içinde stabil hâle döndü, ama bu **planlanmadan** yapılmamalı.

### Nasıl Yapılır (siz kendi ortamınızda, planlı bir bakım penceresinde deneyin)

**1) Bir imza anahtarı üretin** (gerçek bir üretim akışında `cosign generate-key-pair` kullanılır; burada test için düz `openssl` ile de aynı formatta bir anahtar üretilebilir):

```bash
openssl ecparam -genkey -name prime256v1 -noout -out signing-key.pem
openssl ec -in signing-key.pem -pubout -out signing-key-pub.pem
PUBKEY_B64=$(base64 -w0 signing-key-pub.pem)
```

**2) İmajınızı bu anahtarla imzalayın** (gerçek akış — `cosign` gerekir, bu POC'de yapılmadı):

```bash
cosign sign --key signing-key.pem <registry>/<repo>/<imaj>:<tag>
```

**3) `ClusterImagePolicy` oluşturun:**

```yaml
apiVersion: config.openshift.io/v1
kind: ClusterImagePolicy
metadata:
  name: require-signed-myapp
spec:
  scopes:
    - REPLACE_ME_REGISTRY/REPLACE_ME_REPO   # örn. quay.io/benim-org/benim-app
  policy:
    rootOfTrust:
      policyType: PublicKey
      publicKey:
        keyData: ${PUBKEY_B64}
```

```bash
oc apply -f cluster-image-policy.yaml
```

**4) Uygulamadan önce mutlaka bekleyin ve doğrulayın:**

```bash
watch oc get mcp
# master ve worker pool'ları tekrar UPDATED:True, UPDATING:False, DEGRADED:False olana kadar bekleyin
```

**5) Test edin:**

```bash
# İmzasız/yanlış imzalı bir imaj -> ImagePullBackOff beklenir
oc run test --image=<scope-icindeki-imzasiz-imaj> --restart=Never

# İmzalı imaj -> normal calismali
oc run test2 --image=<imzali-imaj> --restart=Never
```

### Pratik Öneriler

1. **Önce `ImagePolicy` (namespace-scope'lu) ile başlayın**, tüm cluster'ı değil tek bir test namespace'ini etkiler — yine de aynı MachineConfig/reboot mekanizmasını tetikleyip tetiklemediğini önce küçük ölçekte doğrulayın.
2. **Bakım penceresi planlayın** — bu, "hemen deneyelim" ile test edilecek bir özellik değil, node reboot'ları normal iş yükü kesintisine yol açabilir (PodDisruptionBudget'ları olmayan uygulamalar için özellikle).
3. **`quay.io/openshift-release-dev/*` scope'larını asla kısıtlamayın** (yanlışlıkla dahi) — cluster'ın kendi imajlarını çekememesi cluster'ı bozabilir. Sadece kendi uygulama imajlarınızın scope'unu hedefleyin.
4. Değişikliği geri almak isterseniz `oc delete clusterimagepolicy <ad>` — bu da **yeni bir reboot rollout'u** tetikler (eski config'e dönüş), yani "dene, olmadıysa hemen sil" döngüsü her seferinde node'ları resetler; ilk denemeden önce doğru yapılandırdığınızdan emin olun.
