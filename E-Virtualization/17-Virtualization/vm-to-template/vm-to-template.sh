#!/usr/bin/env bash
# Mevcut (durdurulmuş, genelleştirilmiş) bir VM'den golden image + OpenShift Template üretir.
#
# Kullanım: ./vm-to-template.sh <vm-adi> <namespace> <template-adi> [display-name]
#
# Yaptıkları:
#   1) VM'in root diskini (ilk disk) <template-adi>-image adlı DataVolume'a klonlar
#   2) Bu PVC'yi <template-adi> adlı DataSource (boot source) olarak yayınlar
#   3) VM tanımından NAME / CLOUD_USER_PASSWORD / SSH_KEY_SECRET parametreli bir Template üretir
#      (<template-adi>.yaml olarak kaydeder ve cluster'a uygular)
set -euo pipefail

VM=${1:?vm adi gerekli}
NS=${2:?namespace gerekli}
TPL=${3:?template adi gerekli}
DISPLAY=${4:-"$TPL (${VM} VM'inden uretildi)"}

phase=$(oc get vm "$VM" -n "$NS" -o jsonpath='{.status.printableStatus}')
if [ "$phase" != "Stopped" ]; then
  echo "HATA: $VM durumu '$phase'. Tutarli bir imaj icin once VM'i genellestirip durdurun (virtctl stop)." >&2
  exit 1
fi

VMJSON=$(mktemp); trap 'rm -f "$VMJSON"' EXIT
oc get vm "$VM" -n "$NS" -o json > "$VMJSON"

# Root disk = bootOrder'i en kucuk (yoksa ilk) disk; onun PVC adini bul
read -r ROOTVOL ROOTPVC ROOTSIZE ROOTSC < <(python3 - "$VMJSON" <<'EOF'
import json,sys,subprocess
vm=json.load(open(sys.argv[1])); spec=vm["spec"]["template"]["spec"]
disks=spec["domain"]["devices"]["disks"]
disks=sorted(disks,key=lambda d:d.get("bootOrder",999))
vols={v["name"]:v for v in spec["volumes"]}
for d in disks:
    v=vols[d["name"]]
    pvc=(v.get("dataVolume") or {}).get("name") or (v.get("persistentVolumeClaim") or {}).get("claimName")
    if pvc and "cdrom" not in d:
        p=json.loads(subprocess.check_output(["oc","get","pvc",pvc,"-n",vm["metadata"]["namespace"],"-o","json"]))
        print(d["name"],pvc,p["status"]["capacity"]["storage"],p["spec"]["storageClassName"]); break
EOF
)
echo "Root disk: volume=$ROOTVOL pvc=$ROOTPVC size=$ROOTSIZE sc=$ROOTSC"

# 1+2) Golden image: disk klonu + DataSource
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${TPL}-image
  namespace: ${NS}
spec:
  source:
    pvc:
      name: ${ROOTPVC}
      namespace: ${NS}
  storage:
    storageClassName: ${ROOTSC}
    resources:
      requests:
        storage: ${ROOTSIZE}
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${TPL}
  namespace: ${NS}
spec:
  source:
    pvc:
      name: ${TPL}-image
      namespace: ${NS}
EOF
oc wait dv "${TPL}-image" -n "$NS" --for=condition=Ready --timeout=15m

# 3) VM tanimindan Template uret
python3 - "$VMJSON" "$TPL" "$NS" "$ROOTVOL" "$ROOTSIZE" "$ROOTSC" "$DISPLAY" > "${TPL}.yaml" <<'EOF'
import json,sys,yaml
vmf,tpl,ns,rootvol,size,sc,display=sys.argv[1:]
vm=json.load(open(vmf)); old=vm["metadata"]["name"]
spec=vm["spec"]; tspec=spec["template"]["spec"]; dom=tspec["domain"]

def fix_labels(d):
    return {k:("${NAME}" if v==old else v) for k,v in (d or {}).items()
            if not k.startswith(("vm.kubevirt.io/template","app.kubernetes.io/managed-by","kubevirt.io/created-by"))}

# Makineye ozgu kimlikleri temizle
dom.get("firmware",{}).pop("uuid",None); dom.get("firmware",{}).pop("serial",None)
for i in dom["devices"].get("interfaces",[]): i.pop("macAddress",None)
# Sadece root disk + cloud-init kalsin (hotplug/veri diskleri template'e girmez)
keep={rootvol}|{v["name"] for v in tspec["volumes"] if "cloudInitNoCloud" in v or "cloudInitConfigDrive" in v}
tspec["volumes"]=[v for v in tspec["volumes"] if v["name"] in keep]
dom["devices"]["disks"]=[d for d in dom["devices"]["disks"] if d["name"] in keep]
for v in tspec["volumes"]:
    if v["name"]==rootvol: v.clear(); v.update({"name":rootvol,"dataVolume":{"name":"${NAME}"}})
    if "cloudInitNoCloud" in v:
        v["cloudInitNoCloud"]={"userData":"#cloud-config\nuser: fedora\npassword: ${CLOUD_USER_PASSWORD}\nchpasswd: { expire: False }"}
tspec["accessCredentials"]=[{"sshPublicKey":{"source":{"secret":{"secretName":"${SSH_KEY_SECRET}"}},"propagationMethod":{"noCloud":{}}}}]
spec["dataVolumeTemplates"]=[{"metadata":{"name":"${NAME}"},"spec":{
    "sourceRef":{"kind":"DataSource","name":tpl,"namespace":ns},
    "storage":{"storageClassName":sc,"resources":{"requests":{"storage":size}}}}}]
spec.pop("running",None); spec["runStrategy"]="Always"
spec["template"]["metadata"]={"labels":fix_labels(spec["template"].get("metadata",{}).get("labels")),
                              "annotations":{k:v for k,v in spec["template"].get("metadata",{}).get("annotations",{}).items() if k.startswith("vm.kubevirt.io/")}}
newvm={"apiVersion":"kubevirt.io/v1","kind":"VirtualMachine",
       "metadata":{"name":"${NAME}","labels":fix_labels(vm["metadata"].get("labels")),
                   "annotations":{k:v for k,v in vm["metadata"].get("annotations",{}).items() if k.startswith("vm.kubevirt.io/")}},
       "spec":spec}
oslabels={k:v for k,v in vm["metadata"].get("labels",{}).items() if k.startswith(("os.template","workload.template","flavor.template"))}
t={"apiVersion":"template.openshift.io/v1","kind":"Template",
   "metadata":{"name":tpl,"namespace":ns,
     "labels":{"template.kubevirt.io/type":"vm",**oslabels},
     "annotations":{"openshift.io/display-name":display,
       "description":f"{old} VM'inden uretilmis template (golden image: DataSource {ns}/{tpl}).",
       "iconClass":"icon-fedora","openshift.io/provider-display-name":"Sekom",
       "template.kubevirt.io/provider":"Sekom","tags":"kubevirt,virtualmachine,linux"}},
   "objects":[newvm],
   "parameters":[
     {"name":"NAME","description":"VM adi","generate":"expression","from":tpl+"-[a-z0-9]{6}"},
     {"name":"CLOUD_USER_PASSWORD","description":"cloud-init kullanicisi (fedora) sifresi","generate":"expression","from":"[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}"},
     {"name":"SSH_KEY_SECRET","description":"VM'e enjekte edilecek SSH public key secret adi","value":"vm-ssh-key","required":True}]}
print(f"# {old} VM'inden vm-to-template.sh ile uretildi")
print(yaml.safe_dump(t,sort_keys=False,allow_unicode=True))
EOF
oc apply -f "${TPL}.yaml"
echo
echo "Hazir. Yeni VM:  oc process $TPL -n $NS -p NAME=<vm-adi> | oc apply -n $NS -f -"
