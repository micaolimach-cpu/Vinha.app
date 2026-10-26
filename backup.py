"""Consistent SQLite backup. Usage: DATA_DIR=/var/data python backup.py /safe/path/backup.sqlite3"""
import os,sqlite3,sys
from pathlib import Path
if len(sys.argv)!=2:raise SystemExit('Informe um caminho de saída para o backup.')
source=Path(os.getenv('DATA_DIR',str(Path(__file__).parent/'data')))/'vinha.sqlite3'
target=Path(sys.argv[1])
if not source.exists():raise SystemExit('Banco de dados não encontrado.')
if target.exists():raise SystemExit('O destino já existe. Use um novo nome.')
target.parent.mkdir(parents=True,exist_ok=True)
fd=os.open(str(target),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd)
with sqlite3.connect(source) as src,sqlite3.connect(target) as dst:src.backup(dst)
print('Backup concluído.')
