from pathlib import Path
import hashlib
import tarfile

base=Path(__file__).resolve().parents[1]
files=sorted(p.relative_to(base/'root').as_posix() for p in (base/'root').rglob('*') if p.is_file())
(base/'manifest.txt').write_text('\n'.join(files)+'\n',encoding='utf-8',newline='\n')
paths=sorted(p for p in base.rglob('*') if p.is_file() and not any(x in ('.git','dist','__pycache__') for x in p.relative_to(base).parts) and p.suffix!='.pyc' and p.name!='SHA256SUMS')
(base/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(base).as_posix()+'\n' for p in paths),encoding='utf-8',newline='\n')
paths.append(base/'SHA256SUMS')
(base/'dist').mkdir(exist_ok=True)
archive=base/'dist/luci-app-zbox-device-limit-1.0.3.tar.gz'
with tarfile.open(archive,'w:gz') as tar:
    for p in paths:
        rel=p.relative_to(base).as_posix()
        info=tar.gettarinfo(str(p),arcname='luci-app-zbox-device-limit/'+rel)
        info.uid=info.gid=0; info.uname=info.gname='root'
        info.mode=0o755 if p.suffix=='.sh' or rel.startswith(('root/usr/libexec/','root/etc/init.d/','root/etc/hotplug.d/')) else 0o644
        with p.open('rb') as f: tar.addfile(info,f)
print(archive.name)
