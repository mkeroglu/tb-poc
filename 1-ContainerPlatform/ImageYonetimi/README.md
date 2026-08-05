# Image Yönetimi

Bu bölümde OpenShift üzerinde container image'larının yönetimi ele alınacaktır:

- [x] Internal registry kullanımı
- [x] External registry entegrasyonu
- [x] Vulnerability scanning

---

## Internal Registry Kullanımı

### Internal Registry nedir?

OpenShift, her cluster'a entegre gelen bir container image registry ile birlikte kurulur (`openshift-image-registry` namespace'inde, `image-registry` cluster operator'ü tarafından yönetilir). Öne çıkan özellikleri:

- Cluster içinden `image-registry.openshift-image-registry.svc:5000` DNS adı üzerinden erişilir; kimlik doğrulama için pod'un service account token'ı otomatik kullanılır (ayrı bir `imagePullSecret` tanımlamaya genelde gerek yoktur).
- Her namespace kendi **ImageStream**'lerine sahiptir; bir image push edildiğinde ilgili ImageStream **otomatik** oluşturulur/güncellenir.
- `defaultRoute: true` ise cluster dışından da (`podman`/`docker` ile) push/pull yapılabilecek bir Route açılır.

### Mevcut durumu kontrol etme

```bash
oc get co image-registry
oc get configs.imageregistry.operator.openshift.io cluster -o yaml
```

Çıktıda kontrol edilmesi gereken alanlar:

| Alan | Değer | Anlamı |
|---|---|---|
| `managementState` | `Managed` ise aktif | Operator registry'i yönetiyor (kapalıysa `Removed` görürsünüz, bkz. aşağıdaki aktifleştirme adımları) |
| `defaultRoute` | `true` ise harici erişim açık | Route hostname'i öğrenmek için: `oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}'` |
| `storage` | `emptyDir` / `pvc` / `s3` vb. | **Dikkat:** `emptyDir` ise **kalıcı değildir** — registry pod'u yeniden zamanlanırsa (node değişimi, restart) push edilen tüm imajlar kaybolur. POC/demo amaçlı kabul edilebilir; production'da mutlaka kalıcı storage (PVC, S3-uyumlu object storage vb.) kullanılmalıdır. |

### Internal Registry nasıl aktif edilir? (kapalıysa)

Bazı kurulumlarda (özellikle bare-metal, storage otomatik yapılandırılmadığı için) registry operator kendini `Removed` bırakır. Aktif etmek için:

```bash
# 1) Kalıcı storage tanımlayın (production önerisi — PVC tabanlı)
oc patch configs.imageregistry.operator.openshift.io cluster --type merge -p \
  '{"spec":{"storage":{"pvc":{"claim":""}}}}'
# "claim" boş bırakılırsa operator, varsayılan StorageClass'tan otomatik bir PVC oluşturur

# 2) Registry'i aktif edin
oc patch configs.imageregistry.operator.openshift.io cluster --type merge -p \
  '{"spec":{"managementState":"Managed"}}'

# 3) (opsiyonel) Harici erişim için route'u açın
oc patch configs.imageregistry.operator.openshift.io cluster --type merge -p \
  '{"spec":{"defaultRoute":true}}'

# Doğrulama
oc get co image-registry
oc get pods -n openshift-image-registry
```

Aynı ayarları tek seferde bir manifest ile de uygulayabilirsiniz — referans için `imageregistry-config-example.yaml` dosyasına bakın.

> **Önemli:** Bu komutlar **cluster-admin** yetkisi gerektirir ve cluster genelindeki **tek** registry yapılandırmasını değiştirir (namespace-scoped değildir). Registry zaten `Managed` durumdaysa bu `managementState`/`storage` değişikliklerini paylaşılan bir cluster'da dikkatli uygulayın — diğer namespace'lerin image push/pull işlemlerini kesintiye uğratma riski taşır. Aşağıdaki push/pull/ImageStream adımları namespace-scoped ve güvenlidir.

### Push/Pull ile kullanım (canlı test edildi)

**1) Registry'ye login olun** — kendi OpenShift OAuth token'ınızla, ayrı bir registry kullanıcı/parolasına gerek yoktur:

```bash
REG=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
podman login --tls-verify=false -u "$(oc whoami)" -p "$(oc whoami -t)" "$REG"
```

> `--tls-verify=false`: bu route'un sertifikası bilinen bir CA tarafından imzalı değil (cluster-internal/self-signed CA). Production'da cluster CA'sını istemcinin trust store'una ekleyip bu flag'i kaldırmanız önerilir.

**2) Bir imajı namespace'inizin altına push edin:**

```bash
podman pull docker.io/library/alpine:3.20
podman tag docker.io/library/alpine:3.20 "$REG/tb-ocp-poc/demo-alpine:latest"
podman push --tls-verify=false "$REG/tb-ocp-poc/demo-alpine:latest"
```

> Push edebilmek için o namespace'te en az `edit` rolüne sahip olmanız yeterlidir.

**3) ImageStream'in otomatik oluştuğunu doğrulayın:**

```bash
oc get imagestream -n tb-ocp-poc
oc describe imagestream demo-alpine -n tb-ocp-poc
```

Push işlemi namespace'te otomatik olarak bir **ImageStream** (`demo-alpine`) oluşturur/günceller — ayrıca `oc create imagestream` çalıştırmanıza gerek yoktur.

**4) Cluster içinden, harici route'a hiç gerek olmadan bu imajı kullanın:**

```bash
oc run demo-alpine-test --image=image-registry.openshift-image-registry.svc:5000/tb-ocp-poc/demo-alpine:latest --restart=Never -- sleep 3600
oc get pod demo-alpine-test
```

Cluster içi pod'lar internal registry'ye **service DNS** üzerinden erişir; kimlik doğrulaması pod'un service account token'ı ile otomatik yapılır — aynı namespace içindeyseniz ayrı bir `imagePullSecret` gerekmez.

**5) Kısa imaj adı kullanımı (image lookup policy):**

Varsayılan olarak bir Pod/Deployment'ta `image: demo-alpine:latest` gibi kısa bir isim yazamazsınız — tam internal registry pull spec'i gerekir. Bunu kolaylaştırmak için ImageStream'in **local lookup** politikasını açabilirsiniz:

```bash
oc set image-lookup demo-alpine
oc run demo-alpine-short --image=demo-alpine:latest --restart=Never -- sleep 3600
oc get pod demo-alpine-short -o jsonpath='{.spec.containers[0].image}'
# çıktı: image-registry.openshift-image-registry.svc:5000/tb-ocp-poc/demo-alpine@sha256:...
```

OpenShift, bir admission webhook üzerinden kısa ismi otomatik olarak tam internal registry pull spec'ine (digest ile birlikte) çözümler.

**6) Harici olarak (cluster dışından) pull test:**

```bash
podman pull --tls-verify=false "$REG/tb-ocp-poc/demo-alpine:latest"
```

### Temizlik

```bash
oc delete imagestream demo-alpine -n tb-ocp-poc
podman rmi -f docker.io/library/alpine:3.20 "$REG/tb-ocp-poc/demo-alpine:latest"
podman logout "$REG"
```

## External Registry Entegrasyonu

Henüz kullanılacak spesifik bir external registry (Quay.io, Docker Hub, Harbor, Artifactory, GHCR vb.) belirlenmedi. Bu bölüm, **hangi registry seçilirse seçilsin geçerli olan genel mekanizmayı** (public pull, private pull secret, ImageStream import) canlı olarak test edip belgeliyor; gerçek registry netleştiğinde sadece host adı/kimlik bilgileri güncellenecektir.

### Kavram

- **Public imajlar** için ekstra kimlik doğrulama gerekmez — herhangi bir external registry'den doğrudan pull edilebilir.
- **Private imajlar** için `kubernetes.io/dockerconfigjson` tipinde bir **Secret** oluşturup, ya pod'un `imagePullSecrets` alanına ya da namespace'in `default` service account'una bağlamanız gerekir.
- OpenShift ayrıca bir **ImageStream** ile harici registry'deki bir tag'i "import" ederek takip edebilir; `--scheduled=true` ile periyodik otomatik güncelleme (ve buna bağlı image-change trigger'ları) mümkündür.

### 1) Public external registry'den pull (canlı test edildi)

Quay.io üzerinden, kimlik doğrulama gerektirmeyen public bir imaj:

```bash
oc run quay-demo --image=quay.io/prometheus/busybox:latest --restart=Never -- sleep 3600
oc get pod quay-demo
```

Sonuç: `1/1 Running` — herhangi bir secret tanımlamadan doğrudan çalıştı.

### 2) Private registry için pull secret mekanizması (canlı test edildi)

Henüz gerçek bir private registry hesabımız olmadığı için mekanizmayı **placeholder (geçersiz) kimlik bilgileriyle** test ettik. Amaç: OpenShift'in secret'ı doğru şekilde okuyup registry'ye kimlik bilgisiyle bağlanmaya **çalıştığını** kanıtlamak — gerçek registry bilgileri elinize geçtiğinde tek yapmanız gereken bu secret'ın değerlerini güncellemektir.

**a) Secret olmadan bir private-tarzı imaj denemesi:**

```bash
oc run priv-nosecret --image=docker.io/tbocppoc/private-demo:latest --restart=Never -- sleep 10
```

Gerçek sonuç (`oc describe pod`):

```
Failed to pull image "docker.io/tbocppoc/private-demo:latest": ... requested access to the resource is denied
```

**b) `external-registry-pull-secret.yaml` ile secret oluşturup deneyin:**

```bash
oc apply -f external-registry-pull-secret.yaml
# veya imperative eşdeğeri:
oc create secret docker-registry external-registry-cred \
  --docker-server=docker.io \
  --docker-username=<gercek-kullanici-adi> \
  --docker-password=<gercek-sifre-veya-token> \
  --docker-email=<eposta>
```

Placeholder kimlik bilgileriyle tekrar denediğimizde **farklı ve daha spesifik** bir hata aldık — bu, secret'ın gerçekten okunup kullanıldığının kanıtıdır:

```
Failed to pull image "docker.io/tbocppoc/private-demo:latest": ...
unable to retrieve auth token: invalid username/password: unauthorized: incorrect username or password
```

(`resource is denied` → kimlik bilgisi hiç gönderilmemiş; `incorrect username or password` → kimlik bilgisi gönderilmiş ama **yanlış**. Gerçek/geçerli bilgilerle bu adım başarıyla pull yapacaktır.)

**c) İki bağlama yöntemi:**

- **Pod/Deployment seviyesinde** (yalnızca o workload için) — bkz. `external-image-demo.yaml`:
  ```yaml
  spec:
    imagePullSecrets:
      - name: external-registry-cred
  ```
- **Service account seviyesinde** (namespace'teki `default` SA'yı kullanan tüm pod'lar için otomatik, pod spec'inde ayrıca belirtmeye gerek kalmadan) — bu şekilde de test edildi ve aynı sonucu verdi:
  ```bash
  oc secrets link default external-registry-cred --for=pull
  ```

**d) Tam Deployment örneği:**

```bash
oc apply -f external-image-demo.yaml
oc get pods -l app=external-image-demo
# beklenen: ImagePullBackOff (placeholder kimlik bilgileri gerçek olmadığı için) —
# gerçek registry bilgileri girildiğinde Running olacaktır.
```

### 3) ImageStream ile harici imaj import/takip etme (canlı test edildi)

```bash
oc import-image external-busybox --from=quay.io/prometheus/busybox --confirm --scheduled=true
oc describe imagestream external-busybox
```

Gerçek çıktıda şu satır görülür:

```
latest
  updates automatically from registry quay.io/prometheus/busybox
```

`--scheduled=true` ile OpenShift, harici registry'yi periyodik olarak (varsayılan ~15 dakikada bir) kontrol eder; kaynak tag güncellenirse ImageStream otomatik güncellenir — bu da varsa bağlı bir `ImageChangeTrigger`'ı (örn. bir Build veya DeploymentConfig) tetikleyebilir.

### Temizlik

```bash
oc delete deployment external-image-demo
oc delete secret external-registry-cred
oc secrets unlink default external-registry-cred
oc delete imagestream external-busybox
oc delete pod quay-demo priv-nosecret priv-withsecret priv-sa-linked --ignore-not-found
```

## Vulnerability Scanning

Araç: **Red Hat Advanced Cluster Security (RHACS / StackRox)**. ACS iki ana parçadan oluşur:

- **Central** — yönetim arayüzü, API, imaj/CVE veritabanı (`stackrox` namespace'inde çalışır).
- **Scanner** — imaj katmanlarını indeksleyip (Indexer) bilinen CVE veritabanıyla eşleştiren (Matcher) bileşen.

Ayrıca opsiyonel olarak her cluster'a bir **SecuredCluster** (Sensor + Collector + Admission Controller) kurularak runtime izleme ve deploy-time politika uygulaması (örn. "kritik CVE'si olan imaj deploy edilemesin") sağlanabilir — bu, salt imaj tarama için zorunlu değildir.

### Mevcut durumu kontrol etme

```bash
oc get ns | grep -iE "stackrox|rhacs"
oc get central -n stackrox
oc get securedcluster -n stackrox
oc get route central -n stackrox
```

| Bileşen | Beklenen durum |
|---|---|
| **Central** | `AVAILABLE: True` — UI + API erişilebilir |
| **Scanner** | İlgili pod'lar `Running`, CVE veritabanı güncel |
| **SecuredCluster** (varsa) | `AVAILABLE: True` — değilse `oc get securedcluster <ad> -o yaml` ile `status.conditions` altındaki hata mesajına bakın |

Central'a henüz kurulu değilse, kurulum **RHACS Operator** (OperatorHub üzerinden) ile yapılır: önce bir `Central` CR (Central servisleri) oluşturulur, ardından her secure edilecek cluster için bir `SecuredCluster` CR uygulanır. Bu POC'de kurulum adımı kapsam dışıdır — mevcut/kurulacak bir Central kullanılacaktır.

### Görüntü taraması için ön koşul: Image Integration

Central, bir registry'deki imajları tarayabilmesi için o registry'nin **Image Integration** olarak tanımlı olmasını gerektirir — aksi halde tarama isteği `no matching image registries found` hatasıyla reddedilir. Mevcut entegrasyonları listeleme:

```bash
CENTRAL=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')
PASS="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)"
curl -sk -u "admin:$PASS" "https://$CENTRAL/v1/imageintegrations" | python3 -m json.tool
```

Internal registry (veya kullanılacak external registry) listede yoksa `acs-image-integration.json` dosyasını kendi kullanıcı adı/token bilgilerinizle doldurup ekleyin:

```bash
curl -sk -u "admin:$PASS" -X POST "https://$CENTRAL/v1/imageintegrations" \
  -H "Content-Type: application/json" \
  -d @acs-image-integration.json
```

> Demo/kurulum sırasında kişisel bir `oc whoami -t` token'ı kullanılabilir, ancak **production'da** bunun yerine sadece `system:image-puller` yetkisine sahip **dedicated bir service account token**'ı kullanılması önerilir (kişisel token'lar süreli/iptal edilebilir olduğu için entegrasyonu kırılgan yapar).

### `roxctl` ile imaj tarama

```bash
roxctl image scan \
  -e "${CENTRAL}:443" --insecure-skip-tls-verify \
  -p "$PASS" \
  --image image-registry.openshift-image-registry.svc:5000/<namespace>/<imaj>:<tag> \
  --output table
```

> `--insecure-skip-tls-verify`: route sertifikası self-signed/cluster-internal bir CA'ya aitse gereklidir. Route üzerinden büyük/yavaş taramalarda HAProxy'nin varsayılan idle timeout'u bağlantıyı kesebilir (`transport: EOF` hatası); bu durumda `oc port-forward svc/central 18443:443 -n stackrox` ile Central'a doğrudan bağlanıp `-e localhost:18443` kullanmak timeout'u aşar.

### Sonuç boş dönerse: kontrol sırası

Bir tarama `TOTAL-COMPONENTS: 0` gibi boş sonuç döndürürse, sırayla şunlar kontrol edilmeli:

1. **Image Integration doğru mu?** — `curl .../v1/imageintegrations` çıktısında ilgili registry'nin `endpoint` alanı, taranan imajın registry host'uyla birebir eşleşmeli (örn. `docker.io` ile `registry-1.docker.io` farklı değerlerdir, eşleşmezse entegrasyon devreye girmez).
2. **Indexer imajı işledi mi?** — `oc logs -n stackrox deploy/scanner-v4-indexer --since=5m | grep "manifest successfully scanned"` ile katmanların okunduğunu doğrulayın.
3. **Matcher çağrıldı mı?** — `oc logs -n stackrox deploy/scanner-v4-matcher --since=5m | grep GetVulnerabilities` ile CVE eşleştirme adımının tetiklendiğini doğrulayın. Indexer başarılı olduğu halde Matcher hiç çağrılmıyorsa, bu Central'ın kendi enrichment pipeline'ında bir sorun olduğuna işaret eder (örn. birden fazla scanner entegrasyonunun çakışması) — bu durumda ACS'i işleten platform/operatör ekibiyle iletişime geçilmesi gerekir.
4. **İmaj Central'da kayıtlı mı?** — `curl .../v1/images?query=Image:<imaj-adi>` ile imajın Central'ın kendi veritabanına işlenip işlenmediğini kontrol edin.

### Temizlik

```bash
oc delete imagestream <test-imaji> -n <namespace> --ignore-not-found
podman rmi -f <yerel-imaj-referanslari>
podman logout "$REG"
```
