# OpenShift Virtualization POC Rehberi

Bu doküman OpenShift Virtualization (KubeVirt) ile sanal makine yaşam döngüsünü uçtan uca anlatır: template'ten VM, ISO'dan kurulum, golden image, ODF depolama, live migration, snapshot/restore, Multus ile VLAN ağı ve affinity / anti-affinity / nodeSelector ile yerleşim.

Her adım hem **CLI** (`oc` / `virtctl`) hem **Web Console** için verilmiştir. CLI adımlarının tamamı Bedrock cluster'ında (OpenShift 4.22.6, OpenShift Virtualization 4.22.9, ODF 4.22.4, bare-metal HPE + QCT worker'lar) **`trt-ocp-poc-virt` namespace'inde uçtan uca canlı test edilmiştir**; bölümlerdeki "✅ Gerçek çıktı" satırları bu testlerden alınmıştır. Console adımları 4.22 arayüzüne göre yazılmıştır.

Senaryo sırası:

1. Ön koşul kontrolü
2. Operatör kurulumu
3. Template'ler — listeleme, dışa alma (export), template'ten VM, özel template, var olan VM'den template alma
4. ISO ile VM kurulumu (ISO yükleme + kurulum + CD-ROM çıkarma)
5. Golden image (kurulu diskten boot source üretme)
6. ODF depolama — hotplug disk ve online disk büyütme
7. Live migration
8. Snapshot / restore
9. Multus — VM'e VLAN (LAN) arayüzü ekleme
10. Yerleşim — nodeSelector, node affinity, VM affinity / anti-affinity
11. OADP ile VM yedekleme (hazırlık)
12. Bilinen sınırlamalar / canlı testte görülenler
13. Temizlik

Dosyalar:

| Dosya | İçerik |
|---|---|
| `namespace.yaml` | `trt-ocp-poc-virt` namespace'i |
| `operator-install.yaml`, `hyperconverged.yaml` | Operatör kurulumu (referans) |
| `custom-template.yaml` | `fedora-server-small`'dan türetilmiş TRT'ye özel template |
| `vm-to-template/vm-to-template.sh` | Var olan VM'den golden image + Template üreten script |
| `vm-to-template/trt-web-golden.yaml` | Script'in canlı testte ürettiği template |
| `vm-from-iso.yaml` | ISO (CD-ROM) + boş diskli VM |
| `golden-image.yaml` | Kurulu diskten DataVolume + DataSource + yeni VM |
| `data-disk-dv.yaml` | Hotplug edilecek veri diski |
| `live-migration.yaml` | `VirtualMachineInstanceMigration` |
| `vm-snapshot.yaml`, `vm-restore.yaml` | Snapshot ve restore |
| `nad-vlan112.yaml` | VLAN 112 `NetworkAttachmentDefinition` |
| `scheduling/*.yaml` | nodeSelector, node affinity, anti-affinity, affinity VM'leri |

---

## 1. Ön Koşul Kontrolü

OpenShift Virtualization, VM'leri worker node'lardaki donanım sanallaştırması (KVM) ile çalıştırır.

```bash
# Hangi node'lar VM çalıştırabilir, KVM cihazı var mı?
oc get nodes -l kubevirt.io/schedulable=true \
  -o custom-columns=NODE:.metadata.name,KVM:'.status.allocatable.devices\.kubevirt\.io/kvm'
```

✅ **Gerçek çıktı:** 6 worker'ın tamamında (`hpeworker01-03`, `worker01-03`) `KVM: 1k`.

> **Önemli:** Worker'lar bir hypervisor üzerinde VM olarak çalışıyorsa (örn. VMware), ESXi'de ilgili VM'ler için **"Expose hardware assisted virtualization to the guest OS"** açılmalıdır. Açılmazsa `/dev/kvm` olmaz ve VM'ler ya hiç başlamaz ya da sadece çok yavaş yazılımsal emülasyonla (`spec.configuration.developerConfiguration.useEmulation`) çalışır. Bu ayar sadece demo içindir, performans testi yapılmamalıdır.

Depolama tarafında ODF, VM'ler için ayrı bir storage class sunar:

```bash
oc get sc ocs-storagecluster-ceph-rbd-virtualization
oc get storageprofile ocs-storagecluster-ceph-rbd-virtualization -o jsonpath='{.status.claimPropertySets}'
```

✅ **Gerçek çıktı:** İlk tercih `ReadWriteMany + Block`. Live migration için RWX gerektiğinden bu storage class kullanılmalıdır.

---

## 2. Operatör Kurulumu

> Bedrock cluster'ında operatör zaten kurulu olduğu için bu adım yeniden uygulanmadı; sadece durum doğrulandı. Aşağıdaki YAML'lar cluster'daki gerçek subscription ile aynıdır (`kubevirt-hyperconverged` / `stable` / `redhat-operators`).

**CLI:**

```bash
oc apply -f operator-install.yaml
oc get csv -n openshift-cnv -w          # kubevirt-hyperconverged-operator ... Succeeded olana kadar bekleyin
oc apply -f hyperconverged.yaml
oc wait hco kubevirt-hyperconverged -n openshift-cnv --for=condition=Available --timeout=15m
```

`virtctl` CLI'ı cluster'ın kendisinden indirilebilir: Console'da **?** → **Command Line Tools** → **virtctl**, ya da `hyperconverged-cluster-cli-download-openshift-cnv.apps.<cluster-domain>` route'u.

**Console:**

1. **Operators → OperatorHub** → "OpenShift Virtualization" → **Install** (varsayılan: `openshift-cnv` namespace, `stable` kanal).
2. Kurulum bitince **Create HyperConverged** → varsayılanlarla **Create**.
3. Sol menüde **Virtualization** bölümü açılır.

**Doğrulama:**

```bash
oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

✅ **Gerçek çıktı:** `ReconcileComplete=True`, `Available=True`, `Progressing=False`, `Degraded=False`, `Upgradeable=True`.

Namespace'i ve VM'lere enjekte edilecek SSH anahtarını hazırlayın:

```bash
oc apply -f namespace.yaml
ssh-keygen -t ed25519 -N '' -f ./vmkey
oc create secret generic vm-ssh-key -n trt-ocp-poc-virt --from-file=key=./vmkey.pub
```

---

## 3. Template'ler

OpenShift Virtualization, `openshift` namespace'inde hazır VM template'leri ile gelir (RHEL, CentOS Stream, Fedora, Windows ...). Bu template'ler işletim sistemi imajını **boot source** (`DataSource`) üzerinden alır. Boot source'lar `openshift-virtualization-os-images` namespace'inde otomatik olarak güncel tutulur.

### 3.1 Template'leri ve boot source'ları listeleme

```bash
# Hazır (base) template'ler
oc get template -n openshift -l template.kubevirt.io/type=base

# Boot source'lar (template'lerin klonladığı OS imajları)
oc get datasource -n openshift-virtualization-os-images
```

✅ **Gerçek çıktı:** 77 base template; `fedora`, `centos-stream9`, `rhel9`, `rhel10`, `win2k22` vb. 14 DataSource. `fedora`, `rhel9` ve `centos-stream9` `Ready=True`.

### 3.2 Template'i dışa alma (export) ve parametrelerini görme

```bash
# Template'in tamamını YAML olarak alma
oc get template fedora-server-small -n openshift -o yaml > fedora-server-small-template.yaml

# Template'in hangi parametreleri aldığını görme
oc process --parameters -n openshift fedora-server-small
```

✅ **Gerçek çıktı:**

```
NAME                    DESCRIPTION                                          GENERATOR    VALUE
NAME                    VM name                                              expression   fedora-[a-z0-9]{16}
DATA_SOURCE_NAME        Name of the DataSource to clone                                   fedora
DATA_SOURCE_NAMESPACE   Namespace of the DataSource                                       openshift-virtualization-os-images
CLOUD_USER_PASSWORD     Randomized password for the cloud-init user fedora   expression   [a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}
```

**Console:** **Virtualization → Templates** → proje olarak `openshift` seçin → template'e tıklayın → **YAML** sekmesi. Sağ üstteki **Download** ile dosya olarak indirebilirsiniz.

### 3.3 Template'ten VM oluşturma

**CLI:**

```bash
oc process -n openshift fedora-server-small \
  -p NAME=fedora-from-template -p CLOUD_USER_PASSWORD=Trt-Poc-2026 \
  | oc apply -n trt-ocp-poc-virt -f -

# SSH anahtarını VM'e ekle (cloud-init ile enjekte edilir)
oc patch vm fedora-from-template -n trt-ocp-poc-virt --type=merge -p \
  '{"spec":{"template":{"spec":{"accessCredentials":[{"sshPublicKey":{"source":{"secret":{"secretName":"vm-ssh-key"}},"propagationMethod":{"noCloud":{}}}}]}}}}'

virtctl start fedora-from-template -n trt-ocp-poc-virt     # template'ler VM'i "Halted" oluşturur
oc get dv,vm,vmi -n trt-ocp-poc-virt
```

✅ **Gerçek çıktı:** DataVolume **19 saniyede** `Succeeded`, VM **20 saniyede** `Running`. Disk sıfırdan indirilmedi, ODF üzerinde boot source snapshot'ından klonlandı. Disk storage profile sayesinde otomatik olarak `ocs-storagecluster-ceph-rbd-virtualization`'da `RWX Block` açıldı.

**Erişim:**

```bash
virtctl ssh fedora@vmi/fedora-from-template -n trt-ocp-poc-virt -i ./vmkey   # SSH (API üzerinden tünel)
virtctl console fedora-from-template -n trt-ocp-poc-virt                      # serial console (çıkış: Ctrl+])
virtctl vnc fedora-from-template -n trt-ocp-poc-virt                          # grafik konsol (yerel VNC istemcisi gerekir)
```

✅ **Gerçek çıktı:** `Fedora release 44`, 1 vCPU, 1.8Gi RAM, 30G `vda`, `qemu-guest-agent: active`.

**Console:**

1. **Virtualization → Catalog** → **Template catalog** sekmesi.
2. Proje: `trt-ocp-poc-virt`; "Fedora VM" (`fedora-server-small`) kartını seçin.
3. Boot source hazır olduğunda kartta "Source available" görünür. **Customize VirtualMachine** ile ad, disk, cloud-init kullanıcı/şifre ve **SSH key** (mevcut secret'ı seçin) ayarlanır.
4. **Create VirtualMachine** ile oluşturun. VM sayfasında **Console** sekmesinden VNC/Serial konsola, **Overview**'dan IP ve node bilgisine ulaşılır.

> **Template yerine InstanceType:** 4.x sürümlerinde önerilen yeni yol **InstanceTypes** sekmesidir. Burada boot volume seçilir, sonra boyut (`u1.small` = 1 vCPU/2Gi, `u1.medium` ...) seçilir. Bölüm 10'daki VM'ler bu yöntemle (`spec.instancetype` + `spec.preference`) oluşturulmuştur.

### 3.4 Özel (kurumsal) template oluşturma

Hazır template dışa alınıp değiştirilerek kuruma özel bir template yapılabilir. Proje namespace'ine konan template'ler Console kataloğunda o projede **"User templates"** olarak görünür.

`custom-template.yaml`, `fedora-server-small`'dan türetilmiştir. Farkları:

- Ad `trt-fedora-small`, namespace `trt-ocp-poc-virt`, görünen ad "TRT Fedora Small (SSH key + ODF virt)".
- Label `template.kubevirt.io/type: vm` (kullanıcı template'i). SSP operatörünün yönettiğini belirten `app.kubernetes.io/*` label'ları kaldırıldı.
- Disk her zaman `ocs-storagecluster-ceph-rbd-virtualization` üzerinde açılır.
- Yeni **`SSH_KEY_SECRET`** parametresi eklendi: anahtar VM'e otomatik enjekte edilir.
- `hpe` rollü node'lar tercih edilir (preferred node affinity).

```bash
oc apply -f custom-template.yaml
oc process --parameters trt-fedora-small -n trt-ocp-poc-virt
oc process trt-fedora-small -n trt-ocp-poc-virt -p NAME=trt-vm-from-custom-template \
  | oc apply -n trt-ocp-poc-virt -f -
virtctl start trt-vm-from-custom-template -n trt-ocp-poc-virt
virtctl ssh fedora@vmi/trt-vm-from-custom-template -n trt-ocp-poc-virt -i ./vmkey
```

✅ **Gerçek çıktı:** Parametre listesinde `SSH_KEY_SECRET ... vm-ssh-key` görüldü. VM `hpeworker01`'e (hpe tercihine uygun) yerleşti, disk `ocs-storagecluster-ceph-rbd-virtualization`'da açıldı ve ek bir patch gerekmeden `virtctl ssh` ile anahtarla girildi.

**Console:**

- **Virtualization → Templates** → `openshift` projesindeki template'in **⋮** menüsü → **Clone**: yeni ad ve hedef proje (`trt-ocp-poc-virt`) verin. Ardından klonun **YAML** / **Disks** / **Scheduling** sekmelerinden özelleştirin.
- Sıfırdan oluşturmak için **Templates → Create Template** (YAML editörü açılır).

### 3.5 Var olan (kurulmuş) bir VM'den template alma

OpenShift Virtualization'da "VM'den template üret" diye tek adımlık bir API yoktur (cluster'da `VirtualMachineTemplate` benzeri bir CRD bulunmuyor). Bu iş şu akışla yapılır:

1. Kaynak VM'i özelleştir (paket, ayar, hardening).
2. **Genelleştir**: makineye özgü kimlikleri temizle ve VM'i durdur.
3. VM'in root diskini klonlayıp **golden image** (`DataSource`) olarak yayınla.
4. VM tanımından MAC/UUID gibi alanları temizleyip **parametreli bir `Template`** üret. Disk, golden image'dan `sourceRef` ile klonlanır.

Adım 3 ve 4 için `vm-to-template/vm-to-template.sh` script'i hazırlanmıştır.

**1) Özelleştirme** (testte `trt-vm-from-custom-template` VM'i kullanıldı):

```bash
# VM içinde
sudo dnf install -y httpd
echo "<h1>TRT golden web sunucusu</h1>" | sudo tee /var/www/html/index.html
sudo systemctl enable --now httpd
echo "TRT kurumsal ayar v1" | sudo tee /etc/trt-golden
```

✅ **Gerçek çıktı:** `dnf_rc=0`, `curl localhost` → `<h1>TRT golden web sunucusu</h1>`, `httpd enabled`.

**2) Genelleştirme ve durdurma:**

```bash
# VM içinde
sudo cloud-init clean --logs --seed      # yeni VM'lerde cloud-init tekrar çalışsın (hostname, kullanıcı, SSH key)
sudo truncate -s0 /etc/machine-id        # her klon kendi machine-id'sini üretsin
sudo rm -f /etc/ssh/ssh_host_*           # her klon kendi SSH host key'ini üretsin
sudo rm -f /home/fedora/.ssh/authorized_keys
sudo hostnamectl set-hostname localhost
sudo systemctl poweroff
```

```bash
virtctl stop trt-vm-from-custom-template -n trt-ocp-poc-virt
```

> Windows VM'lerde bu adımın karşılığı `sysprep /generalize /oobe /shutdown` komutudur.

**3+4) Golden image + Template üretme:**

```bash
cd vm-to-template
./vm-to-template.sh trt-vm-from-custom-template trt-ocp-poc-virt trt-web-golden "TRT Web Sunucusu (httpd, golden)"
```

Script şunları yapar:

- VM durdurulmamışsa hata verip çıkar (tutarsız imaj alınmasın diye).
- Root diski (en küçük `bootOrder`) `trt-web-golden-image` DataVolume'una klonlar ve `DataSource trt-web-golden` olarak yayınlar.
- VM tanımından `firmware.uuid`, `firmware.serial` ve `macAddress` alanlarını, `vm.kubevirt.io/template*` label'larını ve hotplug/veri disklerini çıkarır.
- `NAME`, `CLOUD_USER_PASSWORD` ve `SSH_KEY_SECRET` parametreli `Template` üretir, `trt-web-golden.yaml` olarak kaydeder ve cluster'a uygular.

✅ **Gerçek çıktı:**

```
Root disk: volume=rootdisk pvc=trt-vm-from-custom-template size=30Gi sc=ocs-storagecluster-ceph-rbd-virtualization
datavolume.cdi.kubevirt.io/trt-web-golden-image created
datasource.cdi.kubevirt.io/trt-web-golden created
datavolume.cdi.kubevirt.io/trt-web-golden-image condition met
template.template.openshift.io/trt-web-golden created
```

Üretilen template (`vm-to-template/trt-web-golden.yaml`) incelendi: MAC/UUID yok, disk `sourceRef: DataSource trt-ocp-poc-virt/trt-web-golden` ile klonlanıyor, CPU/bellek/firmware/affinity kaynak VM'den aynen alınmış.

**5) Template'ten yeni VM'ler:**

```bash
oc process trt-web-golden -n trt-ocp-poc-virt -p NAME=trt-web-01 | oc apply -n trt-ocp-poc-virt -f -
oc process trt-web-golden -n trt-ocp-poc-virt -p NAME=trt-web-02 | oc apply -n trt-ocp-poc-virt -f -

# Doğrulama: her VM'de farklı hostname/machine-id olmalı, httpd ve /etc/trt-golden gelmiş olmalı
virtctl ssh fedora@vmi/trt-web-01 -n trt-ocp-poc-virt -i ./vmkey \
  --command 'hostname; cat /etc/machine-id /etc/trt-golden; systemctl is-active httpd; curl -s localhost'
```

> ⏳ **Bu son adım (template'ten VM açıp doğrulama) henüz canlı test edilmedi.** Adım 1–4 test edildi.

**Console karşılığı:**

1. VM'i genelleştirip durdurun (yukarıdaki komutlar, VM **Console** sekmesinden).
2. **Virtualization → Bootable volumes → Add volume** → **Source type: Use existing volume** → PVC `trt-vm-from-custom-template` → ad `trt-web-golden`. Ya da VM → **Snapshots → Take snapshot**, ardından **Add volume → Volume snapshot**.
3. **Virtualization → Templates** → uygun bir base template (örn. `fedora-server-small`) **⋮ → Clone** → proje `trt-ocp-poc-virt`. Klonun **Disks** sekmesinde boot source olarak `trt-web-golden` volume'unu seçin.
4. **Catalog → Template catalog → User templates** üzerinden yeni VM oluşturun.

> **Sadece birebir kopya lazımsa:** `VirtualMachineClone` API'si (`clone.kubevirt.io`) bir VM'i disk ve tanımıyla birlikte doğrudan kopyalar, MAC/SMBIOS değerlerini yeniler. Console: VM → **Actions → Clone**. Bu yöntem template üretmez, tek seferlik kopya içindir.

---

## 4. ISO ile VM Kurulumu

Akış: ISO'yu bir PVC'ye (DataVolume) yükle → VM'i ISO **CD-ROM** + **boş disk** ile oluştur → ISO'dan boot edip diske kur → VM'i durdurup CD-ROM'u çıkar → diskten boot et.

Test için küçük boyutlu ve serial console'dan kurulabildiği için **Alpine Linux 3.24.2 "virt" ISO'su** (66 MB) kullanıldı. RHEL / Windows ISO'larında akış birebir aynıdır, sadece kurulum ekranı farklıdır (Windows için bkz. bölüm 12).

### 4.1 ISO'yu yükleme

**CLI** (`virtctl image-upload`, CDI upload proxy route'u üzerinden):

```bash
curl -LO https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-virt-3.24.2-x86_64.iso

virtctl image-upload dv alpine-iso -n trt-ocp-poc-virt \
  --size=1Gi \
  --image-path=./alpine-virt-3.24.2-x86_64.iso \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
  --insecure --force-bind
```

✅ **Gerçek çıktı:** `66.00 MiB ... 100.00%` (~35 MiB/s), `Processing completed successfully`. Toplam süre **37 saniye**.

> `--insecure`, CDI upload proxy route'unun sertifikası yerel makinede güvenilir değilse gerekir. `--force-bind`, `WaitForFirstConsumer` storage class'larında PVC'nin hemen bağlanmasını sağlar.

ISO bir web sunucusunda duruyorsa yüklemek yerine doğrudan URL'den de çekilebilir:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: alpine-iso
  namespace: trt-ocp-poc-virt
spec:
  source:
    http:
      url: https://<web-sunucusu>/alpine-virt-3.24.2-x86_64.iso
  storage:
    resources:
      requests:
        storage: 1Gi
```

**Console:**

1. **Virtualization → Bootable volumes** → **Add volume**.
2. **Source type: Upload volume** → ISO dosyasını seçin (ya da **Use URL** ile URL verin).
3. **Volume name** `alpine-iso`, **StorageClass** `ocs-storagecluster-ceph-rbd-virtualization`, **Disk size** `1Gi`.
4. İsteğe bağlı olarak **Preference** (örn. `alpine`) seçin, **Save**. Yükleme ilerlemesi ekranda görünür.

### 4.2 ISO'dan boot eden VM'i oluşturma

`vm-from-iso.yaml` iki disk tanımlar:

- `installation-cdrom`: ISO PVC'si, `cdrom` / `sata`, **`bootOrder: 1`**
- `rootdisk`: 5Gi **boş** (`source.blank`) DataVolume, RWX Block, **`bootOrder: 2`**

```bash
oc apply -f vm-from-iso.yaml
virtctl console alpine-from-iso -n trt-ocp-poc-virt     # kurulum ekranı
```

**Console:**

1. **Virtualization → Catalog** → **Template catalog** → işletim sistemine uygun template'i seçin (örn. "Fedora VM" ya da "RHEL 9 VM").
2. **Customize VirtualMachine** → **Disk source**: **"Boot from CD"** işaretleyin → **CD source**: yüklediğiniz `alpine-iso` PVC'si. **Disk source**: **Blank** (örn. 5Gi).
3. **Create VirtualMachine** → **Console** sekmesinden kurulum ekranına bağlanın.

### 4.3 İşletim sistemini diske kurma

Konsolda `root` ile girilip Alpine kurulum sihirbazı çalıştırılır. Testte aynı adımlar serial console üzerinden cevap dosyasıyla otomatik yapılmıştır:

```sh
# VM konsolunda (ISO'dan açılmış live sistem)
cat > /tmp/answers <<'EOF'
KEYMAPOPTS=none
HOSTNAMEOPTS=alpine-from-iso
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
"
TIMEZONEOPTS=UTC
PROXYOPTS=none
APKREPOSOPTS="-1"
USEROPTS=none
SSHDOPTS=openssh
ROOTSSHKEY="<vmkey.pub içeriği>"
NTPOPTS=none
DISKOPTS="-m sys /dev/vda"
LBUOPTS=none
APKCACHEOPTS=none
EOF
ERASE_DISKS=/dev/vda setup-alpine -e -f /tmp/answers
poweroff
```

✅ **Gerçek çıktı:** Paketler internetten (pod ağı üzerinden) indirildi, `Installation is complete. Please reboot.`, `SETUP_RC=0`.

### 4.4 CD-ROM'u çıkarma ve diskten boot

> `runStrategy: Always` olan bir VM'de misafir içinden `poweroff` yapılırsa KubeVirt VM'i **yeniden başlatır** (yine ISO'dan açılır). Bu yüzden VM'i `virtctl stop` ile durdurun.

**CLI:**

```bash
virtctl stop alpine-from-iso -n trt-ocp-poc-virt
oc wait vmi alpine-from-iso -n trt-ocp-poc-virt --for=delete --timeout=120s

# CD-ROM diskini ve volume'unu VM tanımından çıkar (index 1 = installation-cdrom)
oc patch vm alpine-from-iso -n trt-ocp-poc-virt --type=json -p \
  '[{"op":"remove","path":"/spec/template/spec/domain/devices/disks/1"},
    {"op":"remove","path":"/spec/template/spec/volumes/1"}]'

virtctl start alpine-from-iso -n trt-ocp-poc-virt
virtctl ssh root@vmi/alpine-from-iso -n trt-ocp-poc-virt -i ./vmkey
```

✅ **Gerçek çıktı:** Diskler: `[{"bootOrder":2,"disk":{"bus":"virtio"},"name":"rootdisk"}]`. SSH ile `alpine-from-iso`, `3.24.2`, `/dev/vda3  3.3G  60.8M  3.1G  2% /`. Sistem artık kurulu diskten açılıyor.

**Console:** VM → **Configuration → Storage** (ya da **Disks**) → `installation-cdrom` satırında **⋮ → Eject CD-ROM** / **Detach** → **Actions → Restart**.

---

## 5. Golden Image (kurulu diskten boot source)

ISO'dan kurulup özelleştirilmiş bir disk "golden image" yapılabilir. Bu imaj kataloğa boot source olarak eklenir ve yeni VM'ler saniyeler içinde bu diskten klonlanır. Kurumların kendi hardening'li RHEL/Windows imajlarını dağıtma yöntemi budur.

`golden-image.yaml` üç kaynak içerir:

1. `DataVolume alpine-golden`: kurulu `alpine-from-iso-rootdisk`'in klonu
2. `DataSource alpine-golden`: bu PVC'yi boot source olarak yayınlar (varsayılan instancetype/preference label'larıyla)
3. `VirtualMachine alpine-from-golden`: `sourceRef` ile bu DataSource'tan açılan yeni VM

```bash
virtctl stop alpine-from-iso -n trt-ocp-poc-virt       # tutarlı kopya için kaynak VM'i durdurun
oc apply -f golden-image.yaml
virtctl start alpine-from-iso -n trt-ocp-poc-virt
virtctl ssh root@vmi/alpine-from-golden -n trt-ocp-poc-virt -i ./vmkey
```

✅ **Gerçek çıktı:** `alpine-golden` ve `alpine-from-golden-rootdisk` **~24 saniyede** `Succeeded`. Yeni VM açıldı: `golden image VM OK: hostname=alpine-from-iso alpine=3.24.2`.

> Hostname'in `alpine-from-iso` olması beklenen bir durumdur: disk birebir kopyalanır. Gerçek golden image'larda imaj öncesinde **genelleştirme** yapılmalıdır: Linux'ta `virt-sysprep` / `cloud-init clean` + machine-id temizliği, Windows'ta `sysprep /generalize`.

**Console:** **Virtualization → Bootable volumes → Add volume → Source type: Use existing volume** (PVC `alpine-from-iso-rootdisk`) ya da **Volume snapshot**. İsteğe bağlı olarak volume **"Set as default boot source"** olarak işaretlenebilir. Oluşan volume **Catalog → InstanceTypes** ekranında seçilebilir hale gelir.

---

## 6. ODF Depolama — Hotplug Disk ve Online Büyütme

### 6.1 Çalışan VM'e disk takma (hotplug)

```bash
oc apply -f data-disk-dv.yaml                  # 10Gi boş, RWX Block DataVolume
oc wait dv fedora-data-disk -n trt-ocp-poc-virt --for=condition=Ready

virtctl addvolume fedora-from-template -n trt-ocp-poc-virt \
  --volume-name=fedora-data-disk --serial=DATADISK01 --persist
```

`--persist` diski VM tanımına da yazar, böylece VM yeniden başladığında disk kalır. Olmazsa disk sadece çalışan instance'a takılır.

```bash
# VM içinde
lsblk -d -o NAME,SIZE,SERIAL
sudo mkfs.xfs /dev/sda && sudo mkdir -p /data && sudo mount /dev/sda /data
```

✅ **Gerçek çıktı:** VM kapatılmadan `sda  10G  datadisk01` göründü. Volume durumu `fedora-data-disk Ready` (`hp-volume-*` attach pod'u ile).

> Hotplug diskler VM içinde **SCSI bus** üzerinden gelir (`/dev/sda`), `virtio` değildir. `--serial` değeri küçük harfe çevrilerek görünür. Disk `/dev/disk/by-id/virtio-*` altında bulunmaz; kalıcı mount için UUID kullanın.

**Console:** VM → **Configuration → Storage** → **Add disk** → **Use existing** / **Blank** → **Save** (VM çalışırken eklenir).

### 6.2 Diski online büyütme

```bash
oc patch pvc fedora-data-disk -n trt-ocp-poc-virt --type=merge \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# VM içinde (XFS)
sudo xfs_growfs -d /data
```

✅ **Gerçek çıktı:** PVC `20Gi` oldu. VM içinde, yeniden başlatma olmadan `sda 20G`. `xfs_growfs` sonrası `/dev/sda  20G ... /data`, test dosyası (`veri`) korundu.

**Console:** **Storage → PersistentVolumeClaims** → `fedora-data-disk` → **Actions → Expand PVC**.

---

## 7. Live Migration

Çalışan VM'i kapatmadan başka bir node'a taşır. Node bakımı (`oc adm drain`) sırasında da VM'ler bu şekilde otomatik taşınır. Koşul: VM disklerinin **RWX** olması (burada ODF RBD Block RWX).

```bash
oc get vmi -n trt-ocp-poc-virt \
  -o custom-columns=VM:.metadata.name,NODE:.status.nodeName,MIGRATABLE:'.status.conditions[?(@.type=="LiveMigratable")].status'
```

**Kesintiyi ölçmek için** VM içinde 200 ms aralıkla ping ve zaman damgası sayacı başlatıldı:

```bash
# VM içinde
nohup ping -i 0.2 -D 10.128.0.1 > /tmp/ping.log 2>&1 &
nohup sh -c 'while true; do date +%T.%N >> /tmp/counter.log; sleep 0.2; done' >/dev/null 2>&1 &
```

**CLI:**

```bash
oc apply -f live-migration.yaml          # ya da: virtctl migrate fedora-from-template -n trt-ocp-poc-virt
oc get vmim -n trt-ocp-poc-virt -w
oc get vmi fedora-from-template -n trt-ocp-poc-virt -o jsonpath='{.status.migrationState}'
```

✅ **Gerçek çıktı:**

| Ölçüm | Sonuç |
|---|---|
| Kaynak → hedef | `hpeworker01` → `hpeworker03` |
| Mod | `PreCopy` |
| Süre | 10:29:46 → 10:29:53 (**7 sn**) |
| VM içi ping (0.2 sn aralık, 209 paket) | **0 paket kaybı** |
| En büyük ping / sayaç boşluğu | **0.58 sn** (switchover anı; normal aralık 0.2 sn) |
| VM boot zamanı (`uptime -s`) | Değişmedi (`10:22:46`), VM yeniden başlamadı |

**Console:** VM → **Actions → Migrate → Compute** (ya da VM listesinde **⋮ → Migrate**). İlerleme **Virtualization → Overview → Migrations** sekmesinde izlenir.

---

## 8. Snapshot / Restore

ODF RBD CSI snapshot'ları üzerinden çalışır. VM **çalışırken** snapshot alınabilir. VM'de `qemu-guest-agent` varsa snapshot öncesi dosya sistemi dondurulur (freeze), böylece uygulama tutarlı bir kopya alınır.

```bash
# VM içinde: snapshot'ta olması gereken veri
echo "snapshot oncesi veri" > ~/onemli-dosya.txt; sync

oc apply -f vm-snapshot.yaml
oc wait vmsnapshot fedora-snap-1 -n trt-ocp-poc-virt --for=condition=Ready
oc get vmsnapshot fedora-snap-1 -n trt-ocp-poc-virt -o jsonpath='{.status.indications}'
```

✅ **Gerçek çıktı:** `phase=Succeeded indications=["GuestAgent","Online"]`. Arkada `ocs-storagecluster-rbdplugin-snapclass` ile 30Gi'lik bir `VolumeSnapshot` oluştu.

**Felaket simülasyonu ve geri dönüş:**

```bash
# VM içinde: veriyi "boz"
rm -f ~/onemli-dosya.txt; echo yanlislik > ~/snapshot-sonrasi.txt

virtctl stop fedora-from-template -n trt-ocp-poc-virt          # restore için VM kapalı olmalı
oc apply -f vm-restore.yaml
oc wait vmrestore fedora-restore-1 -n trt-ocp-poc-virt --for=condition=Ready
virtctl start fedora-from-template -n trt-ocp-poc-virt
```

✅ **Gerçek çıktı:** Restore öncesi home dizininde `snapshot-sonrasi.txt` vardı. Restore sonrası yalnızca `onemli-dosya.txt` kaldı, içeriği `snapshot oncesi veri`. Sonradan oluşturulan dosya kayboldu, silinen dosya geri geldi.

**Console:** VM → **Snapshots** sekmesi → **Take snapshot**. Geri dönmek için VM'i durdurun → snapshot'ın **⋮ → Restore VirtualMachine from snapshot**. Snapshot'tan **ayrı yeni bir VM** de oluşturulabilir: **⋮ → Create VirtualMachine**.

---

## 9. Multus — VM'e VLAN (LAN) Arayüzü

VM'e pod ağına ek olarak gerçek LAN'dan (VLAN 112) bir NIC eklenir. Böylece VM, LAN'daki diğer sunucular gibi doğrudan IP ile erişilebilir olur.

### 9.1 Node tarafı (NNCP)

Bedrock'ta tüm VM node'larında `br-vm` linux-bridge'i **NMState** (`NodeNetworkConfigurationPolicy`) ile zaten kuruludur (`br-vm` / `br-vm-for-hpe`, trunk port). Bu yüzden node ağına dokunulmadı. Sıfırdan kurulumda NNCP örneği:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-vm
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-vm
        type: linux-bridge
        state: up
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: <ikinci-fiziksel-nic>   # switch tarafında VLAN trunk olmalı
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range: {min: 2, max: 4094}
```

```bash
oc get nncp          # br-vm  Available  SuccessfullyConfigured
```

### 9.2 NetworkAttachmentDefinition

```bash
oc apply -f nad-vlan112.yaml      # type: bridge, bridge: br-vm, vlan: 112
```

**Console:** **Networking → NetworkAttachmentDefinitions → Create** → **Network Type: Linux bridge**, **Bridge name** `br-vm`, **VLAN tag** `112`.

### 9.3 Çalışan VM'e NIC ekleme (hotplug)

Cluster'ın `vmRolloutStrategy` değeri `LiveUpdate` olduğundan NIC, VM kapatılmadan eklenir. KubeVirt bunu arka planda otomatik bir live migration ile uygular.

```bash
oc patch vm fedora-from-template -n trt-ocp-poc-virt --type=json -p '[
  {"op":"add","path":"/spec/template/spec/domain/devices/interfaces/-","value":{"name":"vlan112","bridge":{}}},
  {"op":"add","path":"/spec/template/spec/networks/-","value":{"name":"vlan112","multus":{"networkName":"vlan-112"}}}]'

oc get vmim -n trt-ocp-poc-virt          # kubevirt-workload-update-xxxxx  Succeeded
```

**Console:** VM → **Configuration → Network** → **Add network interface** → **Network**: `vlan-112`, **Type**: Bridge → **Save**.

✅ **Gerçek çıktı:** Otomatik migration `Succeeded`. VM içinde yeni NIC (`enp2s0`) göründü. NetworkManager, VLAN 112'deki kurumsal DHCP'den **`10.134.112.101/24`** aldı (çakışma kontrolü: `arping -D` → 0 cevap).

### 9.4 Routing: LAN'dan erişim

VM'de iki arayüz olduğu için **iki default route** oluşur. Pod ağı (`enp1s0`, metric 100) önde olduğundan, LAN'dan gelen isteklerin cevabı yanlış arayüzden (NAT'lı pod ağından) çıkar ve bağlantı kurulamaz.

✅ **Gerçek çıktı (sorun):** Bastion'dan (`10.134.62.105`) `10.134.112.101`'e ping `%100 kayıp`. VM içinden ise `ping -I enp2s0 10.134.112.1` ve bastion'a ping başarılıydı (asimetrik routing).

Çözüm: VLAN arayüzünden default route alma, sadece kurumsal ağları o arayüzden yönlendir:

```bash
# VM içinde (NetworkManager)
sudo nmcli con mod "Wired connection 1" connection.id vlan112 \
  ipv4.never-default yes ipv4.routes "10.134.0.0/16 10.134.112.1"
sudo nmcli con up vlan112
```

✅ **Gerçek çıktı:** Bastion'dan `10.134.112.101`'e ping `0% packet loss`. **Doğrudan LAN IP'sine SSH** başarılı (`LAN IP uzerinden dogrudan SSH OK: fedora-from-template`). İnternet çıkışı pod ağından devam etti (`https://quay.io` → `200`).

> Guest agent'ın raporladığı IP (`oc get vmi ... .status.interfaces`) VM içinde yapılan değişikliklerden sonra birkaç saniye eski kalabilir. Doğrulamayı VM içinden (`ip -br a`) yapın.

---

## 10. Yerleşim — nodeSelector, Node Affinity, VM Affinity / Anti-Affinity

VM'ler virt-launcher pod'ları içinde çalıştığı için Kubernetes'in tüm scheduling kuralları `spec.template.spec` altında aynen kullanılır. KubeVirt her virt-launcher pod'una otomatik olarak `vm.kubevirt.io/name=<vm-adı>` label'ını koyar. VM-VM affinity kurallarında bu label kullanılabilir.

Tüm VM'ler instancetype `u1.small` (1 vCPU / 2Gi) + preference `fedora` ile, `fedora` boot source'undan oluşturulmuştur.

```bash
oc apply -f scheduling/vm-nodeselector.yaml -f scheduling/vm-node-affinity.yaml -f scheduling/vm-anti-affinity.yaml
# web-1 Running olduktan sonra:
oc apply -f scheduling/vm-affinity.yaml

oc get vmi -n trt-ocp-poc-virt -o custom-columns=VM:.metadata.name,PHASE:.status.phase,NODE:.status.nodeName
```

| Dosya | Kural | Beklenen | ✅ Gerçek sonuç |
|---|---|---|---|
| `vm-nodeselector.yaml` | `nodeSelector: kubernetes.io/hostname=hpeworker02` | Sadece hpeworker02 | `sched-nodeselector` → **hpeworker02** |
| `vm-node-affinity.yaml` | **required**: `node-role.kubernetes.io/qct` var; **preferred** (weight 100): `worker03` | qct node'larından biri, tercihen worker03 | `sched-node-affinity` → **worker03** |
| `vm-anti-affinity.yaml` | 4 VM (`app=trt-web`); required node affinity: `hpe` node'ları (3 adet); **required podAntiAffinity** (`topologyKey: kubernetes.io/hostname`) | 3 VM farklı node'larda, 4. VM yerleşemez | `web-1` → hpeworker01, `web-2` → hpeworker03, `web-3` → hpeworker02, **`web-4` → `ErrorUnschedulable`** |
| `vm-affinity.yaml` | **required podAffinity**: `vm.kubevirt.io/name=web-1` ile aynı node | web-1'in node'u | `cache-1` → **hpeworker01** (web-1 ile aynı) |

✅ **Gerçek çıktı (`web-4` event'i):**

```
0/9 nodes are available: 3 node(s) didn't match Pod's node affinity/selector,
3 node(s) didn't match pod anti-affinity rules, 3 node(s) had untolerated taint(s).
```

(3 master: taint, 3 qct: node affinity dışı, 3 hpe: anti-affinity dolu.) Bu davranış **required** kuralın katı olduğunu gösterir. "Mümkünse ayır, değilse yine de çalıştır" isteniyorsa `preferredDuringSchedulingIgnoredDuringExecution` kullanılmalıdır.

**Toleration (referans, uygulanmadı):** Bedrock'ta worker node'larında taint yok. Paylaşımlı cluster olduğu için test amaçlı taint eklenmedi. VM'leri adanmış (taint'li) node'lara koymak için:

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: dedicated
          operator: Equal
          value: virtualization
          effect: NoSchedule
```

**Console:** VM → **Configuration → Scheduling**:

- **Node selector** → key/value ekleyin.
- **Tolerations** → key/value/effect.
- **Affinity rules** → **Add affinity rule** → **Type**: Node Affinity / Workload (Pod) Affinity / Workload (Pod) Anti-Affinity. **Condition**: Required during scheduling / Preferred (weight). **Topology key**: `kubernetes.io/hostname`. Expression'lar label key/value ile tanımlanır.
- Değişiklikler bir sonraki yerleşimde (restart ya da migration) geçerli olur.

> **Live migration ile ilişkisi:** Migration hedefi de bu kurallara uyar. `nodeSelector` ile tek node'a sabitlenmiş bir VM başka node'a migrate edilemez (`LiveMigratable` olsa bile hedef bulunamaz). Anti-affinity ile tüm node'lar dolmuşsa (`web-1..3` örneği) migration da `Pending` kalır. Node bakımı planlanırken bu dikkate alınmalıdır.

---

## 11. OADP ile VM Yedekleme (hazırlık)

VM'lerin OADP (Velero) ile yedeklenebilmesi için DPA'da `kubevirt` ve `csi` plugin'leri gerekir. Bu repodaki `../OADP/README.md` ile kurulan `dpa-odf` şu şekilde güncellendi:

```bash
oc patch dpa dpa-odf -n openshift-adp --type=merge \
  -p '{"spec":{"configuration":{"velero":{"defaultPlugins":["openshift","aws","csi","kubevirt"]}}}}'
oc rollout status deploy/velero -n openshift-adp
```

✅ **Gerçek çıktı:** Velero deployment'ı yeniden açıldı. Init container'lar: `openshift-velero-plugin`, `velero-plugin-for-aws`, `kubevirt-velero-plugin`.

> ⏳ **Backup / restore testi henüz yapılmadı.** Namespace yedeği, namespace silme ve restore adımları `../OADP/README.md`'deki akışla (`includedNamespaces: [trt-ocp-poc-virt]`, `snapshotVolumes: true`) uygulanacak ve sonuçlar buraya eklenecek. CSI snapshot'ları sadece Ceph içinde tutulur, bu yüzden aynı cluster'a restore için yeterlidir. Farklı bir cluster'a taşıma / gerçek DR için DPA'da `nodeAgent` açılıp `snapshotMoveData: true` (Data Mover) kullanılmalıdır.

---

## 12. Bilinen Sınırlamalar / Canlı Testte Görülenler

- **DHCP ile IP çakışması (önemli):** VLAN 112'deki ilk denemede kurumsal DHCP, test VM'ine `10.134.112.179`'u verdi. Bu IP, başka bir VM'de (`default/rhel9-keycloak1`) **statik ikinci IP** olarak zaten tanımlıydı (`arping -D` başka bir MAC'ten cevap aldı; bastion'dan SSH başka bir sunucuya düştü). IP birkaç dakika içinde VM'den kaldırıldı, NIC de hot-unplug ile çıkarıldı. **Ders:** Statik IP'ler DHCP sunucusunda rezerve / hariç tutulmalıdır. Canlı ortamda VM'lere LAN IP'si verirken ya IPAM/DHCP ekibinden ayrılmış bir blok alınmalı ya da her IP kullanılmadan önce `arping -D` ile kontrol edilmelidir.
- **Multus NIC otomatik DHCP:** Fedora/RHEL imajlarında NetworkManager yeni eklenen NIC'e kendiliğinden DHCP ile IP alır ("Wired connection 1"). Hotplug öncesinde bunun farkında olun.
- **Hotplug diskler SCSI'dır:** `/dev/sdX` olarak görünür, `virtio` değil (bkz. 6.1).
- **`runStrategy: Always` + misafir içi `poweroff`:** VM yeniden başlatılır. Kalıcı kapatma için `virtctl stop` / Console **Stop** kullanın.
- **`virtctl start` sonrası `oc wait vmi`:** VMI nesnesi birkaç saniye sonra oluşur. Hemen `oc wait vmi` çalıştırılırsa `NotFound` döner. `oc wait vm <ad> --for=condition=Ready` kullanın ya da kısa bir bekleme ekleyin.
- **Windows ISO kurulumu:** Windows kurulum ekranı virtio disk/ağ sürücülerini tanımaz. OpenShift Virtualization'ın sağladığı `virtio-win` container disk'i ikinci CD-ROM olarak takılmalıdır (Console'da "Mount Windows drivers disk" kutusu). Ya da disk `sata` bus ile oluşturulup kurulum sonrası virtio sürücüleri yüklenmelidir.
- **Golden image genelleştirme:** Klonlanan disk hostname, SSH host key, machine-id gibi kimlikleri de taşır (bkz. bölüm 5).

---

## 13. Temizlik

```bash
oc delete -f scheduling/ --ignore-not-found
oc delete vm alpine-from-golden alpine-from-iso fedora-from-template trt-vm-from-custom-template -n trt-ocp-poc-virt
oc delete vmrestore,vmsnapshot --all -n trt-ocp-poc-virt
oc delete template trt-fedora-small trt-web-golden -n trt-ocp-poc-virt
oc delete namespace trt-ocp-poc-virt
```

`dpa-odf`'teki plugin eklemesini geri almak için (OADP rehberindeki orijinal hali):

```bash
oc patch dpa dpa-odf -n openshift-adp --type=merge \
  -p '{"spec":{"configuration":{"velero":{"defaultPlugins":["openshift","aws"]}}}}'
```

---

## Özet Tablo

| Senaryo | CLI | Console | Canlı test |
|---|---|---|---|
| Template listeleme / export / parametreler | `oc get template`, `oc get -o yaml`, `oc process --parameters` | Virtualization → Templates | ✅ |
| Template'ten VM | `oc process ... \| oc apply` | Catalog → Template catalog | ✅ 20 sn'de Running |
| Özel template | `custom-template.yaml` | Templates → Clone | ✅ SSH key parametresiyle |
| Var olan VM'den template | `vm-to-template.sh` | Bootable volumes + Templates → Clone | ✅ Golden image + Template üretildi, ⏳ ondan VM açma testi bekliyor |
| ISO yükleme | `virtctl image-upload` | Bootable volumes → Upload | ✅ 66 MB / 37 sn |
| ISO'dan kurulum | `vm-from-iso.yaml` + console | Boot from CD | ✅ Kurulum + CD-ROM çıkarma + diskten boot |
| Golden image | `golden-image.yaml` | Bootable volumes | ✅ |
| Hotplug disk / online büyütme | `virtctl addvolume`, `oc patch pvc` | Storage → Add disk / Expand PVC | ✅ 10→20Gi, veri korundu |
| Live migration | `virtctl migrate` / `VirtualMachineInstanceMigration` | Actions → Migrate | ✅ 7 sn, 0 paket kaybı |
| Snapshot / restore | `VirtualMachineSnapshot` / `VirtualMachineRestore` | Snapshots sekmesi | ✅ Online + guest agent freeze |
| Multus VLAN NIC | `nad-vlan112.yaml` + patch (hotplug) | Network → Add interface | ✅ LAN IP'sine doğrudan SSH |
| nodeSelector / node affinity | `scheduling/*.yaml` | Scheduling sekmesi | ✅ |
| VM affinity / anti-affinity | `scheduling/*.yaml` | Scheduling → Affinity rules | ✅ 4. VM Unschedulable |
| OADP ile VM backup | DPA `kubevirt` + `csi` plugin | — | ⏳ Plugin eklendi, backup testi bekliyor |
