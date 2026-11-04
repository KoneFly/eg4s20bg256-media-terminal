"""在编译前持久记录实际输入副本，临时构建目录退出后仍可追溯。"""
import datetime
import hashlib
import json
import pathlib
import sys

build = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
         for p in build.iterdir() if p.suffix in (".v", ".vh", ".cpp")}
out.write_text(json.dumps({"generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "sources": files}, indent=2) + "\n")
